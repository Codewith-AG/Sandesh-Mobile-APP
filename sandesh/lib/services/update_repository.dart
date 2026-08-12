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
    receiveTimeout: const Duration(minutes: 5),
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

  /// Download APK to app cache directory with progress tracking.
  Future<String> downloadApk(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final savePath = '${tempDir.path}/update_${info.versionCode}.apk';

    // Delete any existing partial download
    final existing = File(savePath);
    if (await existing.exists()) await existing.delete();

    await _dio.download(
      info.downloadUrl,
      savePath,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );

    return savePath;
  }
}
