import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import '../models/message_model.dart'; // includes MessageType & MessageTypeX
import '../models/contact_model.dart';
import '../models/user_profile_model.dart';
import 'local_db_service.dart';
import 'media_upload_service.dart';

class SupabaseBroadcastService with WidgetsBindingObserver {
  static final SupabaseBroadcastService _instance =
      SupabaseBroadcastService._internal();
  factory SupabaseBroadcastService() => _instance;
  SupabaseBroadcastService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  String _myUsername = '';

  /// Tracks the user we are currently chatting with to prevent local notifications
  String? activeChatUser;

  /// The single Postgres realtime channel that listens for all incoming messages
  RealtimeChannel? _inboxChannel;

  /// Broadcast stream for incoming messages — broadcast so multiple listeners are safe
  final StreamController<Message> _messageStreamController =
      StreamController<Message>.broadcast();
  Stream<Message> get messageStream => _messageStreamController.stream;

  // ──────────────────────────── Helpers ────────────────────────────

  /// Produces a deterministic room name for any two users.
  /// Always alphabetically sorted so both sides get the same key.
  static String getRoomName(String userA, String userB) {
    final sorted = [userA.toLowerCase(), userB.toLowerCase()]..sort();
    return 'room_${sorted[0]}_${sorted[1]}';
  }

  /// Normalize a raw phone number string to E.164 format.
  /// Handles Indian numbers (10 digits → +91...) and international formats.
  static String? normalizeToE164(String raw) {
    // Strip everything except digits and leading +
    final hasPlus = raw.trimLeft().startsWith('+');
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');

    if (digits.isEmpty || digits.length < 7) return null;

    if (hasPlus) {
      // Already has country code — reconstruct with +
      return '+$digits';
    }

    if (digits.length == 10) {
      // Bare 10-digit Indian mobile number
      return '+91$digits';
    }

    if (digits.length == 11 && digits.startsWith('0')) {
      // Indian format with leading 0 trunk code
      return '+91${digits.substring(1)}';
    }

    if (digits.length == 12 && digits.startsWith('91')) {
      // Indian number prefixed with country code (no +)
      return '+$digits';
    }

    // International number without + — best-effort
    if (digits.length >= 10) {
      return '+$digits';
    }

    return null;
  }

  // ──────────────────────────── Lifecycle ────────────────────────────

