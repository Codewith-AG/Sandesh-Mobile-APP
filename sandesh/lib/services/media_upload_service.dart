import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_compress/video_compress.dart';

/// Central service for compressing and uploading media to Supabase Storage.
///
/// Buckets required in Supabase dashboard (both public):
///   - `avatars`    (max 2 MB)
///   - `chat_media` (max 50 MB)
class MediaUploadService {
  static final MediaUploadService _instance = MediaUploadService._internal();
  factory MediaUploadService() => _instance;
  MediaUploadService._internal();

  final SupabaseClient _client = Supabase.instance.client;

  // ──────────────────────────── Avatar ────────────────────────────

  /// Compress [imageFile] to ≤256×256 JPEG at 75% quality then upload to
  /// the `avatars` bucket.  Returns the public URL.
  Future<String> uploadAvatar(File imageFile, String username) async {
    // Compress
    final tempDir = await getTemporaryDirectory();
    final destPath = p.join(tempDir.path, 'avatar_$username.jpg');

    final compressed = await FlutterImageCompress.compressAndGetFile(
      imageFile.absolute.path,
      destPath,
      minWidth: 256,
      minHeight: 256,
      quality: 75,
      format: CompressFormat.jpeg,
    );

    final uploadFile = File(compressed?.path ?? imageFile.path);
    final storagePath = 'avatars/$username.jpg';

    await _client.storage.from('avatars').upload(
          storagePath,
          uploadFile,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true, // overwrite on re-upload
          ),
        );

    final url = _client.storage.from('avatars').getPublicUrl(storagePath);
    // Bust CDN cache with a timestamp so the new image shows immediately
    return '$url?t=${DateTime.now().millisecondsSinceEpoch}';
  }

  // ──────────────────────────── Chat Image ────────────────────────────

  /// Compress [imageFile] to max 1200px wide at 60% quality then upload to
  /// the `chat_media` bucket.  Returns the public URL.
  Future<String> uploadChatImage(File imageFile) async {
    final tempDir = await getTemporaryDirectory();
    final fileName = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = p.join(tempDir.path, fileName);

    final compressed = await FlutterImageCompress.compressAndGetFile(
      imageFile.absolute.path,
      destPath,
      minWidth: 1200,
      minHeight: 1200,
      quality: 60,
      format: CompressFormat.jpeg,
    );

    final uploadFile = File(compressed?.path ?? imageFile.path);
    final storagePath = 'images/$fileName';

    await _client.storage.from('chat_media').upload(
          storagePath,
          uploadFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );

    return _client.storage.from('chat_media').getPublicUrl(storagePath);
  }

  // ──────────────────────────── Chat Video ────────────────────────────

  /// Compress [videoFile] to medium quality using VideoCompress then upload.
  /// Returns the public URL.
  Future<String> uploadChatVideo(
    File videoFile, {
    void Function(double progress)? onProgress,
  }) async {
    final subscription = VideoCompress.compressProgress$.subscribe((progress) {
      onProgress?.call(progress / 100);
    });

    try {
      final info = await VideoCompress.compressVideo(
        videoFile.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );

      final uploadFile = File(info?.path ?? videoFile.path);
      final fileName = 'vid_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final storagePath = 'videos/$fileName';

      await _client.storage.from('chat_media').upload(
            storagePath,
            uploadFile,
            fileOptions: const FileOptions(contentType: 'video/mp4'),
          );

      return _client.storage.from('chat_media').getPublicUrl(storagePath);
    } finally {
      subscription.unsubscribe();
      await VideoCompress.cancelCompression();
    }
  }

  // ──────────────────────────── Document ────────────────────────────

  /// Upload a document file as-is (no compression).  Returns the public URL.
  Future<String> uploadDocument(File file, String fileName) async {
    final ext = p.extension(fileName).toLowerCase();
    final contentType = _contentTypeForExt(ext);
    final storagePath = 'docs/${DateTime.now().millisecondsSinceEpoch}_$fileName';

    await _client.storage.from('chat_media').upload(
          storagePath,
          file,
          fileOptions: FileOptions(contentType: contentType),
        );

    return _client.storage.from('chat_media').getPublicUrl(storagePath);
  }

  String _contentTypeForExt(String ext) {
    switch (ext) {
      case '.pdf':
        return 'application/pdf';
      case '.doc':
      case '.docx':
        return 'application/msword';
      case '.xls':
      case '.xlsx':
        return 'application/vnd.ms-excel';
      case '.txt':
        return 'text/plain';
      case '.zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
}
