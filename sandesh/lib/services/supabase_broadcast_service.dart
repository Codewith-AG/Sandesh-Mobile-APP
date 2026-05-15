import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'dart:async';
import '../models/message_model.dart';
import '../models/contact_model.dart';
import '../models/user_profile_model.dart';
import 'local_db_service.dart';

class SupabaseBroadcastService {
  static final SupabaseBroadcastService _instance =
      SupabaseBroadcastService._internal();
  factory SupabaseBroadcastService() => _instance;
  SupabaseBroadcastService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  String _myUsername = '';

  /// Tracks the user we are currently chatting with to prevent local notifications
  String? activeChatUser;

  /// Active room channels keyed by the canonical room name
  final Map<String, RealtimeChannel> _roomChannels = {};

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

  void initialize(String myUsername) {
    _myUsername = myUsername.toLowerCase();

    // Subscribe to a personal global channel to listen for new chat requests
    final globalChannel = _client.channel(
      'global_$_myUsername',
      opts: const RealtimeChannelConfig(self: true),
    );
    globalChannel.onBroadcast(
      event: 'ping',
      callback: (payload) {
        final sender = payload['sender'] as String?;
        if (sender != null && sender.isNotEmpty) {
          debugPrint('Received global ping from $sender, subscribing to room...');
          subscribeToRoom(sender);

          // If the ping includes a message payload, handle it instantly
          if (payload.containsKey('id') && payload.containsKey('text')) {
            _handleIncomingMessage(payload);
          }
        }
      },
    ).subscribe();
  }

  // ──────────────────────────── Room Subscription ────────────────────────────

  /// Subscribe to a shared room channel between [_myUsername] and [peerUsername].
  /// Safe to call multiple times — it won't re-subscribe if already active.
  void subscribeToRoom(String peerUsername) {
    final roomName = getRoomName(_myUsername, peerUsername);

    if (_roomChannels.containsKey(roomName)) {
      debugPrint('Already subscribed to $roomName');
      return;
    }

    final channel = _client.channel(
      roomName,
      opts: const RealtimeChannelConfig(self: true),
    );

    channel
        .onBroadcast(
          event: 'new_message',
          callback: (payload) async {
            if (payload.isNotEmpty) {
              await _handleIncomingMessage(payload);
            }
          },
        )
        .subscribe((status, [error]) {
      debugPrint('Room $roomName status: $status');
    });

    _roomChannels[roomName] = channel;
  }

  /// Unsubscribe from a specific room
  void unsubscribeFromRoom(String peerUsername) {
    final roomName = getRoomName(_myUsername, peerUsername);
    final channel = _roomChannels.remove(roomName);
    if (channel != null) {
      _client.removeChannel(channel);
    }
  }

  /// Subscribe to rooms for ALL existing contacts (called on app startup)
  Future<void> subscribeToAllContactRooms() async {
    try {
      final contacts = await LocalDbService().getContacts();
      for (final contact in contacts) {
        subscribeToRoom(contact.username);
      }
      debugPrint('Subscribed to ${contacts.length} room channels');
    } catch (e) {
      debugPrint('Error subscribing to contact rooms: $e');
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
        isMe: false,
        timestamp: payload['timestamp'] as int,
      );

      // Save to local vault
      await LocalDbService().insertMessage(message);

      // Auto-add sender to contacts if not already there
      final exists = await LocalDbService().contactExists(message.senderUsername);
      if (!exists) {
        await LocalDbService().insertContact(Contact(
          username: message.senderUsername,
          hashedPhone: '',
        ));
        // Also subscribe to their room
        subscribeToRoom(message.senderUsername);
      }

      // Show local notification if not in active chat
      if (activeChatUser != message.senderUsername) {
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

  // ──────────────────────────── Sending Messages ────────────────────────────

  Future<void> sendMessage(Message message) async {
    // Save locally immediately so the UI updates instantly
    await LocalDbService().insertMessage(message);

    // Ensure we are subscribed to the room
    subscribeToRoom(message.receiverUsername);

    final roomName = getRoomName(message.senderUsername, message.receiverUsername);
    final channel = _roomChannels[roomName];

    if (channel == null) {
      debugPrint('ERROR: no channel for room $roomName');
      return;
    }

    // Broadcast to the shared room
    try {
      await channel.sendBroadcastMessage(
        event: 'new_message',
        payload: {
          'id': message.id,
          'sender_username': message.senderUsername,
          'receiver_username': message.receiverUsername,
          'text': message.text,
          'media_base64': message.mediaBase64,
          'timestamp': message.timestamp,
        },
      );

      // Ping the receiver globally so they wake up and subscribe if they haven't yet
      final pingChannel =
          _client.channel('global_${message.receiverUsername}');
      pingChannel.subscribe();
      await pingChannel.sendBroadcastMessage(
        event: 'ping',
        payload: {
          'sender': message.senderUsername,
          'id': message.id,
          'sender_username': message.senderUsername,
          'receiver_username': message.receiverUsername,
          'text': message.text,
          'media_base64': message.mediaBase64,
          'timestamp': message.timestamp,
        },
      );
      await _client.removeChannel(pingChannel);
    } catch (e) {
      debugPrint('Error broadcasting message: $e');
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
  /// as local contacts (excluding self). Also subscribes to their rooms.
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
        final exists = await LocalDbService().contactExists(username);
        if (!exists) {
          await LocalDbService().insertContact(Contact(
            username: username,
            phone: (user['phone_e164'] ?? '') as String,
            hashedPhone: '',
            bio: (user['bio'] ?? '') as String,
            avatarUrl: (user['avatar_url'] ?? '') as String,
          ));
          newContacts++;
        }
        // Subscribe to room for this contact
        subscribeToRoom(username);
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
          subscribeToRoom(username);
        }
      }

      debugPrint('Phone contact sync found $newContacts new matches');
    } catch (e) {
      debugPrint('Phone contact sync failed: $e');
    }
    return newContacts;
  }

  // ──────────────────────────── Cleanup ────────────────────────────

  void dispose() {
    for (final channel in _roomChannels.values) {
      _client.removeChannel(channel);
    }
    _roomChannels.clear();
    if (!_messageStreamController.isClosed) {
      _messageStreamController.close();
    }
  }
}
