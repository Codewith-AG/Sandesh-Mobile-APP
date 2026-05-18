import 'dart:io';
import 'package:flutter/material.dart';

class MediaViewerScreen extends StatelessWidget {
  final String heroTag;
  final String? localPath;
  final String? networkUrl;

  const MediaViewerScreen({
    super.key,
    required this.heroTag,
    this.localPath,
    this.networkUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: Hero(
          tag: heroTag,
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
    if (localPath != null && File(localPath!).existsSync()) {
      return Image.file(
        File(localPath!),
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
      );
    } else if (networkUrl != null && networkUrl!.startsWith('http')) {
      return Image.network(
        networkUrl!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
      );
    } else {
      return const Icon(Icons.broken_image_outlined, size: 80, color: Colors.white);
    }
  }
}
