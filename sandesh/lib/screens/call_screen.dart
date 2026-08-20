import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../services/call_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../models/message_model.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

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
  bool _isCameraOff = false; // our own camera muted
  bool _remoteCameraOff = false; // peer's camera muted (show their avatar)
  bool _callConnected = false; // true once remote peer joins
  bool _isOutgoing = false;
  bool _callEnded = false;
  // Loudspeaker toggle. Defaults ON for video (hands-free) and OFF for audio
  // (earpiece), matching WhatsApp. Exposed as a control-bar button so the user
  // can switch to the loudspeaker during an audio call (function sub-issue-2.1).
  bool _isSpeakerOn = false;
  // Guards against playing/stopping the outgoing ringback tone more than once.
  bool _ringbackPlaying = false;

  // WhatsApp-style picture-in-picture swap: when true the LOCAL feed fills the
  // screen and the REMOTE feed shrinks into the corner tile.
  bool _localIsMain = false;
  // Controls auto-hide on tap (like WhatsApp) so video can go truly full-screen.
  bool _controlsVisible = true;

  // Peer's profile picture (fetched from `profiles`); null/empty => show initial.
  String? _peerAvatarUrl;

  // ── Signal subscription ────────────────────────────────────────────────────
  StreamSubscription<CallEvent>? _signalSub;

  // ── Call timer ─────────────────────────────────────────────────────────────
  Timer? _durationTimer;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _isOutgoing = widget.isOutgoing;
    _fetchPeerAvatar();
    _initAgora();

    // Outgoing calls play a looping ringback tone until the peer answers, so
    // the caller can HEAR that it's ringing — not just see "Calling..."
    // (function sub-issue-2.2). Stopped in _stopRingback() once connected/ended.
    if (_isOutgoing) _startRingback();

    // Listen for remote signals
    _signalSub = CallService().callSignalStream.listen(_onSignal);
  }

  // ── Outgoing ringback tone ──────────────────────────────────────────────────
  void _startRingback() {
    if (_ringbackPlaying) return;
    _ringbackPlaying = true;
    // Quieter than the incoming ringtone — this is the caller's "it's ringing"
    // feedback, played through the media/ringtone channel, looped until answer.
    FlutterRingtonePlayer().playRingtone(looping: true, volume: 0.4);
  }

  void _stopRingback() {
    if (!_ringbackPlaying) return;
    _ringbackPlaying = false;
    FlutterRingtonePlayer().stop();
  }

  /// Best-effort fetch of the peer's profile picture so the call screen can
  /// show their real avatar (Issue 2 · UI-1.1). Never throws / blocks the call.
  Future<void> _fetchPeerAvatar() async {
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('avatar_url')
          .eq('username', widget.peerUsername.toLowerCase())
          .maybeSingle();
      final url = (row?['avatar_url'] as String?) ?? '';
      if (mounted && url.isNotEmpty) setState(() => _peerAvatarUrl = url);
    } catch (e) {
      debugPrint('CallScreen: peer avatar fetch failed (non-fatal): $e');
    }
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
          // Peer answered → stop the ringback tone and start the call timer.
          _stopRingback();
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
        // Track when the peer turns their camera on/off so we can show their
        // avatar on a dark placeholder instead of a frozen/black frame
        // (Issue 2 · UI-1.3).
        onRemoteVideoStateChanged: (conn, uid, state, reason, elapsed) {
          if (!mounted) return;
          // Peer muted their camera → show their avatar placeholder.
          final mutedOff = state == RemoteVideoState.remoteVideoStateStopped &&
              reason ==
                  RemoteVideoStateReason.remoteVideoStateReasonRemoteMuted;
          // Peer's video resumed → go back to the live feed.
          final resumed = state == RemoteVideoState.remoteVideoStateDecoding ||
              state == RemoteVideoState.remoteVideoStateStarting;
          if (mutedOff && !_remoteCameraOff) {
            setState(() => _remoteCameraOff = true);
          } else if (resumed && _remoteCameraOff) {
            setState(() => _remoteCameraOff = false);
          }
        },
      ),
    );

    // ── Audio: high-quality, audible, drop-out-resistant voice ──────────
    // FIX (function sub-issue-2.3 / optimisation sub-issue-3.6): previously
    // only the VIDEO path was tuned and audio used the very low
    // `audioProfileSpeechStandard` (~18-24 Kbps), which is why voice sounded
    // thin/quiet — and in a video call the encoder took all the bandwidth so
    // audio was barely audible. We now:
    //   • use `audioProfileMusicHighQuality` — 48 kHz, mono, up to ~96 Kbps —
    //     a genuinely different, HIGHER audio bitrate than before, giving
    //     clear voice on BOTH audio and video calls (this is the separate
    //     "audio category" bitrate vs the video encoder bitrate below —
    //     function sub-issue-2.4);
    //   • use the `audioScenarioMeeting` scenario, tuned for real-time voice:
    //     constant capture, echo-cancellation, no aggressive auto-ducking —
    //     stops the audio cutting out mid-call.
    await engine.enableAudio();
    await engine.setAudioProfile(
      profile: AudioProfileType.audioProfileMusicHighQuality,
      scenario: AudioScenarioType.audioScenarioMeeting,
    );
    // Guarantee we actually SUBSCRIBE to and PLAY the peer's audio at full
    // volume — the concrete "I can't hear the other person" fix.
    await engine.muteAllRemoteAudioStreams(false);
    await engine.adjustPlaybackSignalVolume(100); // 0-400; 100 = unity
    await engine.adjustRecordingSignalVolume(100);

    // Network-resilience fallback ladder (engine-wide):
    //  - if OUR uplink collapses, keep publishing AUDIO ONLY instead of
    //    dropping the call — the single most effective fix for audio cuts.
    //  - if the REMOTE downlink is weak, auto-switch to their low-res stream
    //    rather than freezing.
    await engine.setLocalPublishFallbackOption(
        StreamFallbackOptions.streamFallbackOptionAudioOnly);
    await engine.setRemoteSubscribeFallbackOption(
        StreamFallbackOptions.streamFallbackOptionVideoStreamLow);

    // Video calls default to the loudspeaker (hands-free); audio calls to the
    // earpiece. The user can flip this at any time with the Speaker button
    // (function sub-issue-2.1). Keep _isSpeakerOn in sync with the default.
    await engine.setDefaultAudioRouteToSpeakerphone(isVideo);
    _isSpeakerOn = isVideo;

    if (isVideo) {
      await engine.enableVideo();

      // 1) Capture at 720p. On a mobile RTC uplink 720p is the sweet spot:
      //    sharp on a phone screen, but far cheaper to encode/transmit than
      //    1080p — which means LOWER latency, LESS battery/CPU, and it holds up
      //    on weak networks (optimisation sub-issue-3.1 & 3.5). Capturing at
      //    1080p only to send it over a congested mobile link added latency and
      //    caused the freezing/cut-outs the user reported.
      await engine.setCameraCapturerConfiguration(
        const CameraCapturerConfiguration(
          cameraDirection: CameraDirection.cameraFront,
          format: VideoFormat(width: 1280, height: 720, fps: 30),
        ),
      );

      // 2) 720p30 encoder config — a SEPARATE, explicit VIDEO bitrate ladder
      //    (distinct from the audio bitrate set above — function sub-issue-2.4):
      //    - bitrate 1800 Kbps is a crisp 720p30 target (Agora's 720p30
      //      reference is ~1710 Kbps) that a typical mobile uplink can actually
      //      sustain, so the picture stays sharp WITHOUT the stutter that a
      //      too-high 1080p/4 Mbps target caused.
      //    - minBitrate 320 lets Agora ride out congestion by dropping bitrate
      //      (not the whole call) so video "doesn't lag or cut" on low network
      //      (optimisation sub-issue-3.5).
      //    - maintainBalanced => under congestion Agora trades a little of BOTH
      //      resolution and frame-rate rather than collapsing one, keeping the
      //      far side watchable.
      //    - preferLowLatency favours low end-to-end latency over maximum
      //      compression (optimisation sub-issue-3.1).
      await engine.setVideoEncoderConfiguration(
        const VideoEncoderConfiguration(
          dimensions: VideoDimensions(width: 1280, height: 720),
          frameRate: 30,
          bitrate: 1800, // sustainable 720p30 target (Kbps)
          minBitrate: 320,
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

  /// Toggle the loudspeaker on/off (function sub-issue-2.1). Works for both
  /// audio (earpiece ⇄ speaker) and video calls.
  Future<void> _toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await CallService().engine.setEnableSpeakerphone(_isSpeakerOn);
    if (mounted) setState(() {});
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
    _stopRingback();
    
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
    _stopRingback();
    _signalSub?.cancel();
    _durationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType == 'video';
    final hasRemoteVideo = isVideo && _remoteUid != null && !_remoteCameraOff;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // Tap anywhere to toggle overlays so video can go truly full-screen
        // (WhatsApp-style). Audio calls keep the controls always visible.
        onTap: isVideo ? _toggleControls : null,
        child: Stack(
          children: [
            // ── Main full-screen feed / background ────────────────────────
            Positioned.fill(child: _mainView(isVideo, hasRemoteVideo)),

            // ── Floating PiP tile (connected video call only) ─────────────
            if (isVideo && _localJoined && _callConnected)
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                right: 16,
                child: _pipTile(hasRemoteVideo),
              ),

            // ── Peer name + status (fades with controls) ──────────────────
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _controlsVisible ? 1 : 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: _topInfo(),
              ),
            ),

            // ── Bottom control bar (slides out when hidden) ───────────────
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              bottom: _controlsVisible ? 0 : -220,
              child: _controlBar(isVideo),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleControls() => setState(() => _controlsVisible = !_controlsVisible);

  // ── Subwidgets ─────────────────────────────────────────────────────────────

  /// The full-screen feed. Video calls show the remote feed (or the local feed
  /// when swapped), falling back to an avatar placeholder when the relevant
  /// camera is off or the peer hasn't joined yet.
  Widget _mainView(bool isVideo, bool hasRemoteVideo) {
    if (!isVideo) return _audioBackground();

    if (_localIsMain) {
      return _isCameraOff
          ? _cameraOffPlaceholder(isSelf: true)
          : _localVideoFull();
    }
    if (hasRemoteVideo) return _remoteVideoView();
    return _callConnected
        ? _cameraOffPlaceholder(isSelf: false)
        : _audioBackground();
  }

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

  Widget _localVideoFull() {
    return SizedBox.expand(
      child: AgoraVideoView(
        controller: VideoViewController(
          rtcEngine: CallService().engine,
          canvas: const VideoCanvas(uid: 0),
        ),
      ),
    );
  }

  /// A dark screen with the person's avatar, shown when a camera is off.
  Widget _cameraOffPlaceholder({required bool isSelf, bool compact = false}) {
    final name = isSelf ? widget.myUsername : widget.peerUsername;
    final url = isSelf ? null : _peerAvatarUrl;
    return Container(
      color: const Color(0xFF0E0E11),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(name: name, imageUrl: url, radius: compact ? 26 : 56),
            if (!compact) ...[
              const SizedBox(height: 16),
              Text(
                isSelf ? 'Your camera is off' : 'Camera is off',
                style: GoogleFonts.inter(color: Colors.white54, fontSize: 15),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Audio-call / pre-connect background: the peer's profile picture blurred
  /// behind a large, crisp avatar (Issue 2 · UI-1.1 & 1.4). Falls back to a
  /// themed gradient when no picture is available.
  Widget _audioBackground() {
    final hasPic = _peerAvatarUrl != null && _peerAvatarUrl!.isNotEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasPic)
          Image(
            image: CachedNetworkImageProvider(_peerAvatarUrl!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _gradientBackdrop(),
          )
        else
          _gradientBackdrop(),
        // Darkened blur over the picture for readable overlays.
        if (hasPic)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(color: Colors.black.withValues(alpha: 0.5)),
          ),
        // Foreground: large avatar with a soft glow.
        Align(
          alignment: const Alignment(0, -0.18),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.35),
                  blurRadius: 44,
                  spreadRadius: 8,
                ),
              ],
            ),
            child: UserAvatar(
              name: widget.peerUsername,
              imageUrl: _peerAvatarUrl,
              radius: 76,
            ),
          ),
        ),
      ],
    );
  }

  Widget _gradientBackdrop() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.primary, AppTheme.background],
        ),
      ),
    );
  }

  /// Small rounded corner tile. Shows the feed NOT currently in the main view,
  /// and tapping it swaps the two (WhatsApp-style · Issue 2 · UI-1.3).
  Widget _pipTile(bool hasRemoteVideo) {
    final Widget content;
    if (_localIsMain) {
      // Main = my camera → PiP shows the remote peer.
      content = hasRemoteVideo
          ? _remoteVideoView()
          : _cameraOffPlaceholder(isSelf: false, compact: true);
    } else {
      // Main = remote → PiP shows my own camera.
      content = _isCameraOff
          ? _cameraOffPlaceholder(isSelf: true, compact: true)
          : _localVideoFull();
    }
    return GestureDetector(
      onTap: () => setState(() => _localIsMain = !_localIsMain),
      child: Container(
        width: 106,
        height: 152,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: content,
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
      // Buttons are laid out in an evenly-spaced row with the red End button
      // as the visual anchor in the centre, so nothing looks stray/unaligned
      // (function sub-issue-2.1). Audio calls show Mute · Speaker · End · Flip-
      // placeholder; video calls show Mute · Camera · End · Flip.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _ControlBtn(
            icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: _isMuted ? 'Unmute' : 'Mute',
            // Filled (solid white) when the toggle is engaged, like WhatsApp.
            filled: _isMuted,
            onTap: _toggleMute,
          ),
          if (isVideo)
            _ControlBtn(
              icon: _isCameraOff
                  ? Icons.videocam_off_rounded
                  : Icons.videocam_rounded,
              label: _isCameraOff ? 'Camera on' : 'Camera off',
              filled: _isCameraOff,
              onTap: _toggleCamera,
            )
          else
            // Speaker toggle — the new button requested for audio calls.
            _ControlBtn(
              icon: _isSpeakerOn
                  ? Icons.volume_up_rounded
                  : Icons.hearing_rounded,
              label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
              filled: _isSpeakerOn,
              onTap: _toggleSpeaker,
            ),
          // End call (large red centre) — the anchor of the row.
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
              onTap: _switchCamera,
            )
          else
            // Audio call: a Camera-style spot isn't needed, so we keep a fourth
            // slot balanced with a spacer that matches a control button's width.
            const SizedBox(width: 58),
        ],
      ),
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final String label;

  /// When true the button is a solid white pill (engaged state, e.g. muted /
  /// camera off); otherwise it's a translucent glass circle.
  final bool filled;
  final VoidCallback? onTap;

  const _ControlBtn({
    required this.icon,
    required this.label,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: filled
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: filled ? 0.0 : 0.25),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              color: filled ? Colors.black87 : Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}
