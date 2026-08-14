import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/call_service.dart';
import '../theme/app_theme.dart';
import 'call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  final CallEvent event;
  const IncomingCallScreen({super.key, required this.event});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;
  StreamSubscription<CallEvent>? _signalSub;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Listen for call_ended / call_rejected from caller side (caller cancelled)
    _signalSub = CallService().callSignalStream.listen((e) {
      if (!mounted) return;
      if (e.channelName == widget.event.channelName &&
          (e.isEnded || e.isRejected)) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _signalSub?.cancel();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_handling) return;
    setState(() => _handling = true);

    // ── Step 1: Request only the permissions we need for this call type ────
    final isVideo = widget.event.callType == 'video';
    final perms = isVideo
        ? [Permission.microphone, Permission.camera]
        : [Permission.microphone];
    final statuses = await perms.request();
    final allGranted =
        statuses.values.every((s) => s == PermissionStatus.granted);
    if (!allGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isVideo
              ? 'Microphone and Camera permissions are required for a video call.'
              : 'Microphone permission is required for an audio call.'),
        ));
        Navigator.of(context).pop();
      }
      return;
    }

    // ── Step 2: Ask CallService to send accept signal + fetch Agora token ──
    final callToken = await CallService().acceptCall(widget.event);
    if (!mounted) return;
    if (callToken == null || callToken.token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to get a call token. Try again.'),
      ));
      // Make sure we don't leave the service stuck in isInCall=true
      CallService().markCallEnded();
      Navigator.of(context).pop();
      return;
    }

    // ── Step 3: Resolve my own username for CallScreen ──────────────────────
    final prefs = await SharedPreferences.getInstance();
    final myUsername = (prefs.getString('username') ??
            widget.event.receiverUsername)
        .toLowerCase();

    // ── Step 4: Replace IncomingCallScreen with CallScreen ─────────────────
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          myUsername: myUsername,
          peerUsername: widget.event.callerUsername,
          channelName: widget.event.channelName,
          token: callToken.token,
          agoraUid: callToken.uid,
          callType: widget.event.callType,
          isOutgoing: false,
        ),
      ),
    );
  }

  Future<void> _reject() async {
    if (_handling) return;
    setState(() => _handling = true);
    await CallService().rejectCall(widget.event);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.event.callType == 'video';
    final initial = widget.event.callerUsername.isNotEmpty
        ? widget.event.callerUsername[0].toUpperCase()
        : '?';

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),

              // Subtitle
              Text(
                isVideo ? 'Incoming Video Call' : 'Incoming Audio Call',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: Colors.white54,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 36),

              // Pulsing avatar
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer ring
                      Transform.scale(
                        scale: _pulse.value * 1.28,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                      // Middle ring
                      Transform.scale(
                        scale: _pulse.value * 1.12,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.primary.withValues(alpha: 0.2),
                          ),
                        ),
                      ),
                      // Avatar
                      CircleAvatar(
                        radius: 60,
                        backgroundColor: AppTheme.primary,
                        child: Text(
                          initial,
                          style: GoogleFonts.inter(
                            fontSize: 44,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 36),

              // Caller name
              Text(
                widget.event.callerUsername,
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'sandesh',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Colors.white38,
                ),
              ),

              const Spacer(flex: 3),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(
                    icon: Icons.call_end_rounded,
                    label: 'Decline',
                    color: AppTheme.danger,
                    onTap: _handling ? null : _reject,
                  ),
                  _ActionButton(
                    icon: isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                    label: 'Accept',
                    color: AppTheme.primary,
                    onTap: _handling ? null : _accept,
                  ),
                ],
              ),

              const SizedBox(height: 52),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: onTap == null ? color.withValues(alpha: 0.4) : color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            color: Colors.white70,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
