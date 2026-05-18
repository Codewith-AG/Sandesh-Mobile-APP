import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/call_service.dart';

class CallScreen extends StatefulWidget {
  final String myUsername;
  final String peerUsername;
  final String channelName;
  final String token;
  final String callType; // 'audio' | 'video'
  final bool isOutgoing;

  const CallScreen({
    super.key,
    required this.myUsername,
    required this.peerUsername,
    required this.channelName,
    required this.token,
    required this.callType,
    required this.isOutgoing,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  // ── Agora state ────────────────────────────────────────────────────────────
  int? _remoteUid;
  bool _localJoined = false;

  // ── UI state ───────────────────────────────────────────────────────────────
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _callConnected = false; // true once remote peer joins
  bool _isOutgoing = false;
  bool _callEnded = false;

  // ── Signal subscription ────────────────────────────────────────────────────
  StreamSubscription<CallEvent>? _signalSub;

  // ── Call timer ─────────────────────────────────────────────────────────────
  Timer? _durationTimer;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _isOutgoing = widget.isOutgoing;
    _initAgora();

    // Listen for remote signals
    _signalSub = CallService().callSignalStream.listen(_onSignal);
  }

  Future<void> _initAgora() async {
    final engine = CallService().engine;
    final appId = dotenv.env['AGORA_APP_ID'] ?? '';
    if (appId.isEmpty) return;

    // Register callbacks
    engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (conn, elapsed) {
          if (mounted) setState(() => _localJoined = true);
        },
        onUserJoined: (conn, uid, elapsed) {
          if (mounted) {
            setState(() {
              _remoteUid = uid;
              _callConnected = true;
            });
            _startTimer();
          }
        },
        onUserOffline: (conn, uid, reason) {
          if (mounted) setState(() => _remoteUid = null);
        },
      ),
    );

    await engine.enableVideo();
    await engine.startPreview();

    await engine.joinChannel(
      token: widget.token,
      channelId: widget.channelName,
      uid: 0,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
  }

  void _onSignal(CallEvent event) {
    if (event.channelName != widget.channelName) return;
    if (event.isAccepted && _isOutgoing) {
      if (mounted) setState(() => _isOutgoing = false);
    } else if (event.isRejected || event.isEnded) {
      _leaveAndPop();
    }
  }

  void _startTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });
  }

  String get _formattedDuration {
    final m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Future<void> _toggleMute() async {
    _isMuted = !_isMuted;
    await CallService().engine.muteLocalAudioStream(_isMuted);
    if (mounted) setState(() {});
  }

  Future<void> _toggleCamera() async {
    _isCameraOff = !_isCameraOff;
    await CallService().engine.muteLocalVideoStream(_isCameraOff);
    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    await CallService().engine.switchCamera();
  }

  Future<void> _endCall() async {
    await CallService().endCall(
      peerUsername: widget.peerUsername,
      channelName: widget.channelName,
      callType: widget.callType,
    );
    _leaveAndPop();
  }

  void _leaveAndPop() {
    if (_callEnded) return;
    _callEnded = true;
    CallService().markCallEnded();
    _durationTimer?.cancel();
    try {
      CallService().engine.leaveChannel();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _signalSub?.cancel();
    _durationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType == 'video';
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Remote / Background view ──────────────────────────────────────
          if (isVideo && _remoteUid != null)
            _remoteVideoView()
          else
            _audioBackground(),

          // ── Local video preview (PiP corner) ─────────────────────────────
          if (isVideo && _localJoined)
            Positioned(
              top: 56,
              right: 16,
              child: _localVideoPreview(),
            ),

          // ── Peer name + status overlay ────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _topInfo(),
          ),

          // ── Bottom control bar ─────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _controlBar(isVideo),
          ),
        ],
      ),
    );
  }

  // ── Subwidgets ─────────────────────────────────────────────────────────────

  Widget _remoteVideoView() {
    return SizedBox.expand(
      child: AgoraVideoView(
        controller: VideoViewController.remote(
          rtcEngine: CallService().engine,
          canvas: VideoCanvas(uid: _remoteUid!),
          connection: RtcConnection(channelId: widget.channelName),
        ),
      ),
    );
  }

  Widget _audioBackground() {
    final initial = widget.peerUsername.isNotEmpty
        ? widget.peerUsername[0].toUpperCase()
        : '?';
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A0533), Color(0xFF0D0D1A)],
        ),
      ),
      child: Center(
        child: CircleAvatar(
          radius: 72,
          backgroundColor: const Color(0xFF7C3AED),
          child: Text(
            initial,
            style: GoogleFonts.inter(
              fontSize: 56,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _localVideoPreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 96,
        height: 140,
        child: AgoraVideoView(
          controller: VideoViewController(
            rtcEngine: CallService().engine,
            canvas: const VideoCanvas(uid: 0),
          ),
        ),
      ),
    );
  }

  Widget _topInfo() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 8),
            Text(
              widget.peerUsername,
              style: GoogleFonts.inter(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _callConnected
                  ? _formattedDuration
                  : _isOutgoing
                      ? 'Calling...'
                      : 'Connecting...',
              style: GoogleFonts.inter(
                fontSize: 14,
                color: Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlBar(bool isVideo) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.85), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ControlBtn(
            icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: _isMuted ? 'Unmute' : 'Mute',
            active: !_isMuted,
            onTap: _toggleMute,
          ),
          if (isVideo)
            _ControlBtn(
              icon: _isCameraOff
                  ? Icons.videocam_off_rounded
                  : Icons.videocam_rounded,
              label: _isCameraOff ? 'Cam Off' : 'Camera',
              active: !_isCameraOff,
              onTap: _toggleCamera,
            ),
          // End call (large red centre)
          GestureDetector(
            onTap: _endCall,
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.45),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.call_end_rounded,
                  color: Colors.white, size: 32),
            ),
          ),
          if (isVideo)
            _ControlBtn(
              icon: Icons.flip_camera_ios_rounded,
              label: 'Flip',
              active: true,
              onTap: _switchCamera,
            )
          else
            const SizedBox(width: 56), // balance row
        ],
      ),
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _ControlBtn({
    required this.icon,
    required this.label,
    required this.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: active
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.08),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: active ? 0.3 : 0.12),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              color: active ? Colors.white : Colors.white38,
              size: 24,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: Colors.white60,
            ),
          ),
        ],
      ),
    );
  }
}
