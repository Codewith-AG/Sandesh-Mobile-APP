import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:convert';
import '../models/message_model.dart'; // includes MessageType & MessageTypeX
import '../models/contact_model.dart';
import '../models/user_profile_model.dart';
import 'local_db_service.dart';
import 'media_upload_service.dart';
import 'package:gal/gal.dart';
import 'call_service.dart';

class SupabaseBroadcastService with WidgetsBindingObserver {
  static final SupabaseBroadcastService _instance =
      SupabaseBroadcastService._internal();
  factory SupabaseBroadcastService() => _instance;
  SupabaseBroadcastService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  String _myUsername = '';

  /// Tracks the user we are currently chatting with to prevent local notifications
  String? activeChatUser;

  /// Suppresses local notifications during INITIAL sync (messages were already
  /// delivered by FCM while the app was closed; their FCM notification already
  /// appeared in the tray, so we don’t want a second one when we re-save them).
  /// This must NOT suppress notifications for NEW messages arriving via Realtime
  /// while the app is open.
  bool _isSyncing = false;

  /// IDs of messages that were pre-saved by the FCM background handler.
  /// The Realtime channel will fire for these when the app comes online, but
  /// we must NOT show a second local notification for them.
  final Set<String> _bgHandlerSavedIds = {};

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

  /// Whether this service has already been fully initialised once.
  bool _initialized = false;

  /// Initialises the service for [myUsername].
  /// Sets up a single Postgres realtime listener on the `messages` table
  /// filtered to rows where `receiver_username = _myUsername`, then
  /// immediately syncs any messages that arrived while the app was offline.
  ///
  /// Safe to call multiple times — only re-subscribes if the username changes
  /// or the channel has been torn down.
  void initialize(String myUsername) {
    final newUsername = myUsername.toLowerCase();

    // If already initialised for the same user, just make sure we are online
    // and the channel is still alive. Do NOT add another observer.
    if (_initialized && _myUsername == newUsername && _inboxChannel != null) {
      _startPresenceHeartbeat();
      return;
    }

    // ── Tear down any previous subscription ──────────────────────────────
    if (_initialized) {
      WidgetsBinding.instance.removeObserver(this);
      if (_inboxChannel != null) {
        _client.removeChannel(_inboxChannel!);
        _inboxChannel = null;
      }
    }

    _myUsername = newUsername;
    _initialized = true;

    // Register lifecycle observer exactly once
    WidgetsBinding.instance.addObserver(this);
    _startPresenceHeartbeat();

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

            final messageId = row['id'] as String?;

            // RACE-CONDITION FIX: if syncPendingMessages() already downloaded
            // and deleted this message, skip it here to avoid a second
            // notification and a redundant DB insert.
            if (messageId != null && _bgHandlerSavedIds.contains(messageId)) {
              debugPrint('[Realtime] Skipping already-synced message $messageId');
              _bgHandlerSavedIds.remove(messageId);
              // Delete from cloud in case sync missed it
              try {
                await _client.from('messages').delete().eq('id', messageId);
              } catch (_) {}
              return;
            }

            // Handle the incoming message (save locally + notify UI)
            await _handleIncomingMessage(row);

            // The magic — DELETE the cloud copy immediately after local save
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
            // Reset flag so initialize() fully re-subscribes
            _initialized = false;
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
    // Firebase sometimes returns null on the very first launch because it
    // hasn't registered with Google's FCM servers yet. We retry a few times
    // with a short delay so the token is always saved correctly.
    const maxAttempts = 5;
    const retryDelay = Duration(seconds: 2);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final authUser = _client.auth.currentUser;
        if (authUser == null) {
          debugPrint('FCM token sync skipped: no auth user');
          return;
        }

        final fcmToken = await FirebaseMessaging.instance.getToken();

        if (fcmToken != null && fcmToken.isNotEmpty) {
          await _client
              .from('profiles')
              .update({'fcm_token': fcmToken})
              .eq('id', authUser.id); // ← auth ID never has case issues
          debugPrint('FCM token saved (attempt $attempt) for ${authUser.id}: $fcmToken');
          return; // success — stop retrying
        } else {
          debugPrint('FCM token is null on attempt $attempt — retrying in ${retryDelay.inSeconds}s...');
        }
      } catch (e) {
        debugPrint('FCM token sync error on attempt $attempt: $e');
      }

