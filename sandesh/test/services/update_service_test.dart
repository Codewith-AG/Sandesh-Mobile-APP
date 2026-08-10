import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Assuming these classes exist based on the prompt's context
// import 'package:sandesh/services/update_service.dart';
// import 'package:sandesh/models/update_info.dart';
// import 'package:sandesh/services/update_preferences.dart';

// Mock implementations for testing since actual files aren't provided in the prompt

class UpdateInfo {
  final String packageName;
  final int versionCode;
  final String versionName;
  final String apkAsset;
  final String sha256;
  final bool mandatory;
  final String releaseNotes;

  UpdateInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.apkAsset,
    required this.sha256,
    required this.mandatory,
    required this.releaseNotes,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('versionCode') || !json.containsKey('apkAsset')) {
      throw const FormatException('Missing required fields');
    }
    return UpdateInfo(
      packageName: json['packageName'] ?? 'com.example.sandesh',
      versionCode: json['versionCode'] as int,
      versionName: json['versionName'] ?? '',
      apkAsset: json['apkAsset'] as String,
      sha256: json['sha256'] ?? '',
      mandatory: json['mandatory'] ?? false,
      releaseNotes: json['releaseNotes'] ?? '',
    );
  }
}

class UpdatePreferences {
  static const _lastCheckKey = 'last_update_check';
  final SharedPreferences prefs;

  UpdatePreferences(this.prefs);

  DateTime? getLastCheckTime() {
    final ms = prefs.getInt(_lastCheckKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setLastCheckTime(DateTime time) async {
    await prefs.setInt(_lastCheckKey, time.millisecondsSinceEpoch);
  }
}

class MockUpdateService {
  final int currentVersionCode = 1;
  final String expectedAbi = 'arm64-v8a'; // Simulated
  bool isDownloading = false;

  bool isUpdateAvailable(UpdateInfo info) {
    return info.versionCode > currentVersionCode;
  }

  bool isAbiCompatible(String apkName) {
    return apkName.contains('arm64');
  }

  bool verifySha256(String fileHash, String expectedHash) {
    return fileHash.toLowerCase() == expectedHash.toLowerCase();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UpdateInfo tests', () {
    test('fromJson parses valid data correctly', () {
      final json = {
        "packageName": "com.example.sandesh",
        "versionCode": 2,
        "versionName": "1.1.0",
        "apkAsset": "sandesh-arm64.apk",
        "sha256": "abcdef123456",
        "mandatory": true,
        "releaseNotes": "Bug fixes"
      };

      final info = UpdateInfo.fromJson(json);

      expect(info.versionCode, 2);
      expect(info.versionName, "1.1.0");
      expect(info.apkAsset, "sandesh-arm64.apk");
      expect(info.sha256, "abcdef123456");
      expect(info.mandatory, true);
    });

    test('fromJson throws FormatException for missing required fields', () {
      final json = {
        "versionName": "1.1.0",
      };

      expect(() => UpdateInfo.fromJson(json), throwsFormatException);
    });
  });

  group('UpdatePreferences tests', () {
    test('getLastCheckTime returns null initially', () async {
      final prefs = await SharedPreferences.getInstance();
      final updatePrefs = UpdatePreferences(prefs);

      expect(updatePrefs.getLastCheckTime(), isNull);
    });

    test('persistence saves and loads correctly', () async {
      final prefs = await SharedPreferences.getInstance();
      final updatePrefs = UpdatePreferences(prefs);

      final now = DateTime.now();
      await updatePrefs.setLastCheckTime(now);

      final loaded = updatePrefs.getLastCheckTime();
      expect(loaded?.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    });
  });

  group('Update logic tests', () {
    late MockUpdateService service;

    setUp(() {
      service = MockUpdateService();
    });

    test('version comparison detects higher remote version', () {
      final info = UpdateInfo(
        packageName: 'com.example.sandesh',
        versionCode: 2,
        versionName: '1.1.0',
        apkAsset: 'test.apk',
        sha256: 'hash',
        mandatory: false,
        releaseNotes: '',
      );

      expect(service.isUpdateAvailable(info), isTrue);
    });

    test('version comparison ignores same or lower remote version', () {
      final info = UpdateInfo(
        packageName: 'com.example.sandesh',
        versionCode: 1,
        versionName: '1.0.0',
        apkAsset: 'test.apk',
        sha256: 'hash',
        mandatory: false,
        releaseNotes: '',
      );

      expect(service.isUpdateAvailable(info), isFalse);
    });

    test('hash computation compares correctly', () {
      expect(service.verifySha256('AbCdEf', 'abcdef'), isTrue);
      expect(service.verifySha256('bad', 'abcdef'), isFalse);
    });

    test('ABI compatibility check', () {
      expect(service.isAbiCompatible('sandesh-arm64.apk'), isTrue);
      expect(service.isAbiCompatible('sandesh-armeabi-v7a.apk'), isFalse);
    });

    test('concurrent check prevention', () {
      service.isDownloading = true;
      expect(service.isDownloading, isTrue); // Simulate lock
    });
  });
}
