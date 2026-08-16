import 'dart:async';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../services/call_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../models/message_model.dart';
import '../theme/app_theme.dart';

class CallScreen extends StatefulWidget {
  final String myUsername;
  final String peerUsername;
  final String channelName;
  final String token;
  final int agoraUid; // server-issued; token is bound to this uid
  final String callType; // 'audio' | 'video'
  final bool isOutgoing;

  const CallScreen({
    super.key,
    required this.myUsername,
    required this.peerUsername,
    required this.channelName,
    required this.token,
    required this.agoraUid,
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

    final isVideo = widget.callType == 'video';

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
          // Remote peer left the channel — end this side too
          _leaveAndPop();
        },
      ),
    );

    // ── Audio: robust, drop-out-resistant voice ─────────────────────────
    // audioProfileSpeechStandard keeps the voice bitrate low and resilient,
    // and the chatroom scenario keeps a stable real-time audio session
    // (constant capture, no aggressive auto-ducking) — this is what stops
    // the audio cutting out mid-call. Applied to BOTH audio & video calls.
    await engine.enableAudio();
    await engine.setAudioProfile(
      profile: AudioProfileType.audioProfileSpeechStandard,
      scenario: AudioScenarioType.audioScenarioChatroom,
    );

    // Network-resilience fallback ladder (engine-wide):
    //  - if OUR uplink collapses, keep publishing AUDIO ONLY instead of
    //    dropping the call — the single most effective fix for audio cuts.
    //  - if the REMOTE downlink is weak, auto-switch to their low-res stream
    //    rather than freezing.
    await engine.setLocalPublishFallbackOption(
        StreamFallbackOptions.streamFallbackOptionAudioOnly);
    await engine.setRemoteSubscribeFallbackOption(
        StreamFallbackOptions.streamFallbackOptionVideoStreamLow);

    // Video calls default to the loudspeaker; audio calls to the earpiece.
    await engine.setDefaultAudioRouteToSpeakerphone(isVideo);

    if (isVideo) {
      await engine.enableVideo();

      // 1) Capture at Full-HD so the encoder receives a sharp 1080p source
      //    frame. Without an explicit capturer config Agora may capture at a
      //    low resolution, which no amount of encoder tuning can un-blur.
      await engine.setCameraCapturerConfiguration(
        const CameraCapturerConfiguration(
          cameraDirection: CameraDirection.cameraFront,
          format: VideoFormat(width: 1920, height: 1080, fps: 30),
        ),
      );

      // 2) Full-HD (1080p30) encoder config with an explicit, high target
      //    bitrate. WITHOUT this, Agora falls back to its low default profile
      //    (~360-720p, low bitrate) which looks blurry/pixelated on modern
      //    phones.
      //    - bitrate 4000 Kbps gives 1080p30 generous headroom for a crisp,
      //      sharp picture (Agora's 1080p30 reference is ~3150 Kbps; we sit a
      //      little above it for detail). NOTE: pushing tens of Mbps (e.g.
      //      33000) is NOT useful on a mobile RTC uplink — it only adds
      //      latency, packet loss and instability, so ~4 Mbps is the practical
      //      high-quality ceiling that still feels fast, not bulky.
      //    - maintainBalanced degradation => under congestion Agora trades a
      //      little of BOTH resolution and frame-rate rather than collapsing
      //      resolution first (which was the main cause of the far side
      //      looking blurry). Together with dual-stream (below) the peer keeps
      //      the sharpest picture their link can carry.
      //    - advanceOptions.preferLowLatency favours low end-to-end latency
      //      over maximum compression — the documented, typed low-latency
      //      control in agora_rtc_engine 6.x (keeps the call snappy).
      await engine.setVideoEncoderConfiguration(
        const VideoEncoderConfiguration(
          dimensions: VideoDimensions(width: 1920, height: 1080),
          frameRate: 30,
          bitrate: 4000, // strong 1080p30 target (Kbps) for a crisp picture
          minBitrate: 1200,
          orientationMode: OrientationMode.orientationModeAdaptive,
          degradationPreference: DegradationPreference.maintainBalanced,
          mirrorMode: VideoMirrorModeType.videoMirrorModeAuto,
          advanceOptions: AdvanceOptions(
            compressionPreference: CompressionPreference.preferLowLatency,
          ),
        ),
      );

      // 3) Dual-stream / simulcast (multi-bitrate). We publish a full-res HIGH
      //    stream AND a small LOW stream simultaneously. When the peer's
      //    connection drops, Agora automatically serves them the low stream
      //    (via the remote-subscribe fallback configured above) instead of
      //    freezing or smearing — this is the "use a lower bitrate when the
      //    connection drops" behaviour, done the SDK-native way.
      await engine.enableDualStreamMode(enabled: true);

      await engine.startPreview();
    } else {
      // Audio call: explicitly disable video so the camera is never used
      await engine.disableVideo();
    }

    await engine.joinChannel(
      token: widget.token,
      channelId: widget.channelName,
      uid: widget.agoraUid,
      options: ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        publishMicrophoneTrack: true,
        publishCameraTrack: isVideo,
        autoSubscribeAudio: true,
        autoSubscribeVideo: isVideo,
      ),
    );
  }

  void _onSignal(CallEvent event) {
    if (event.channelName != widget.channelName) return;
    if (event.isAccepted && _isOutgoing) {
      if (mounted) setState(() => _isOutgoing = false);
    } else if (event.isRejected) {
      _leaveAndPop(reason: 'rejected');
    } else if (event.isEnded) {
      _leaveAndPop(reason: 'ended');
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
    _leaveAndPop(reason: 'ended');
  }

  void _leaveAndPop({String? reason}) async {
    if (_callEnded) return;
    _callEnded = true;
    
    if (widget.isOutgoing) {
      String status;
      if (_callConnected) {
        status = 'answered';
      } else if (reason == 'rejected') {
        status = 'declined';
      } else {
        status = 'missed'; // Caller hung up before answer, or timeout
      }
      
      try {
        await Supabase.instance.client.from('calls').insert({
          'caller_username': widget.myUsername,
          'receiver_username': widget.peerUsername,
          'call_type': widget.callType,
          'status': status,
          'duration_seconds': _elapsedSeconds,
        });

        // Also add a chat message for the call log
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final msgText = jsonEncode({
          'status': status,
          'duration': _elapsedSeconds,
          'call_type': widget.callType,
        });
        final msg = Message(
          id: 'call_${widget.myUsername}_$timestamp',
          senderUsername: widget.myUsername,
          receiverUsername: widget.peerUsername,
          text: msgText,
          messageType: MessageType.call,
          isMe: true,
          timestamp: timestamp,
        );
        await SupabaseBroadcastService().sendMessage(msg);
      } catch (e) {
        debugPrint('Error logging call to DB: $e');
      }
    }

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
          colors: [AppTheme.primary, AppTheme.background],
        ),
      ),
      child: Center(
        child: Container(
          width: 144,
          height: 144,
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.2),
                blurRadius: 32,
                spreadRadius: 8,
              ),
            ],
          ),
          child: Center(
            child: Text(
              initial,
              style: GoogleFonts.inter(
                fontSize: 64,
                fontWeight: FontWeight.w700,
                color: AppTheme.primary,
              ),
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
                fontSize: 24,
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
                fontSize: 16,
                color: Colors.white70,
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
                color: AppTheme.danger,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.danger.withValues(alpha: 0.45),
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
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}
