class UpdateInfo {
  final String packageName;
  final int versionCode;
  final String versionName;
  final String apkAsset;
  final String sha256;
  final bool mandatory;
  final String releaseNotes;
  final String downloadUrl;

  /// Size of the APK in bytes (0 if the release did not advertise it).
  /// Used to warn the user how much data an over-mobile-data update will use.
  final int sizeBytes;

  const UpdateInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.apkAsset,
    required this.sha256,
    this.mandatory = false,
    this.releaseNotes = '',
    required this.downloadUrl,
    this.sizeBytes = 0,
  });

  /// Human-readable APK size, e.g. "62.4 MB". Returns null when unknown.
  String? get formattedSize {
    if (sizeBytes <= 0) return null;
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = sizeBytes.toDouble();
    int unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  /// Parse update.json from GitHub release.
  /// Supports both camelCase (canonical) and snake_case keys.
  factory UpdateInfo.fromJson(Map<String, dynamic> json, String downloadUrl) {
    return UpdateInfo(
      packageName: (json['packageName'] ?? json['package_name'] ?? 'com.example.sandesh') as String,
      versionCode: _parseInt(json['versionCode'] ?? json['version_code'] ?? 0),
      versionName: (json['versionName'] ?? json['version_name'] ?? '') as String,
      apkAsset: (json['apkAsset'] ?? json['apk_asset'] ?? '') as String,
      sha256: (json['sha256'] ?? '') as String,
      mandatory: (json['mandatory'] ?? false) as bool,
      releaseNotes: (json['releaseNotes'] ?? json['release_notes'] ?? '') as String,
      downloadUrl: downloadUrl,
      sizeBytes: _parseInt(json['size'] ?? json['sizeBytes'] ?? json['apkSize'] ?? 0),
    );
  }

  /// Parse from locally cached JSON (includes downloadUrl).
  factory UpdateInfo.fromCacheJson(Map<String, dynamic> json) {
    return UpdateInfo(
      packageName: (json['packageName'] ?? json['package_name'] ?? 'com.example.sandesh') as String,
      versionCode: _parseInt(json['versionCode'] ?? json['version_code'] ?? 0),
      versionName: (json['versionName'] ?? json['version_name'] ?? '') as String,
      apkAsset: (json['apkAsset'] ?? json['apk_asset'] ?? '') as String,
      sha256: (json['sha256'] ?? '') as String,
      mandatory: (json['mandatory'] ?? false) as bool,
      releaseNotes: (json['releaseNotes'] ?? json['release_notes'] ?? '') as String,
      downloadUrl: (json['downloadUrl'] ?? json['download_url'] ?? '') as String,
      sizeBytes: _parseInt(json['size'] ?? json['sizeBytes'] ?? json['apkSize'] ?? 0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'packageName': packageName,
      'versionCode': versionCode,
      'versionName': versionName,
      'apkAsset': apkAsset,
      'sha256': sha256,
      'mandatory': mandatory,
      'releaseNotes': releaseNotes,
      'downloadUrl': downloadUrl,
      'sizeBytes': sizeBytes,
    };
  }

  UpdateInfo copyWith({
    String? packageName,
    int? versionCode,
    String? versionName,
    String? apkAsset,
    String? sha256,
    bool? mandatory,
    String? releaseNotes,
    String? downloadUrl,
    int? sizeBytes,
  }) {
    return UpdateInfo(
      packageName: packageName ?? this.packageName,
      versionCode: versionCode ?? this.versionCode,
      versionName: versionName ?? this.versionName,
      apkAsset: apkAsset ?? this.apkAsset,
      sha256: sha256 ?? this.sha256,
      mandatory: mandatory ?? this.mandatory,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      sizeBytes: sizeBytes ?? this.sizeBytes,
    );
  }

  /// Safely parse int from dynamic (handles String, int, double).
  static int _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  @override
  String toString() => 'UpdateInfo(v$versionName+$versionCode, pkg=$packageName)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UpdateInfo &&
          packageName == other.packageName &&
          versionCode == other.versionCode;

  @override
  int get hashCode => Object.hash(packageName, versionCode);
}
