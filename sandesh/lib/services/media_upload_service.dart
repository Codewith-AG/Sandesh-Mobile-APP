import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_compress/video_compress.dart';

/// Central service for compressing and uploading media to Supabase Storage.
///
/// Buckets required in Supabase dashboard:
///   - `avatars`    (PUBLIC, max 2 MB)
///   - `chat_media` (PRIVATE, max 50 MB) — readable only via signed URLs
class MediaUploadService {
  // ── Hard limits enforced client-side ──────────────────────────────────────
  static const int _maxAvatarBytes = 2 * 1024 * 1024;     // 2 MB
  static const int _maxImageBytes = 10 * 1024 * 1024;     // 10 MB
  static const int _maxVideoBytes = 60 * 1024 * 1024;     // 60 MB
  static const int _maxDocBytes = 30 * 1024 * 1024;       // 30 MB

  // Signed-URL lifetime for chat media. 24h is long enough for the receiver to
  // come online + auto-download, short enough to stop public link sharing.
  static const int _signedUrlSeconds = 24 * 60 * 60;

  // Allowed document extensions.
  static const Set<String> _allowedDocExts = {
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.txt', '.zip', '.rtf', '.csv', '.png', '.jpg', '.jpeg',
  };

  static final RegExp _filenameSanitizer = RegExp(r'[^A-Za-z0-9._-]');
  static final MediaUploadService _instance = MediaUploadService._internal();
  factory MediaUploadService() => _instance;
  MediaUploadService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  final Random _rand = Random.secure();

  /// Generates an unguessable filename to prevent path-guessing attacks.
  String _uuidLikeId() {
    final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Returns the storage prefix for the current user — RLS uses this to
  /// scope writes/reads. Falls back to "shared" only if logged-out (which
  /// should not happen during chat usage).
  Future<String> _myUsernamePrefix() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('username') ?? 'shared';
    return raw.toLowerCase().replaceAll(_filenameSanitizer, '_');
  }

  String _sanitizeBaseName(String fileName) {
    // Strip any path components from a user-supplied name and limit length.
    final base = p.basename(fileName);
    final cleaned = base.replaceAll(_filenameSanitizer, '_');
    return cleaned.length > 80 ? cleaned.substring(cleaned.length - 80) : cleaned;
  }

  void _checkSize(File f, int max, String label) {
    final len = f.lengthSync();
    if (len > max) {
      throw Exception('$label is too large (${(len / 1048576).toStringAsFixed(1)} MB). '
          'Max allowed: ${(max / 1048576).toStringAsFixed(0)} MB.');
    }
  }

  // ──────────────────────────── Avatar ────────────────────────────

  /// Compress [imageFile] to ≤256×256 JPEG at 75% quality then upload to
  /// the `avatars` bucket. Returns the public URL.
  Future<String> uploadAvatar(File imageFile, String username) async {
    _checkSize(imageFile, _maxAvatarBytes, 'Avatar');

    final tempDir = await getTemporaryDirectory();
    final safeName = username.toLowerCase().replaceAll(_filenameSanitizer, '_');
    final destPath = p.join(tempDir.path, 'avatar_$safeName.jpg');

    final compressed = await FlutterImageCompress.compressAndGetFile(
      imageFile.absolute.path,
      destPath,
      minWidth: 256,
      minHeight: 256,
      quality: 75,
      format: CompressFormat.jpeg,
    );

    final uploadFile = File(compressed?.path ?? imageFile.path);
    final storagePath = '$safeName.jpg';

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
  /// the `chat_media` bucket. Returns a SIGNED URL (24h) so the bucket can be
  /// kept private — only the receiver who got the URL via the message can read.
  Future<String> uploadChatImage(File imageFile) async {
    _checkSize(imageFile, _maxImageBytes, 'Image');

    final tempDir = await getTemporaryDirectory();
    final id = _uuidLikeId();
    final fileName = '$id.jpg';
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
    // Scope under the sender's username so storage RLS can enforce
    // "you can only INSERT under your own folder".
    final prefix = await _myUsernamePrefix();
    final storagePath = '$prefix/images/$fileName';

    await _client.storage.from('chat_media').upload(
          storagePath,
          uploadFile,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );

    return await _client.storage
        .from('chat_media')
        .createSignedUrl(storagePath, _signedUrlSeconds);
  }

  // ──────────────────────────── Chat Video ────────────────────────────

  /// Compress [videoFile] to medium quality using VideoCompress then upload.
  /// Returns a SIGNED URL (24h).
  Future<String> uploadChatVideo(
    File videoFile, {
    void Function(double progress)? onProgress,
  }) async {
    _checkSize(videoFile, _maxVideoBytes, 'Video');

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
      final id = _uuidLikeId();
      final fileName = '$id.mp4';
      final prefix = await _myUsernamePrefix();
      final storagePath = '$prefix/videos/$fileName';

      await _client.storage.from('chat_media').upload(
            storagePath,
            uploadFile,
            fileOptions: const FileOptions(contentType: 'video/mp4'),
          );

      return await _client.storage
          .from('chat_media')
          .createSignedUrl(storagePath, _signedUrlSeconds);
    } finally {
      subscription.unsubscribe();
      await VideoCompress.cancelCompression();
    }
  }

