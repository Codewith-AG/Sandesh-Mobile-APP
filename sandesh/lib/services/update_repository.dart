import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/update_info.dart';

class UpdateRepository {
  static const _owner = 'Codewith-AG';
  static const _repo = 'Sandesh-Releases';
  static const _apiBase = 'https://api.github.com';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 10), // GitHub CDN can be slow
    sendTimeout: const Duration(seconds: 30),
  ));

  /// Fetch the latest release from GitHub and parse update.json.
  /// Returns null if no update available, GitHub is unreachable, or on any error.
  Future<UpdateInfo?> fetchLatestRelease() async {
    try {
      final url = '$_apiBase/repos/$_owner/$_repo/releases/latest';

      Response<dynamic>? response;
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          response = await _dio.get(
            url,
            options: Options(
              headers: {'Accept': 'application/vnd.github.v3+json'},
              validateStatus: (status) => status != null && status < 500, // Handle 404/403/429 gracefully
            ),
          );

          if (response.statusCode == 200) break;
          if (response.statusCode == 403 || response.statusCode == 429) {
            debugPrint('[UpdateRepo] Rate limited (${response.statusCode})');
            return null;
          }
          if (response.statusCode == 404) {
            debugPrint('[UpdateRepo] No releases found');
            return null;
          }
        } catch (e) {
          if (attempt == 1) rethrow;
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (response == null || response.statusCode != 200) return null;

      final data = (response.data is String) 
          ? jsonDecode(response.data as String) as Map<String, dynamic>
          : response.data as Map<String, dynamic>;
      final List<dynamic> assets = data['assets'] ?? [];

      // Find update.json asset
      String? updateJsonUrl;
      for (final asset in assets) {
        if (asset['name'] == 'update.json') {
          updateJsonUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
      if (updateJsonUrl == null) {
        debugPrint('[UpdateRepo] No update.json found in release assets');
        return null;
      }

      // Download and parse update.json
      final updateResponse = await _dio.get(updateJsonUrl);
      if (updateResponse.statusCode != 200) return null;

      final updateJson = (updateResponse.data is String) 
          ? jsonDecode(updateResponse.data as String) as Map<String, dynamic>
          : updateResponse.data as Map<String, dynamic>;

      // Find APK asset download URL (support both camelCase and snake_case)
      final String apkAssetName = (updateJson['apkAsset'] ?? updateJson['apk_asset'] ?? '') as String;
      if (apkAssetName.isEmpty) {
        debugPrint('[UpdateRepo] No apkAsset specified in update.json');
        return null;
      }

      String? apkDownloadUrl;
      for (final asset in assets) {
        if (asset['name'] == apkAssetName) {
          apkDownloadUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
      if (apkDownloadUrl == null) {
        debugPrint('[UpdateRepo] APK asset "$apkAssetName" not found in release');
        return null;
      }

      // Verify HTTPS
      if (!apkDownloadUrl.startsWith('https://')) {
        debugPrint('[UpdateRepo] APK URL is not HTTPS, rejecting');
        return null;
      }

      return UpdateInfo.fromJson(updateJson, apkDownloadUrl);
    } catch (e) {
      debugPrint('[UpdateRepo] Error fetching latest release: $e');
      return null;
    }
  }

  /// Download APK to the app cache directory with progress tracking.
  ///
  /// Resumable: bytes are streamed into a `.part` file and, if a partial file
  /// from a previous interrupted attempt exists, the download continues from
  /// where it stopped using an HTTP `Range` request instead of starting over.
  /// Only once the full file is received is it promoted to the final `.apk`.
  Future<String> downloadApk(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final savePath = '${tempDir.path}/update_${info.versionCode}.apk';
    final partPath = '$savePath.part';

    final partFile = File(partPath);
    int existingBytes = 0;
    if (await partFile.exists()) {
      existingBytes = await partFile.length();
    }

    // A finished .apk from a prior attempt is stale; rebuild from scratch/part.
    final finalFile = File(savePath);
    if (await finalFile.exists()) await finalFile.delete();

    try {
      final response = await _dio.get<ResponseBody>(
        info.downloadUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: existingBytes > 0 ? {'Range': 'bytes=$existingBytes-'} : null,
          validateStatus: (s) => s != null && s < 400,
        ),
      );

      // If the server ignored the Range header (200 instead of 206), restart.
      final status = response.statusCode ?? 200;
      final bool append = status == 206;
      if (!append && existingBytes > 0) {
        if (await partFile.exists()) await partFile.delete();
        existingBytes = 0;
      }

      // Work out the total size for progress reporting.
      final contentLen = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      final total = append && contentLen > 0
          ? existingBytes + contentLen
          : (contentLen > 0 ? contentLen : info.sizeBytes);

      final sink = partFile.openSync(mode: append ? FileMode.writeOnlyAppend : FileMode.writeOnly);
      int received = existingBytes;
      try {
        await for (final chunk in response.data!.stream) {
          sink.writeFromSync(chunk);
          received += chunk.length;
          if (onProgress != null && total > 0) onProgress(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      // Promote the completed part file to the final APK path.
      await partFile.rename(savePath);
      return savePath;
    } on DioException {
      // Leave the .part file in place so a later attempt can resume it.
      rethrow;
    }
  }
}
