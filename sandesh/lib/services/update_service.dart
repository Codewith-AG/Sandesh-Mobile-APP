import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/update_info.dart';
import 'update_preferences.dart';
import 'update_repository.dart';

enum UpdateState {
  idle,
  checking,
  updateAvailable,
  downloading,
  validating,
  readyToInstall,
  installing,
  error,
  upToDate,
}

enum UpdateCheckResult {
  updateAvailable,
  upToDate,
  error,
  throttled,
}

class UpdateValidationResult {
  final bool valid;
  final String? error;
  UpdateValidationResult({required this.valid, this.error});
}

class UpdateService {
  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._() {
    cleanup();
  }

  static const _channel = MethodChannel('com.example.sandesh/updater');
  final UpdateRepository _repository = UpdateRepository();
  final UpdatePreferences _preferences = UpdatePreferences();

  final ValueNotifier<UpdateState> state = ValueNotifier(UpdateState.idle);
  final ValueNotifier<double> downloadProgress = ValueNotifier(0.0);
  UpdateInfo? availableUpdate;
  String? _downloadedApkPath;
  bool _isChecking = false;
  bool _isDownloading = false;
  CancelToken? _cancelToken;
  String? lastError;

  /// Check for updates, respecting the 6-hour cache interval.
  /// [forceCheck] bypasses the cache (for manual "Check for updates").
  Future<UpdateCheckResult> checkForUpdate({bool forceCheck = false}) async {
    if (_isChecking) return UpdateCheckResult.throttled;
    _isChecking = true;
    state.value = UpdateState.checking;
    lastError = null;

    try {
      // Check cache interval unless force-checking
      if (!forceCheck) {
        final shouldCheck = await _preferences.shouldCheckForUpdate();
        if (!shouldCheck) {
          // Return cached result if within 6 hours
          final cached = await _preferences.cachedUpdateInfo;
          if (cached != null) {
            final pkgInfo = await PackageInfo.fromPlatform();
            final currentVersionCode = int.tryParse(pkgInfo.buildNumber) ?? 0;
            if (cached.versionCode > currentVersionCode) {
              availableUpdate = cached;
              state.value = UpdateState.updateAvailable;
              return UpdateCheckResult.updateAvailable;
            }
          }
          state.value = UpdateState.upToDate;
          return UpdateCheckResult.throttled;
        }
      }

      final info = await _repository.fetchLatestRelease();
      await _preferences.setLastCheckTime(DateTime.now());

      if (info == null) {
        // Could not reach GitHub or no releases exist — not necessarily an error
        state.value = UpdateState.upToDate;
        return UpdateCheckResult.upToDate;
      }

      final pkgInfo = await PackageInfo.fromPlatform();
      final currentVersionCode = int.tryParse(pkgInfo.buildNumber) ?? 0;

      if (info.versionCode > currentVersionCode) {
        availableUpdate = info;
        await _preferences.setCachedUpdateInfo(info);
        state.value = UpdateState.updateAvailable;
        return UpdateCheckResult.updateAvailable;
      } else {
        await _preferences.setCachedUpdateInfo(null);
        availableUpdate = null;
        state.value = UpdateState.upToDate;
        return UpdateCheckResult.upToDate;
      }
    } catch (e) {
      debugPrint('[UpdateService] Check error: $e');
      lastError = e.toString();
      state.value = UpdateState.error;
      return UpdateCheckResult.error;
    } finally {
      _isChecking = false;
    }
  }