  /// Initialises the service for [myUsername].
  /// Sets up a single Postgres realtime listener on the `messages` table
  /// filtered to rows where `receiver_username = _myUsername`, then
  /// immediately syncs any messages that arrived while the app was offline.
  void initialize(String myUsername) {
    _myUsername = myUsername.toLowerCase();
    
    // Add lifecycle observer for presence tracking
    WidgetsBinding.instance.addObserver(this);
    _updatePresence(true);

    // STEP 3: Replace broadcast listener with a Postgres INSERT listener.
    // One single channel per user — no per-room subscriptions needed.
    _inboxChannel = _client
        .channel('public:messages:inbox:$_myUsername')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_username',
            value: _myUsername,
          ),
          callback: (payload) async {
            final row = payload.newRecord;
            if (row.isEmpty) return;

            // Handle the incoming message (save locally + notify UI)
            await _handleIncomingMessage(row);

            // The magic — DELETE the cloud copy immediately after local save
            final messageId = row['id'] as String?;
            if (messageId != null) {
              try {
                await _client
                    .from('messages')
                    .delete()
                    .eq('id', messageId);
                debugPrint('Deleted cloud message $messageId after delivery');
              } catch (e) {
                debugPrint('Failed to delete cloud message $messageId: $e');
              }
            }
          },
        )
        .subscribe((status, [error]) {
      debugPrint('Inbox channel status: $status${error != null ? " | $error" : ""}');
      // Auto-reconnect if the channel drops unexpectedly
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        debugPrint('Inbox channel lost — reconnecting in 3s...');
        Future.delayed(const Duration(seconds: 3), () {
          if (_myUsername.isNotEmpty) {
            _client.removeChannel(_inboxChannel!);
            _inboxChannel = null;
            initialize(_myUsername);
          }
        });
      }
    });

    // STEP 1: Sync messages that arrived while we were offline
    syncPendingMessages();

    // STEP 4: Get FCM token and save it to Supabase
    _syncFcmToken();
  }

  Future<void> _syncFcmToken() async {
    try {
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        await _client
            .from('profiles')
            .update({'fcm_token': fcmToken})
            .eq('username', _myUsername);
        debugPrint('FCM token saved: $fcmToken');
      }
      
      // Listen for foreground messages (optional, already handled by Realtime)
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('FCM foreground message: ${message.data}');
      });
    } catch (e) {
      debugPrint('Failed to sync FCM token: $e');
    }
  }

  // ──────────────────────────── STEP 1: Offline Sync ────────────────────────────

  /// Fetches all messages addressed to [_myUsername] from the Supabase
  /// `messages` table, saves each one locally, then deletes it from the cloud.
  /// This handles the "store-and-forward" catch-up on every app launch.
  Future<void> syncPendingMessages() async {
    try {
      final rows = await _client
          .from('messages')
          .select()
          .eq('receiver_username', _myUsername);

      final messages = rows as List<dynamic>;
      debugPrint('syncPendingMessages: found ${messages.length} pending message(s)');

      for (final row in messages) {
        final record = Map<String, dynamic>.from(row as Map);

        // Save locally and notify UI
        await _handleIncomingMessage(record);

        // Delete from cloud immediately after safe local storage
        final messageId = record['id'] as String?;
        if (messageId != null) {
          try {
            await _client.from('messages').delete().eq('id', messageId);
            debugPrint('syncPendingMessages: deleted cloud message $messageId');
          } catch (e) {
            debugPrint('syncPendingMessages: failed to delete $messageId: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('syncPendingMessages error: $e');
    }
  }

  // ──────────────────────────── Incoming Messages ────────────────────────────

  Future<void> _handleIncomingMessage(Map<String, dynamic> payload) async {
    try {
      final senderUsername = payload['sender_username'] as String;

      // Ignore messages sent by self — we already saved them locally in sendMessage()
      if (senderUsername.toLowerCase() == _myUsername) return;

      final message = Message(
        id: payload['id'] as String,
        senderUsername: senderUsername,
        receiverUsername: payload['receiver_username'] as String,
        text: payload['text'] as String?,
        mediaBase64: payload['media_base64'] as String?,
        mediaUrl: payload['media_url'] as String?,
        fileName: payload['file_name'] as String?,
        messageType: MessageTypeX.fromString(payload['message_type'] as String?),
        isMe: false,
        timestamp: payload['timestamp'] as int,
      );

      // Save to local vault
      await LocalDbService().insertMessage(message);

      // ── Auto-Download & Auto-Delete (Receiver side only) ──────────────────
      // For image and video messages with a network URL, immediately download
      // the file to local storage, update the DB record, then delete from cloud.
      if ((message.messageType == MessageType.image ||
              message.messageType == MessageType.video) &&
          message.mediaUrl != null &&
          message.mediaUrl!.startsWith('http')) {
        _autoDownloadAndClean(message);
      }

      // Auto-add sender to contacts if not already there
      final exists = await LocalDbService().contactExists(message.senderUsername);
      if (!exists) {
        await LocalDbService().insertContact(Contact(
          username: message.senderUsername,
          hashedPhone: '',
        ));
      }

      // Show local notification if not actively chatting with sender
      if (activeChatUser?.toLowerCase() != message.senderUsername.toLowerCase()) {
        _showLocalNotification(
            message.senderUsername, message.text ?? 'Sent an attachment');
      }

      // Notify UI globally — use microtask so listeners are guaranteed to be ready
      Future.microtask(() {
        if (!_messageStreamController.isClosed) {
          _messageStreamController.add(message);
        }
      });
    } catch (e) {
      debugPrint('Error handling incoming message: $e');
    }
  }

  Future<void> _showLocalNotification(String title, String body) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'messages_channel',
      'Messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
    );
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);
    try {
      final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      await flutterLocalNotificationsPlugin.show(
        id: DateTime.now().millisecond,
        title: title,
        body: body,
        notificationDetails: platformChannelSpecifics,
      );
    } catch (e) {
      debugPrint('Error showing notification: $e');
    }
  }

  // ──────────────────────────── STEP 2: Sending Messages ────────────────────────────

  /// Sends a message using the Store-and-Forward pattern:
  /// 1. Saves locally for instant UI feedback.
  /// 2. INSERTs into Supabase `messages` table for durable delivery.
  /// The receiver's Postgres listener (or `syncPendingMessages`) will pick it
  /// up, save it locally, and DELETE it from the cloud immediately.
  Future<void> sendMessage(Message message) async {
    // Save locally immediately so the UI updates instantly
    await LocalDbService().insertMessage(message);

    // INSERT into Supabase — durable, offline-safe delivery
    try {
      await _client.from('messages').insert({
        'id': message.id,
        'sender_username': message.senderUsername,
        'receiver_username': message.receiverUsername,
        'text': message.text,
        'media_url': message.mediaUrl,
        'file_name': message.fileName,
        'message_type': message.messageType.value,
        'timestamp': message.timestamp,
      });
      debugPrint('Message ${message.id} inserted into Supabase for delivery');
    } catch (e) {
      debugPrint('Error inserting message into Supabase: $e');
    }
  }

  // ──────────────────────────── Profile Sync ────────────────────────────

  /// Upserts the user profile to the Supabase `profiles` table.
  /// Uses the Supabase auth user ID as the conflict key.
  Future<void> syncProfile(UserProfile profile) async {
    try {
      final user = _client.auth.currentUser;
      await _client.from('profiles').upsert(
        profile.toSupabaseMap(authId: user?.id),
        onConflict: user != null ? 'id' : 'username',
      );
      debugPrint('Profile synced to Supabase');
    } catch (e) {
      debugPrint('Failed to sync profile: $e');
    }
  }

  // ──────────────────────────── Contact Discovery ────────────────────────────

  /// Queries the Supabase `profiles` table and auto-adds any registered users
  /// as local contacts (excluding self).
  Future<int> discoverContacts() async {
    int newContacts = 0;
    try {
      final response = await _client
          .from('profiles')
          .select('username, phone_e164, bio, avatar_url')
          .neq('username', _myUsername);

      final users = response as List<dynamic>;

      for (final user in users) {
        final username = (user['username'] as String).toLowerCase();
        if (username == _myUsername) continue;
        final avatarUrl = (user['avatar_url'] ?? '') as String;
        final exists = await LocalDbService().contactExists(username);
        if (!exists) {
          await LocalDbService().insertContact(Contact(
            username: username,
            phone: (user['phone_e164'] ?? '') as String,
            hashedPhone: '',
            bio: (user['bio'] ?? '') as String,
            avatarUrl: avatarUrl,
          ));
          newContacts++;
        } else if (avatarUrl.isNotEmpty) {
          // Always update avatar_url so URL changes (re-uploads) propagate
          await LocalDbService().updateContactAvatar(username, avatarUrl);
        }
      }

      debugPrint('Discovered $newContacts new contacts from Supabase');
    } catch (e) {
      debugPrint('Contact discovery failed: $e');
    }
    return newContacts;
  }

  /// Fetches device contacts, normalizes their numbers to E.164, and matches
  /// them against the Supabase `profiles.phone_e164` column.
  /// Returns the number of new contacts found.
  Future<int> syncPhoneContacts(List<String> rawPhoneNumbers) async {
    int newContacts = 0;
    try {
      // Normalize all device phone numbers to E.164
      final e164Numbers = <String>[];
      final e164ToRaw = <String, String>{};

      for (final raw in rawPhoneNumbers) {
        final e164 = normalizeToE164(raw);
        if (e164 != null && !e164Numbers.contains(e164)) {
          e164Numbers.add(e164);
          e164ToRaw[e164] = raw;
        }
      }

      if (e164Numbers.isEmpty) return 0;

      debugPrint(
          'Syncing ${e164Numbers.length} normalized E.164 phone numbers with Supabase...');

      // Query Supabase for matching E.164 phone numbers directly
      final response = await _client
          .from('profiles')
          .select('username, phone_e164, bio, avatar_url')
          .inFilter('phone_e164', e164Numbers)
          .neq('username', _myUsername);

      final users = response as List<dynamic>;

      for (final user in users) {
        final username = (user['username'] as String).toLowerCase();
        if (username == _myUsername) continue;
        final phoneE164 = (user['phone_e164'] ?? '') as String;

        final exists = await LocalDbService().contactExists(username);
        if (!exists) {
          await LocalDbService().insertContact(Contact(
            username: username,
            phone: phoneE164,
            hashedPhone: '',
            bio: (user['bio'] ?? '') as String,
            avatarUrl: (user['avatar_url'] ?? '') as String,
          ));
          newContacts++;
        }
      }

      debugPrint('Phone contact sync found $newContacts new matches');
    } catch (e) {
      debugPrint('Phone contact sync failed: $e');
    }
    return newContacts;
  }

  // Backward compatibility stubs for UI screens
  void subscribeToRoom(String peerUsername) {}
  void unsubscribeFromRoom(String peerUsername) {}
  Future<void> subscribeToAllContactRooms() async {}

  // ──────────────────────────── Auto-Download ────────────────────────────

  /// Downloads the media file in [message] to local storage, updates the DB
  /// record with the local path, then deletes the file from Supabase Storage.
  /// Runs fire-and-forget — errors are swallowed so they never crash the inbox.
  void _autoDownloadAndClean(Message message) {
    Future(() async {
      try {
        final url = message.mediaUrl!;
        // Build a deterministic, safe file name from the message id
        final ext = message.messageType == MessageType.image ? '.jpg' : '.mp4';
        final fileName = '${message.id}$ext';

        final localPath = await MediaUploadService().downloadAndSave(url, fileName);
        if (localPath == null) return;

        // Update DB so the bubble renders from local file next time
        await LocalDbService().updateMessageLocalPath(message.id, localPath);

        // Delete from Supabase Storage bucket
        await MediaUploadService().deleteFromStorage(url, 'chat_media');

        debugPrint('Auto-download complete: $localPath');
      } catch (e) {
        debugPrint('_autoDownloadAndClean error: $e');
      }
    });
  }


  // ──────────────────────────── Presence ────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_myUsername.isEmpty) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _updatePresence(true);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _updatePresence(false);
        break;
    }
  }

  Future<void> _updatePresence(bool isOnline) async {
    try {
      await _client.from('profiles').update({
        'is_online': isOnline,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).eq('username', _myUsername);
    } catch (e) {
      debugPrint('Failed to update presence: $e');
    }
  }

  // ──────────────────────────── Cleanup ────────────────────────────

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_myUsername.isNotEmpty) {
      _updatePresence(false);
    }

    if (_inboxChannel != null) {
      _client.removeChannel(_inboxChannel!);
      _inboxChannel = null;
    }
    if (!_messageStreamController.isClosed) {
      _messageStreamController.close();
    }
  }
}