  // ──────────────────────────── Document ────────────────────────────

  /// Upload a document file as-is (no compression). Returns a SIGNED URL (24h).
  Future<String> uploadDocument(File file, String fileName) async {
    _checkSize(file, _maxDocBytes, 'Document');

    final ext = p.extension(fileName).toLowerCase();
    if (!_allowedDocExts.contains(ext)) {
      throw Exception('File type "$ext" is not allowed.');
    }
    final contentType = _contentTypeForExt(ext);

    final id = _uuidLikeId();
    final safeName = _sanitizeBaseName(fileName);
    final prefix = await _myUsernamePrefix();
    final storagePath = '$prefix/docs/${id}_$safeName';

    await _client.storage.from('chat_media').upload(
          storagePath,
          file,
          fileOptions: FileOptions(contentType: contentType),
        );

    return await _client.storage
        .from('chat_media')
        .createSignedUrl(storagePath, _signedUrlSeconds);
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
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }

  // ──────────────────────────── Auto-Download (Receiver Side) ────────────────────────────

  /// Downloads a media file from [url] and saves it to the app's documents
  /// directory.  Returns the absolute local path on success, or null on failure.
  Future<String?> downloadAndSave(String url, String fileName) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = p.join(dir.path, 'sandesh_media', fileName);
      final saveFile = File(savePath);

      // Ensure directory exists
      await saveFile.parent.create(recursive: true);

      // Skip if already downloaded
      if (await saveFile.exists()) return savePath;

      final dio = Dio();
      await dio.download(url, savePath,
          options: Options(receiveTimeout: const Duration(seconds: 60)));

      debugPrint('Downloaded media to $savePath');
      return savePath;
    } catch (e) {
      debugPrint('downloadAndSave error: $e');
      return null;
    }
  }

  /// Extracts the Supabase storage path from a public URL and deletes that
  /// object from the given [bucket].
  ///
  /// Supabase public URL format:
  ///   `https://<project>.supabase.co/storage/v1/object/public/<bucket>/<storagePath>`
  Future<void> deleteFromStorage(String publicUrl, String bucket) async {
    try {
      // Parse the storage path from the public URL
      final uri = Uri.parse(publicUrl);
      // path segments: ['', 'storage', 'v1', 'object', 'public', bucket, ...rest]
      final segments = uri.pathSegments;
      final bucketIndex = segments.indexOf(bucket);
      if (bucketIndex == -1 || bucketIndex + 1 >= segments.length) return;

      final storagePath = segments.sublist(bucketIndex + 1).join('/');
      await _client.storage.from(bucket).remove([storagePath]);
      debugPrint('Deleted from Supabase Storage: $bucket/$storagePath');
    } catch (e) {
      debugPrint('deleteFromStorage error: $e');
    }
  }
}