  /// Download the update APK with progress tracking.
  Future<bool> downloadUpdate() async {
    if (_isDownloading || availableUpdate == null) return false;

    // Check WiFi preference
    final wifiOnly = await _preferences.wifiOnlyEnabled;
    if (wifiOnly) {
      final isWifi = await isWifiAvailable();
      if (!isWifi) {
        debugPrint('[UpdateService] WiFi required but not available, deferring download');
        lastError = 'Wi-Fi required for download';
        // Don't set error state — just leave as updateAvailable
        return false;
      }
    }

    _isDownloading = true;
    state.value = UpdateState.downloading;
    downloadProgress.value = 0.0;
    _cancelToken = CancelToken();

    try {
      _downloadedApkPath = await _repository.downloadApk(
        availableUpdate!,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (total > 0) {
            downloadProgress.value = received / total;
          }
        },
      );

      // Immediately validate after download
      state.value = UpdateState.validating;
      final validation = await validateDownloadedApk();
      if (validation.valid) {
        state.value = UpdateState.readyToInstall;
        return true;
      } else {
        lastError = validation.error;
        state.value = UpdateState.error;
        return false;
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        debugPrint('[UpdateService] Download cancelled');
        state.value = UpdateState.updateAvailable;
      } else {
        debugPrint('[UpdateService] Download error: $e');
        lastError = 'Download failed: ${e.message}';
        state.value = UpdateState.error;
      }
      _downloadedApkPath = null;
      return false;
    } catch (e) {
      debugPrint('[UpdateService] Download error: $e');
      lastError = 'Download failed: $e';
      state.value = UpdateState.error;
      _downloadedApkPath = null;
      return false;
    } finally {
      _isDownloading = false;
      _cancelToken = null;
    }
  }

  /// Cancel an ongoing download.
  void cancelDownload() {
    if (_isDownloading && _cancelToken != null && !_cancelToken!.isCancelled) {
      _cancelToken!.cancel('User cancelled download');
    }
  }

  /// Validate the downloaded APK: SHA-256, ABI, package name, version, signature.
  Future<UpdateValidationResult> validateDownloadedApk() async {
    if (_downloadedApkPath == null || availableUpdate == null) {
      return UpdateValidationResult(valid: false, error: 'No APK downloaded');
    }

    final file = File(_downloadedApkPath!);
    try {
      if (!await file.exists()) {
        return UpdateValidationResult(valid: false, error: 'APK file not found');
      }

      // 1. SHA-256 verification
      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes);
      if (digest.toString().toLowerCase() != availableUpdate!.sha256.toLowerCase()) {
        await _deleteFile(file);
        return UpdateValidationResult(
          valid: false,
          error: 'SHA-256 checksum mismatch — file may be corrupted or tampered',
        );
      }

      // 2. ABI compatibility check
      final abis = await _channel.invokeMethod<List<dynamic>>('getDeviceAbis');
      if (abis == null || !abis.contains('arm64-v8a')) {
        await _deleteFile(file);
        return UpdateValidationResult(
          valid: false,
          error: 'This device does not support arm64-v8a',
        );
      }

      // 3. Package name verification
      final apkPackageName = await _channel.invokeMethod<String>(
        'getApkPackageName',
        {'apkPath': _downloadedApkPath},
      );
      if (apkPackageName != 'com.example.sandesh') {
        await _deleteFile(file);
        return UpdateValidationResult(
          valid: false,
          error: 'Package name mismatch: expected com.example.sandesh, got $apkPackageName',
        );
      }

      // 4. Version code verification (must be greater than installed)
      final apkVersionCode = await _channel.invokeMethod<int>(
        'getApkVersionCode',
        {'apkPath': _downloadedApkPath},
      );
      final pkgInfo = await PackageInfo.fromPlatform();
      final currentVersionCode = int.tryParse(pkgInfo.buildNumber) ?? 0;
      if (apkVersionCode == null || apkVersionCode <= currentVersionCode) {
        await _deleteFile(file);
        return UpdateValidationResult(
          valid: false,
          error: 'Version code ($apkVersionCode) is not newer than installed ($currentVersionCode)',
        );
      }

      // 5. Signing certificate verification
      final installedSig = await _channel.invokeMethod<String>('getInstalledSignatures');
      final apkSig = await _channel.invokeMethod<String>(
        'getApkSignatures',
        {'apkPath': _downloadedApkPath},
      );
      if (installedSig != null && apkSig != null && installedSig != apkSig) {
        await _deleteFile(file);
        return UpdateValidationResult(
          valid: false,
          error: 'APK signing certificate does not match the installed app',
        );
      }

      return UpdateValidationResult(valid: true);
    } catch (e) {
      debugPrint('[UpdateService] Validation error: $e');
      await _deleteFile(file);
      return UpdateValidationResult(valid: false, error: 'Validation failed: $e');
    }
  }

  /// Check if install permission is granted.
  Future<bool> canRequestInstall() async {
    try {
      final result = await _channel.invokeMethod<bool>('canRequestInstall');
      return result ?? false;
    } catch (e) {
      debugPrint('[UpdateService] canRequestInstall error: $e');
      return false;
    }
  }

  /// Open the system settings for "Install unknown apps" permission.
  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod('openInstallPermissionSettings');
    } catch (e) {
      debugPrint('[UpdateService] openInstallPermissionSettings error: $e');
    }
  }

  /// Install the validated APK via native PackageInstaller.
  Future<void> installUpdate() async {
    if (state.value != UpdateState.readyToInstall || _downloadedApkPath == null) return;

    // Check install permission first
    final canInstall = await canRequestInstall();
    if (!canInstall) {
      lastError = 'Install permission not granted';
      return;
    }

    state.value = UpdateState.installing;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'installApk',
        {'apkPath': _downloadedApkPath},
      );
      debugPrint('[UpdateService] Install result: $result');
      // The actual install result comes via PackageInstallerReceiver.
      // The method returns immediately after committing the session.
    } catch (e) {
      debugPrint('[UpdateService] Install error: $e');
      lastError = 'Installation failed: $e';
      state.value = UpdateState.error;
    }
  }

  /// Full auto-update flow using Android WorkManager.
  /// WorkManager will handle WiFi constraints, retries, downloading, validation, and installation.
  Future<void> performAutoUpdate() async {
    if (availableUpdate == null) {
      final checkResult = await checkForUpdate();
      if (checkResult != UpdateCheckResult.updateAvailable) return;
    }
    if (availableUpdate == null) return;

    final autoUpdate = await _preferences.autoUpdateEnabled;
    if (!autoUpdate) return;

    final wifiOnly = await _preferences.wifiOnlyEnabled;
    try {
      await _channel.invokeMethod('scheduleBackgroundUpdate', {
        'downloadUrl': availableUpdate!.downloadUrl,
        'sha256': availableUpdate!.sha256,
        'versionCode': availableUpdate!.versionCode,
        'wifiOnly': wifiOnly,
      });
      debugPrint('[UpdateService] Scheduled background update via WorkManager');
    } catch (e) {
      debugPrint('[UpdateService] Failed to schedule WorkManager update: $e');
    }
  }

  /// Check if WiFi is available (non-metered connection).
  Future<bool> isWifiAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isWifiConnected');
      return result ?? false;
    } catch (e) {
      debugPrint('[UpdateService] WiFi check error: $e');
      return false;
    }
  }

  /// Clean up old downloaded APK files.
  Future<void> cleanup() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir.listSync();
      for (final file in files) {
        if (file is File &&
            file.path.endsWith('.apk') &&
            file.path.contains('update_')) {
          // Don't delete the current ready-to-install APK
          if (_downloadedApkPath != null &&
              file.path == _downloadedApkPath &&
              state.value == UpdateState.readyToInstall) {
            continue;
          }
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('[UpdateService] Cleanup error: $e');
    }
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
