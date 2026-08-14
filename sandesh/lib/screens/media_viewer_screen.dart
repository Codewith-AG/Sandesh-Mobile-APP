import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';

class MediaViewerScreen extends StatefulWidget {
  final String heroTag;
  final String? localPath;
  final String? networkUrl;
  final bool isVideo;

  const MediaViewerScreen({
    super.key,
    required this.heroTag,
    this.localPath,
    this.networkUrl,
    this.isVideo = false,
  });

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      if (widget.localPath != null && File(widget.localPath!).existsSync()) {
        _videoController = VideoPlayerController.file(File(widget.localPath!))
          ..initialize().then((_) {
            setState(() {});
            _videoController?.play();
            _videoController?.setLooping(true);
          });
      } else if (widget.networkUrl != null && widget.networkUrl!.startsWith('http')) {
        _videoController = VideoPlayerController.networkUrl(Uri.parse(widget.networkUrl!))
          ..initialize().then((_) {
            setState(() {});
            _videoController?.play();
            _videoController?.setLooping(true);
          });
      }
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Matches the new dark surface of incoming call
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: Hero(
          tag: widget.heroTag,
          child: InteractiveViewer(
            panEnabled: true,
            minScale: 1.0,
            maxScale: 4.0,
            child: _buildMediaContent(),
          ),
        ),
      ),
    );
  }

  Widget _buildMediaContent() {
    if (widget.isVideo) {
      if (_videoController != null && _videoController!.value.isInitialized) {
        return AspectRatio(
          aspectRatio: _videoController!.value.aspectRatio,
          child: VideoPlayer(_videoController!),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.localPath != null && File(widget.localPath!).existsSync()) {
      return Image.file(
        File(widget.localPath!),
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: 1080,
      );
    } else if (widget.networkUrl != null && widget.networkUrl!.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: widget.networkUrl!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: 1080,
        placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
        errorWidget: (context, url, error) => const Icon(Icons.broken_image_outlined, size: 80, color: Colors.white),
      );
    } else {
      return const Icon(Icons.broken_image_outlined, size: 80, color: Colors.white);
    }
  }
}
