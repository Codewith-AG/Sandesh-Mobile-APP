import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';

/// Full-screen "review before send" screen for a captured/picked photo or video.
///
/// Mirrors `Sandesh_UI/video-sharing-ui-3.html`: a black canvas, a header with a
/// close button and a "Send to <name>" label, the media filling the screen
/// (video autoplays muted + looped), and a footer with a translucent glass
/// caption field and a circular accent send button.
///
/// Returns via `Navigator.pop`:
///   * a `String` caption (possibly empty `''`) when the user taps **Send**
///   * `null` when the user cancels / backs out
class MediaPreviewScreen extends StatefulWidget {
  final File file;
  final bool isVideo;
  final String sendToLabel;

  const MediaPreviewScreen({
    super.key,
    required this.file,
    required this.sendToLabel,
    this.isVideo = false,
  });

  @override
  State<MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<MediaPreviewScreen> {
  final _captionController = TextEditingController();
  VideoPlayerController? _video;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    final controller = VideoPlayerController.file(widget.file);
    _video = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0); // muted preview, like the reference
      await controller.play();
      if (mounted) setState(() => _videoReady = true);
    } catch (_) {
      if (mounted) setState(() => _videoReady = false);
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    _video?.dispose();
    super.dispose();
  }

  void _send() => Navigator.of(context).pop(_captionController.text.trim());
  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final topPad = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Media (video autoplays muted/looped; image is contained) ──
          Center(child: _buildMedia()),

          // ── Header: close + "Send to <name>" ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: topPad + 8,
                left: 12,
                right: 12,
                bottom: 12,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  _circleButton(Icons.close_rounded, _cancel),
                  Expanded(
                    child: Text(
                      'Send to ${widget.sendToLabel}',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 40), // balances the close button
                ],
              ),
            ),
          ),

          // ── Footer: glass caption field + circular accent send button ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: bottomInset + bottomPad + 16,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2)),
                      ),
                      child: TextField(
                        controller: _captionController,
                        minLines: 1,
                        maxLines: 4,
                        cursorColor: Colors.white,
                        style: GoogleFonts.inter(
                            color: Colors.white, fontSize: 15),
                        decoration: InputDecoration(
                          hintText: 'Add a caption...',
                          hintStyle: GoogleFonts.inter(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 15),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _send,
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.send_rounded,
                          color: Colors.white, size: 24),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _buildMedia() {
    if (widget.isVideo) {
      final video = _video;
      if (video != null && _videoReady && video.value.isInitialized) {
        return AspectRatio(
          aspectRatio: video.value.aspectRatio,
          child: VideoPlayer(video),
        );
      }
      return const CircularProgressIndicator(color: Colors.white);
    }
    return Image.file(widget.file, fit: BoxFit.contain);
  }
}
