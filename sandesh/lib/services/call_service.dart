import 'dart:async';
import 'dart:convert';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/message_model.dart';
import 'supabase_broadcast_service.dart';

// ════════════════════════════════════════════════════════════════════════════
// Data model for a call signaling event
// ════════════════════════════════════════════════════════════════════════════

class CallEvent {
  final String type; // matches MessageType.value: call_invite / accepted / rejected / ended
  final String callerUsername;
  final String receiverUsername;
  final String channelName;
  final String callType; // 'audio' | 'video'

  const CallEvent({
    required this.type,
    required this.callerUsername,
    required this.receiverUsername,
    required this.channelName,
    required this.callType,
  });

  bool get isInvite => type == 'call_invite';
  bool get isAccepted => type == 'call_accepted';
  bool get isRejected => type == 'call_rejected';
  bool get isEnded => type == 'call_ended';
}

/// Result of a token fetch — both the Agora token and the per-user Agora uid
/// that the token was generated for. The client MUST use this uid when calling
/// `joinChannel`, otherwise Agora will reject the token.
class CallToken {
  final String token;
  final int uid;
  const CallToken({required this.token, required this.uid});
}

// ════════════════════════════════════════════════════════════════════════════
// CallService — Singleton
// ════════════════════════════════════════════════════════════════════════════

