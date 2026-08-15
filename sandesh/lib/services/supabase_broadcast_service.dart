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
import 'notification_prefs.dart';
import 'package:gal/gal.dart';
import 'call_service.dart';

/// Notification action id for the inline "Reply" button (notification-text-reply-2).
/// Shared by [SupabaseBroadcastService] (which attaches the action) and
/// main.dart (which handles the typed reply text).
const String kReplyActionId = 'reply_action';

/// Emitted on [SupabaseBroadcastService.statusStream] when a delivery receipt
/// for one of OUR sent messages arrives (delivered / read). The open chat
/// screen listens and repaints the ticks for [messageId].
class MessageStatusUpdate {
  final String messageId;
  final String status; // 'delivered' | 'read'
  const MessageStatusUpdate(this.messageId, this.status);
}

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

  /// LAYER 4 (verified backstop): message id → pending backstop timer. If a
  /// `delivered` receipt arrives before the timer fires, it is cancelled
  /// (the peer already received the message, so no backstop push is needed).
  final Map<String, Timer> _backstopTimers = {};

  /// The single Postgres realtime channel that listens for all incoming messages
  RealtimeChannel? _inboxChannel;

  /// Broadcast stream for incoming messages — broadcast so multiple listeners are safe
  final StreamController<Message> _messageStreamController =
      StreamController<Message>.broadcast();
  Stream<Message> get messageStream => _messageStreamController.stream;

  /// Realtime channel that listens for delivery receipts of OUR sent messages.
  RealtimeChannel? _receiptsChannel;

  /// Realtime channel that listens for delete-for-everyone signals aimed at us.
  RealtimeChannel? _deletionsChannel;

  /// Emits status updates ('delivered' | 'read') for messages WE sent, so an
  /// open chat screen can repaint the tick marks (✓ / ✓✓ / blue ✓✓).
  final StreamController<MessageStatusUpdate> _statusStreamController =
      StreamController<MessageStatusUpdate>.broadcast();
  Stream<MessageStatusUpdate> get statusStream => _statusStreamController.stream;

  /// Emits the message id of any message that was deleted-for-everyone by its
  /// sender, so an open chat/group screen can remove it from the list live.
  final StreamController<String> _deletionStreamController =
      StreamController<String>.broadcast();
  Stream<String> get deletionStream => _deletionStreamController.stream;

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

    // #4 / #1: subscribe to delivery receipts + delete-for-everyone signals
    // and reconcile anything that happened while we were offline.
    _subscribeToReceipts();
    _subscribeToDeletions();
    syncPendingReceipts();
    syncPendingDeletions();

    // STEP 4: Get FCM token and save it to Supabase
    _syncFcmToken();

    // Pull the user's notification toggles into the local cache so a fresh
    // install / reinstall honours their saved preferences on the very first
    // incoming message (before they ever open the settings screen).
    NotificationPrefs.syncFromServer();
  }

  // ──────────────────────────── #4 Read Receipts ────────────────────────────

  /// Upserts a receipt row telling the ORIGINAL sender that we (the reader)
  /// have received/read their message. RLS only allows writing rows where
  /// `reader_username = us`, so this is safe.
  Future<void> _sendReceipt(
      String messageId, String senderUsername, String status) async {
    if (_myUsername.isEmpty) return;
    try {
      await _client.from('message_receipts').upsert({
        'message_id': messageId,
        'sender_username': senderUsername.toLowerCase(),
        'reader_username': _myUsername,
        'status': status,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'message_id,reader_username');
    } catch (e) {
      debugPrint('sendReceipt($status) error: $e');
    }
  }

  Future<void> sendDeliveredReceipt(String messageId, String senderUsername) =>
      _sendReceipt(messageId, senderUsername, 'delivered');

  Future<void> sendReadReceipt(String messageId, String senderUsername) =>
      _sendReceipt(messageId, senderUsername, 'read');

  /// Applies a receipt row addressed to us (the sender): updates the local
  /// message status and notifies any open chat screen so the ticks repaint.
  void _applyReceipt(Map<String, dynamic> row) {
    final id = row['message_id'] as String?;
    final status = row['status'] as String?;
    if (id == null || status == null) return;
    // Confirmed delivered/read — cancel any pending Layer-4 backstop so we
    // never double-notify the peer.
    _backstopTimers.remove(id)?.cancel();
    LocalDbService().updateMessageStatus(id, status);
    if (!_statusStreamController.isClosed) {
      _statusStreamController.add(MessageStatusUpdate(id, status));
    }
  }

  void _subscribeToReceipts() {
    if (_receiptsChannel != null) {
      _client.removeChannel(_receiptsChannel!);
      _receiptsChannel = null;
    }
    _receiptsChannel = _client
        .channel('public:message_receipts:$_myUsername')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_receipts',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_username',
            value: _myUsername,
          ),
          callback: (payload) => _applyReceipt(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'message_receipts',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_username',
            value: _myUsername,
          ),
          callback: (payload) => _applyReceipt(payload.newRecord),
        )
        .subscribe();
  }

  /// Catches up on receipts that were written while we were offline.
  Future<void> syncPendingReceipts() async {
    try {
      final rows = await _client
          .from('message_receipts')
          .select()
          .eq('sender_username', _myUsername);
      for (final row in (rows as List<dynamic>)) {
        _applyReceipt(Map<String, dynamic>.from(row as Map));
      }
    } catch (e) {
      debugPrint('syncPendingReceipts error: $e');
    }
  }

  // ──────────────────────────── #1 Delete for Everyone ────────────────────────────

  /// Deletes one of OUR OWN 1:1 messages for everyone. Records the deletion in
  /// `message_deletions` (so the peer removes it live/on next launch), tries to
  /// remove the cloud copy if still undelivered, and deletes it locally.
  Future<void> deleteMessageForEveryone(Message message) async {
    try {
      await _client.from('message_deletions').insert({
        'message_id': message.id,
        'sender_username': _myUsername,
        'receiver_username': message.receiverUsername.toLowerCase(),
        'is_group': false,
      });
    } catch (e) {
      debugPrint('deleteMessageForEveryone signal error: $e');
    }
    try {
      await _client.from('messages').delete().eq('id', message.id);
    } catch (_) {}
    await LocalDbService().deleteMessageById(message.id);
  }

  /// Deletes one of OUR OWN group messages for everyone. Removes the cloud row
  /// (RLS allows the sender), records a group deletion signal, and deletes it
  /// locally.
  Future<void> deleteGroupMessageForEveryone(
      String messageId, String groupId) async {
    try {
      await _client.from('group_messages').delete().eq('id', messageId);
    } catch (e) {
      debugPrint('deleteGroupMessageForEveryone cloud error: $e');
    }
    try {
      await _client.from('message_deletions').insert({
        'message_id': messageId,
        'sender_username': _myUsername,
        'receiver_username': groupId,
        'is_group': true,
      });
    } catch (_) {}
    await LocalDbService().deleteGroupMessageById(messageId);
  }

  void _applyDeletion(Map<String, dynamic> row) {
    final id = row['message_id'] as String?;
    if (id == null) return;
    final isGroup = row['is_group'] == true;
    if (isGroup) {
      LocalDbService().deleteGroupMessageById(id);
    } else {
      LocalDbService().deleteMessageById(id);
    }
    if (!_deletionStreamController.isClosed) {
      _deletionStreamController.add(id);
    }
  }

  void _subscribeToDeletions() {
    if (_deletionsChannel != null) {
      _client.removeChannel(_deletionsChannel!);
      _deletionsChannel = null;
    }
    // 1:1 deletions are addressed to us via receiver_username = our username.
    _deletionsChannel = _client
        .channel('public:message_deletions:$_myUsername')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_deletions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_username',
            value: _myUsername,
          ),
          callback: (payload) => _applyDeletion(payload.newRecord),
        )
        .subscribe();
  }

  /// Catches up on delete-for-everyone signals aimed at us while offline.
  Future<void> syncPendingDeletions() async {
    try {
      final rows = await _client
          .from('message_deletions')
          .select()
          .eq('receiver_username', _myUsername);
      for (final row in (rows as List<dynamic>)) {
        _applyDeletion(Map<String, dynamic>.from(row as Map));
      }
    } catch (e) {
      debugPrint('syncPendingDeletions error: $e');
    }
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

      // Block check: silently ignore messages from blocked users.
      // The message is still deleted from the cloud to prevent buildup.
      final isBlocked = await LocalDbService().isBlocked(senderUsername);
      if (isBlocked) {
        try {
          await _client.from('messages').delete().eq('id', payload['id'] as String);
        } catch (_) {}
        return;
      }

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
        replyToId: payload['reply_to_id'] as String?,
        replyToSender: payload['reply_to_sender'] as String?,
        replyToText: payload['reply_to_text'] as String?,
        replyToType: payload['reply_to_type'] as String?,
      );

      // ── Call signaling — do NOT save to DB, route to CallService ────────
      if (message.messageType.isCallSignal) {
        CallService().handleCallMessage(message);
        return; // skip DB insert, auto-download, notifications
      }

      // Save to local vault
      await LocalDbService().insertMessage(message);

      // ── #4 Receipts: acknowledge delivery to the sender ──────────────────
      // If the user is currently looking at this exact chat, the message is
      // effectively read the instant it arrives, so send a 'read' receipt.
      // Otherwise it is merely 'delivered'. The sender listens on
      // message_receipts and advances the tick marks accordingly.
      if (activeChatUser?.toLowerCase() == message.senderUsername.toLowerCase()) {
        sendReadReceipt(message.id, message.senderUsername);
      } else {
        sendDeliveredReceipt(message.id, message.senderUsername);
      }

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
        // Respect the user's "1-on-1 Messages" notification toggle. When it is
        // OFF we still saved the message + notified the UI above; we simply
        // suppress the heads-up notification.
        final messagesEnabled = await NotificationPrefs.messagesEnabled();
        if (!_isSyncing && messagesEnabled) {
          // WhatsApp-style: show the saved contact name instead of raw username
          final displayName = await LocalDbService()
              .getContactDisplayName(message.senderUsername);
          _showLocalNotification(
            title: displayName ?? message.senderUsername,
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
    // Honour the user's In-App Sounds / Vibrate toggles for realtime (in-app)
    // notifications. (Killed-app FCM pushes are gated separately server-side.)
    final soundsEnabled = await NotificationPrefs.soundsEnabled();
    final vibrateEnabled = await NotificationPrefs.vibrateEnabled();

    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'messages_channel',
      'Messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      playSound: soundsEnabled,
      enableVibration: vibrateEnabled,
      // Inline "Reply" action (notification-text-reply-2). Tapping Reply opens an
      // on-notification text field; the typed text is delivered to the app's
      // notification-response handler which sends it via store-and-forward.
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
          kReplyActionId,
          'Reply',
          inputs: <AndroidNotificationActionInput>[
            AndroidNotificationActionInput(label: 'Message'),
          ],
          // Keep the app in the background — we just send the reply, no UI.
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );
    final NotificationDetails platformChannelSpecifics =
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
  /// 3. If INSERT succeeds, the Supabase Database Webhook → send-push Edge
  ///    Function will fire automatically and send the FCM push.
  /// 4. As a FALLBACK, we also call the send-notification Edge Function
  ///    directly so delivery works even if the webhook is misconfigured,
  ///    delayed, or the receiver's Realtime channel is not connected.
  ///
  /// Returns true if the cloud insert succeeded, false otherwise.
  Future<bool> sendMessage(Message message) async {
    // Save locally immediately so the UI updates instantly
    await LocalDbService().insertMessage(message);

    // CRITICAL FIX: lowercase usernames so the Realtime Postgres filter
    // (which uses lowercased _myUsername) always matches.
    final senderLower = message.senderUsername.toLowerCase();
    final receiverLower = message.receiverUsername.toLowerCase();

    // INSERT into Supabase — retry up to 3 times on failure.
    bool insertOk = false;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        await _client.from('messages').insert({
          'id': message.id,
          'sender_username': senderLower,
          'receiver_username': receiverLower,
          'text': message.text,
          'media_url': message.mediaUrl,
          'file_name': message.fileName,
          'message_type': message.messageType.value,
          'timestamp': message.timestamp,
          'reply_to_id': message.replyToId,
          'reply_to_sender': message.replyToSender,
          'reply_to_text': message.replyToText,
          'reply_to_type': message.replyToType,
        });
        debugPrint('[sendMessage] Inserted on attempt $attempt — webhook will trigger FCM');
        insertOk = true;
        break;
      } catch (e) {
        debugPrint('[sendMessage] INSERT failed (attempt $attempt/3): $e');
        if (attempt < 3) {
          await Future.delayed(Duration(seconds: attempt)); // 1s, 2s backoff
        }
      }
    }

    // FALLBACK: If INSERT succeeded, the webhook SHOULD fire and send FCM.
    // But we ALSO call the send-notification edge function directly as a
    // safety net. This guarantees delivery even if:
    //  - The webhook is not configured or broken
    //  - The receiver's Realtime channel is not connected
    //  - The receiver's app is killed and only FCM can wake it
    //
    // The send-notification function is idempotent — a duplicate FCM push
    // just shows one extra notification which is far better than zero.
    if (insertOk) {
      _scheduleDeliveryBackstop(message, senderLower, receiverLower);
    }

    if (!insertOk) {
      debugPrint('[sendMessage] All 3 INSERT attempts failed — message may not be delivered to receiver');
    }

    return insertOk;
  }

  /// LAYER 4 (verified backstop). After a message is sent, wait a few seconds
  /// for a `delivered` receipt from the peer. The receipt is written by the
  /// peer's Realtime path or its FCM background isolate the moment it receives
  /// the message. If NO receipt arrives in time — meaning the peer's app could
  /// not be woken (common on aggressive-OEM killed apps) — we invoke `renotify`
  /// to send a guaranteed system notification-shape push.
  ///
  /// Because it only fires when the message is UNconfirmed, there is no
  /// duplicate notification in the normal (fast-path) case. The timer is
  /// cancelled in [_applyReceipt] as soon as a receipt lands.
  void _scheduleDeliveryBackstop(Message message, String sender, String receiver) {
    // Call signals are ephemeral and handled elsewhere — never back them up.
    if (message.messageType.isCallSignal) return;

    _backstopTimers[message.id]?.cancel();
    _backstopTimers[message.id] = Timer(const Duration(seconds: 4), () async {
      _backstopTimers.remove(message.id);
      try {
        await _client.functions.invoke(
          'renotify',
          body: {
            'sender_username': sender,
            'receiver_username': receiver,
            'text': message.text ?? '',
            'message_id': message.id,
            'message_type': message.messageType.value,
            'timestamp': message.timestamp.toString(),
          },
        );
        debugPrint('[backstop] renotify fired for ${message.id} (no delivered receipt in 4s)');
      } catch (e) {
        // Best-effort — the store-and-forward layer still guarantees the message.
        debugPrint('[backstop] renotify error (non-fatal): $e');
      }
    });
  }


  /// Sends a call signaling message (callInvite / callAccepted / callRejected / callEnded).
  /// Does NOT save to local DB — call signals are ephemeral.
  Future<void> sendCallSignal(Message message) async {
    try {
      await _client.from('messages').insert({
        'id': message.id,
        'sender_username': message.senderUsername.toLowerCase(),
        'receiver_username': message.receiverUsername.toLowerCase(),
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

      // Match profiles CASE-INSENSITIVELY. Contacts are stored lower-cased, but
      // profiles.username keeps its original casing (e.g. "Rahul Pandey"), so a
      // case-sensitive `inFilter` would silently miss them — that mismatch is
      // exactly why a contact's avatar showed on the chat/calls screens (which
      // query profiles live) but NOT on the home list (which uses this cache).
      final usernames = localContacts
          .map((c) => c.username.toLowerCase())
          .toSet()
          .toList();
      final orFilter = usernames.map((u) => 'username.ilike.$u').join(',');

      final response = await _client
          .from('profiles')
          .select('username, bio, avatar_url')
          .or(orFilter);

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
        } else if (displayName.isNotEmpty) {
          // WhatsApp-style: always update display name from phone contacts
          // so if the user renames a contact in their phone, it reflects here.
          await LocalDbService().updateContactDisplayName(username, displayName);
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
    if (_receiptsChannel != null) {
      _client.removeChannel(_receiptsChannel!);
      _receiptsChannel = null;
    }
    if (_deletionsChannel != null) {
      _client.removeChannel(_deletionsChannel!);
      _deletionsChannel = null;
    }
    if (!_messageStreamController.isClosed) {
      _messageStreamController.close();
    }
    if (!_statusStreamController.isClosed) {
      _statusStreamController.close();
    }
    if (!_deletionStreamController.isClosed) {
      _deletionStreamController.close();
    }
    _initialized = false;
  }
}
