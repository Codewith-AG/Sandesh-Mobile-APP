import 'dart:async';
import 'dart:convert';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
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
  // Init
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> initialize(String myUsername) async {
    _myUsername = myUsername.toLowerCase();
    final appId = dotenv.env['AGORA_APP_ID'] ?? '';
    if (appId.isEmpty) {
      debugPrint('CallService: AGORA_APP_ID not set in .env — calls disabled.');
      return;
    }
    if (_engine != null) return; // already init
    _engine = createAgoraRtcEngine();
    await _engine!.initialize(RtcEngineContext(appId: appId));
    debugPrint('CallService: Agora engine ready (appId=$appId)');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Initiating a call — caller side
  // ════════════════════════════════════════════════════════════════════════════

  Future<bool> initiateCall({
    required String receiverUsername,
    required String callType,
  }) async {
    if (_isInCall || !isEngineReady) return false;

    // Request mic + camera permissions
    final statuses = await [Permission.microphone, Permission.camera].request();
    if (statuses[Permission.microphone] != PermissionStatus.granted) {
      debugPrint('CallService: mic permission denied');
      return false;
    }

    final ch = _makeChannelName(_myUsername, receiverUsername);
    final token = await _fetchToken(ch);
    if (token == null) {
      debugPrint('CallService: token fetch failed');
      return false;
    }

    _isInCall = true;

    // Signal receiver
    await _sendSignal(
      type: MessageType.callInvite,
      to: receiverUsername.toLowerCase(),
      channelName: ch,
      callType: callType,
    );

    // Emit an event so the caller's ChatScreen can navigate to CallScreen
    _signalCtrl.add(CallEvent(
      type: 'outgoing',
      callerUsername: _myUsername,
      receiverUsername: receiverUsername.toLowerCase(),
      channelName: ch,
      callType: callType,
    ));

    return true;
  }

  /// Returns the channel name and token for the caller to use in CallScreen.
  Future<String?> fetchTokenForChannel(String channelName) =>
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
      // Let main.dart / root listener show IncomingCallScreen
      if (!_incomingCtrl.isClosed) _incomingCtrl.add(event);
    } else {
      // callAccepted / callRejected / callEnded
      if (!_signalCtrl.isClosed) _signalCtrl.add(event);
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // Accept / Reject / End — called by UI screens
  // ════════════════════════════════════════════════════════════════════════════

  Future<String?> acceptCall(CallEvent event) async {
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

  Future<String?> _fetchToken(String channelName) async {
    try {
      final res = await Supabase.instance.client.functions
          .invoke('agora-token', body: {'channelName': channelName, 'uid': 0});
      return res.data['token'] as String?;
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