class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  // ── Agora ──────────────────────────────────────────────────────────────────
  RtcEngine? _engine;
  bool get isEngineReady => _engine != null;
  RtcEngine get engine => _engine!;

  // ── State ───────────────────────────────────────────────────────────────────
  String _myUsername = '';
  bool _isInCall = false;
  bool get isInCall => _isInCall;

  /// Channel names we have recently announced as incoming. Used to dedup
  /// the case where the same call_invite arrives twice (e.g. once via FCM
  /// notification tap, again via Supabase Realtime when the app catches up).
  final Map<String, DateTime> _recentInvites = {};

  // ── Streams ─────────────────────────────────────────────────────────────────

  /// Emits incoming call invites. [main.dart] listens to this and shows
  /// [IncomingCallScreen] via the global navigator key.
  final StreamController<CallEvent> _incomingCtrl =
      StreamController<CallEvent>.broadcast();
  Stream<CallEvent> get incomingCallStream => _incomingCtrl.stream;

  /// All other call events (accepted / rejected / ended) go here.
  /// [CallScreen] and [IncomingCallScreen] listen to this.
  final StreamController<CallEvent> _signalCtrl =
      StreamController<CallEvent>.broadcast();
  Stream<CallEvent> get callSignalStream => _signalCtrl.stream;

  // ════════════════════════════════════════════════════════════════════════════
  // Init — called on login. Safe to call multiple times.
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> initialize(String myUsername) async {
    _myUsername = myUsername.toLowerCase();
    // Engine is now initialized lazily on first call attempt.
    // This avoids the race condition where AGORA_APP_ID is not yet available.
    debugPrint('CallService: username set to $_myUsername (engine will init on first call)');
  }

  // ── Lazy engine init — called just before joining a channel ─────────────────
  Future<String?> _ensureEngineReady() async {
    if (_engine != null) return null; // already ready

    final appId = dotenv.env['AGORA_APP_ID'] ?? '';
    if (appId.isEmpty) {
      const msg = 'AGORA_APP_ID is not set in .env. Calls are disabled.';
      debugPrint('CallService: $msg');
      return msg;
    }

    try {
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(RtcEngineContext(appId: appId));
      debugPrint('CallService: Agora engine initialized (appId=$appId)');
      return null; // success
    } catch (e) {
      _engine = null;
      final msg = 'Agora engine failed to initialize: $e';
      debugPrint('CallService: $msg');
      return msg;
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Initiating a call — caller side
  // Returns null on success, or an error string describing the failure.
  // Permissions MUST be granted by the caller (chat_screen.dart) before calling this.
  // ════════════════════════════════════════════════════════════════════════════

  Future<String?> initiateCall({
    required String receiverUsername,
    required String callType,
  }) async {
    if (_isInCall) {
      return 'Already in a call.';
    }

    // Lazily initialize the Agora engine if not already done
    final engineError = await _ensureEngineReady();
    if (engineError != null) return engineError;

    final ch = _makeChannelName(_myUsername, receiverUsername);

    // Fetch token from Supabase Edge Function
    final tokenResult = await _fetchToken(ch);
    if (tokenResult == null) {
      return 'Could not get a call token from the server. '
          'Ensure the "agora-token" Edge Function is deployed and '
          'AGORA_APP_ID / AGORA_APP_CERTIFICATE secrets are set.';
    }

    _isInCall = true;

    // Signal receiver via existing store-and-forward pipeline
    try {
      await _sendSignal(
        type: MessageType.callInvite,
        to: receiverUsername.toLowerCase(),
        channelName: ch,
        callType: callType,
      );
    } catch (e) {
      _isInCall = false;
      return 'Failed to send call signal: $e';
    }

    // Emit an event so the caller's ChatScreen can navigate to CallScreen
    _signalCtrl.add(CallEvent(
      type: 'outgoing',
      callerUsername: _myUsername,
      receiverUsername: receiverUsername.toLowerCase(),
      channelName: ch,
      callType: callType,
    ));

    return null; // success
  }

  /// Returns the token + per-user uid for the caller to use in CallScreen.
  Future<CallToken?> fetchTokenForChannel(String channelName) =>
      _fetchToken(channelName);

  // ════════════════════════════════════════════════════════════════════════════
  // Handling incoming messages from SupabaseBroadcastService
  // ════════════════════════════════════════════════════════════════════════════

  void handleCallMessage(Message message) {
    final event = _parseEvent(message);
    if (event == null) return;

    if (message.messageType == MessageType.callInvite) {
      if (_isInCall) {
        // Already in call — auto reject
        _sendSignal(
          type: MessageType.callRejected,
          to: message.senderUsername,
          channelName: event.channelName,
          callType: event.callType,
        );
        return;
      }
      // Dedup invites that arrive twice (FCM + Realtime catch-up). Keep a
      // 60-second window per channel name.
      _purgeOldInvites();
      if (_recentInvites.containsKey(event.channelName)) return;
      _recentInvites[event.channelName] = DateTime.now();
      // Let main.dart / root listener show IncomingCallScreen
      if (!_incomingCtrl.isClosed) _incomingCtrl.add(event);
    } else {
      // callAccepted / callRejected / callEnded — also clear dedup so a future
      // invite on the same channel name (rare, but possible) is allowed through.
      _recentInvites.remove(event.channelName);
      if (!_signalCtrl.isClosed) _signalCtrl.add(event);
    }
  }

  void _purgeOldInvites() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    _recentInvites.removeWhere((_, t) => t.isBefore(cutoff));
  }

  /// Used by the FCM open/initial-message handlers so the incoming-call UI is
  /// shown through the same dedup-protected stream as the Realtime path.
  void notifyIncomingFromFcm(CallEvent event) {
    if (_isInCall) return;
    _purgeOldInvites();
    if (_recentInvites.containsKey(event.channelName)) return;
    _recentInvites[event.channelName] = DateTime.now();
    if (!_incomingCtrl.isClosed) _incomingCtrl.add(event);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Accept / Reject / End — called by UI screens
  // ════════════════════════════════════════════════════════════════════════════

  Future<CallToken?> acceptCall(CallEvent event) async {
    // Engine must be ready before the receiver tries to join the channel.
    final engineError = await _ensureEngineReady();
    if (engineError != null) {
      debugPrint('acceptCall: $engineError');
      return null;
    }
    _isInCall = true;
    await _sendSignal(
      type: MessageType.callAccepted,
      to: event.callerUsername,
      channelName: event.channelName,
      callType: event.callType,
    );
    return _fetchToken(event.channelName);
  }

  Future<void> rejectCall(CallEvent event) async {
    await _sendSignal(
      type: MessageType.callRejected,
      to: event.callerUsername,
      channelName: event.channelName,
      callType: event.callType,
    );
  }

  Future<void> endCall({
    required String peerUsername,
    required String channelName,
    required String callType,
  }) async {
    _isInCall = false;
    try {
      await _engine?.leaveChannel();
    } catch (_) {}
    await _sendSignal(
      type: MessageType.callEnded,
      to: peerUsername,
      channelName: channelName,
      callType: callType,
    );
  }

  void markCallEnded() => _isInCall = false;

  // ════════════════════════════════════════════════════════════════════════════
  // Private helpers
  // ════════════════════════════════════════════════════════════════════════════

  Future<CallToken?> _fetchToken(String channelName) async {
    try {
      final res = await Supabase.instance.client.functions
          .invoke('agora-token', body: {'channelName': channelName});
      final data = res.data as Map<String, dynamic>?;
      final token = data?['token'] as String?;
      final uid = (data?['uid'] as num?)?.toInt() ?? 0;
      if (token == null || token.isEmpty) {
        debugPrint('_fetchToken: server returned null/empty token');
        return null;
      }
      return CallToken(token: token, uid: uid);
    } catch (e) {
      debugPrint('_fetchToken error: $e');
      return null;
    }
  }

  static String _makeChannelName(String a, String b) {
    final sorted = [a.toLowerCase(), b.toLowerCase()]..sort();
    return 'call_${sorted[0]}_${sorted[1]}';
  }

  CallEvent? _parseEvent(Message msg) {
    try {
      final payload = jsonDecode(msg.text ?? '{}') as Map<String, dynamic>;
      return CallEvent(
        type: msg.messageType.value,
        callerUsername: msg.senderUsername,
        receiverUsername: msg.receiverUsername,
        channelName: payload['channelName'] as String? ?? '',
        callType: payload['callType'] as String? ?? 'audio',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendSignal({
    required MessageType type,
    required String to,
    required String channelName,
    required String callType,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final msg = Message(
      id: '${_myUsername}_${type.value}_$ts',
      senderUsername: _myUsername,
      receiverUsername: to,
      text: jsonEncode({'channelName': channelName, 'callType': callType}),
      messageType: type,
      callType: callType,
      isMe: true,
      timestamp: ts,
    );
    await SupabaseBroadcastService().sendCallSignal(msg);
  }

  // ── Dispose ──────────────────────────────────────────────────────────────────
  Future<void> disposeEngine() async {
    await _engine?.release();
    _engine = null;
  }
}