      if (attempt < maxAttempts) {
        await Future.delayed(retryDelay);
      }
    }

    debugPrint('FCM token still null after $maxAttempts attempts. '
        'Check that google-services.json is correct and the device has Google Play Services.');
  }

  // ──────────────────────────── STEP 1: Offline Sync ────────────────────────────

  /// Fetches all messages addressed to [_myUsername] from the Supabase
  /// `messages` table, saves each one locally, then deletes it from the cloud.
  /// This handles the “store-and-forward” catch-up on every app launch.
  Future<void> syncPendingMessages() async {
    _isSyncing = true;
    try {
      final rows = await _client
          .from('messages')
          .select()
          .eq('receiver_username', _myUsername);

      final messages = rows as List<dynamic>;
      debugPrint('syncPendingMessages: found ${messages.length} pending message(s)');

      for (final row in messages) {
        final record = Map<String, dynamic>.from(row as Map);

        // Track this ID so the Realtime channel callback knows not to
        // show a duplicate notification for it.
        final msgId = record['id'] as String?;
        if (msgId != null) _bgHandlerSavedIds.add(msgId);

        // Save locally and notify UI (no notification shown while _isSyncing)
        await _handleIncomingMessage(record);

        // Delete from cloud immediately after safe local storage
        if (msgId != null) {
          try {
            await _client.from('messages').delete().eq('id', msgId);
            debugPrint('syncPendingMessages: deleted cloud message $msgId');
          } catch (e) {
            debugPrint('syncPendingMessages: failed to delete $msgId: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('syncPendingMessages error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  // ──────────────────────────── Incoming Messages ────────────────────────────

  Future<void> _handleIncomingMessage(Map<String, dynamic> payload) async {
    try {
      final senderUsername = payload['sender_username'] as String;

      // Ignore messages sent by self — we already saved them locally in sendMessage()
      // Case-insensitive comparison so it works regardless of name capitalization
      if (senderUsername.toLowerCase() == _myUsername.toLowerCase()) return;

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

      // ── Call signaling — do NOT save to DB, route to CallService ────────
      if (message.messageType.isCallSignal) {
        CallService().handleCallMessage(message);
        return; // skip DB insert, auto-download, notifications
      }

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

      // Show local notification ONLY if:
      // 1. Not actively chatting with this sender
      // 2. Not during initial sync (FCM already showed the notification for
      //    messages that arrived while the app was closed)
      //
      // IMPORTANT: New messages arriving via Realtime while the app is open
      // must ALWAYS show a notification (unless the chat is already open).
      // The old code used `!_isSyncing` here which accidentally suppressed
      // notifications for new messages if syncPendingMessages() happened to
      // still be running in the background.
      if (activeChatUser?.toLowerCase() != message.senderUsername.toLowerCase()) {
        if (!_isSyncing) {
          // App is fully running — this is a live new message, always notify
          _showLocalNotification(
            title: message.senderUsername,
            body: message.text ?? 'Sent an attachment',
            senderUsername: message.senderUsername,
          );
        }
        // If _isSyncing, FCM already showed the system notification
        // so we intentionally skip showing a duplicate.
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

  Future<void> _showLocalNotification({
    required String title,
    required String body,
    required String senderUsername,
  }) async {
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
      // Use the same global plugin instance as main.dart so the tap callback
      // wired up there fires when the user taps this notification.
      final plugin = FlutterLocalNotificationsPlugin();
      final payload = jsonEncode({
        'type': 'message',
        'sender_username': senderUsername,
      });
      await plugin.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
        title: title,
        body: body,
        notificationDetails: platformChannelSpecifics,
        payload: payload,
      );
    } catch (e) {
      debugPrint('Error showing notification: $e');
    }
  }

  // ──────────────────────────── STEP 2: Sending Messages ────────────────────────────

  /// Sends a message using the Store-and-Forward pattern:
  /// 1. Saves locally for instant UI feedback.
  /// 2. INSERTs into Supabase `messages` table for durable delivery.
  ///
  /// The FCM push notification is sent AUTOMATICALLY by the Supabase
  /// Database Webhook → send-push Edge Function when the INSERT fires.
  /// Flutter does NOT need to call the Edge Function directly.
  Future<void> sendMessage(Message message) async {
    // Save locally immediately so the UI updates instantly
    await LocalDbService().insertMessage(message);

    // INSERT into Supabase — durable, offline-safe delivery.
    // Using lowercase usernames so the realtime filter and webhook always match.
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
      debugPrint('Message ${message.id} inserted — webhook will trigger FCM push');
    } catch (e) {
      debugPrint('Error inserting message into Supabase: $e');
    }
  }

  /// Sends a call signaling message (callInvite / callAccepted / callRejected / callEnded).
  /// Does NOT save to local DB — call signals are ephemeral.
  Future<void> sendCallSignal(Message message) async {
    try {
      await _client.from('messages').insert({
        'id': message.id,
        'sender_username': message.senderUsername,
        'receiver_username': message.receiverUsername,
        'text': message.text,
        'message_type': message.messageType.value,
        'timestamp': message.timestamp,
      });
      debugPrint('Call signal ${message.messageType.value} sent to ${message.receiverUsername}');
    } catch (e) {
      debugPrint('sendCallSignal error: $e');
    }
  }


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

  /// Refreshes avatar/bio for contacts the user already has.
  ///
  /// SECURITY NOTE: Previously this method pulled the entire `profiles` table
  /// including phone numbers. That allowed any logged-in user to scrape every
  /// registered phone number in the system. We now restrict to (a) only the
  /// rows the user already knows about and (b) public columns only
  /// (no `phone_e164`).
  Future<int> discoverContacts() async {
    int updated = 0;
    try {
      final localContacts = await LocalDbService().getContacts();
      if (localContacts.isEmpty) return 0;
      final usernames = localContacts.map((c) => c.username.toLowerCase()).toList();

      final response = await _client
          .from('profiles')
          .select('username, bio, avatar_url')
          .inFilter('username', usernames);

      final users = response as List<dynamic>;
      for (final user in users) {
        final username = (user['username'] as String).toLowerCase();
        final avatarUrl = (user['avatar_url'] ?? '') as String;
        if (avatarUrl.isNotEmpty) {
          await LocalDbService().updateContactAvatar(username, avatarUrl);
          updated++;
        }
      }
    } catch (e) {
      debugPrint('Contact refresh failed: $e');
    }
    return updated;
  }

  /// Matches the user's device contacts against Supabase by phone number.
  ///
  /// SECURITY: We do NOT query `profiles` directly — that would leak the whole
  /// phone book to any authenticated user. Instead we call the SECURITY DEFINER
  /// RPC `find_contacts_by_phones`, which only returns rows whose phone the
  /// caller already knows. Phone numbers in the response are the same ones the
  /// caller submitted, so no new information is disclosed.
  Future<int> syncPhoneContacts(Map<String, String> phoneToName) async {
    int newContacts = 0;
    try {
      // Normalize all device phone numbers to E.164 and build a reverse map
      final e164ToName = <String, String>{};
      for (final entry in phoneToName.entries) {
        final e164 = normalizeToE164(entry.key);
        if (e164 != null) {
          e164ToName[e164] = entry.value;
        }
      }
      if (e164ToName.isEmpty) return 0;

      debugPrint(
          'Matching ${e164ToName.length} normalized phone numbers via RPC...');

      // SECURITY DEFINER RPC defined in security_policies.sql.
      // Signature: find_contacts_by_phones(phone_list text[])
      //   RETURNS TABLE (username text, phone_e164 text, bio text, avatar_url text)
      final response = await _client.rpc(
        'find_contacts_by_phones',
        params: {'phone_list': e164ToName.keys.toList()},
      );

      final users = (response as List<dynamic>?) ?? const [];
      for (final user in users) {
        final username = (user['username'] as String).toLowerCase();
        if (username == _myUsername) continue;
        final phoneE164 = (user['phone_e164'] ?? '') as String;
        final displayName = e164ToName[phoneE164] ?? '';

        final exists = await LocalDbService().contactExists(username);
        if (!exists) {
          await LocalDbService().insertContact(Contact(
            username: username,
            phone: phoneE164,
            hashedPhone: '',
            displayName: displayName,
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

        // Ensure it is saved to the native gallery
        if (message.messageType == MessageType.image) {
          await Gal.putImage(localPath);
        } else if (message.messageType == MessageType.video) {
          await Gal.putVideo(localPath);
        }

        // Update DB so the bubble renders from local file next time
        await LocalDbService().updateMessageLocalPath(message.id, localPath);

        // Delete from Supabase Storage bucket
        await MediaUploadService().deleteFromStorage(url, 'chat_media');

        debugPrint('Auto-download complete & saved to gallery: $localPath');
      } catch (e) {
        debugPrint('_autoDownloadAndClean error: $e');
      }
    });
  }


  // ──────────────────────────── Presence ────────────────────────────

  Timer? _presenceDebounce;
  /// Periodic heartbeat keeps `is_online = true` refreshed every 30 s while the
  /// app is in the foreground. Without this, a Supabase restart or transient
  /// network blip could silently reset the flag and make the user look offline.
  Timer? _presenceHeartbeat;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_myUsername.isEmpty) return;
    switch (state) {
      case AppLifecycleState.resumed:
        // Cancel any pending offline update and immediately go online
        _presenceDebounce?.cancel();
        _startPresenceHeartbeat();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Stop heartbeat and debounce: wait 8 seconds before marking offline
        // to avoid flicker during quick app switches or notification shade pulls
        _presenceHeartbeat?.cancel();
        _presenceHeartbeat = null;
        _presenceDebounce?.cancel();
        _presenceDebounce = Timer(const Duration(seconds: 8), () {
          _updatePresence(false);
        });
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Don't mark offline — these are transient states
        break;
    }
  }

  Future<void> _updatePresence(bool isOnline) async {
    try {
      // Use lowercase id-based update to avoid any case mismatch
      final authUser = _client.auth.currentUser;
      if (authUser != null) {
        await _client.from('profiles').update({
          'is_online': isOnline,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', authUser.id);
      } else {
        await _client.from('profiles').update({
          'is_online': isOnline,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
        }).eq('username', _myUsername);
      }
    } catch (e) {
      debugPrint('Failed to update presence: $e');
    }
  }

  /// Immediately marks the user online and starts a 30-second heartbeat that
  /// keeps refreshing `is_online = true` while the app is in the foreground.
  /// Cancels any running heartbeat first to avoid duplicates.
  void _startPresenceHeartbeat() {
    _presenceHeartbeat?.cancel();
    _updatePresence(true); // Immediate update
    _presenceHeartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      _updatePresence(true);
    });
  }

  // ──────────────────────────── Cleanup ────────────────────────────

  void dispose() {
    _presenceDebounce?.cancel();
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
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
    _initialized = false;
  }
}
