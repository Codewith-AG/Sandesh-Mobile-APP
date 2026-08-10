class UpdateInfo {
  final String packageName;
  final int versionCode;
  final String versionName;
  final String apkAsset;
  final String sha256;
  final bool mandatory;
  final String releaseNotes;
  final String downloadUrl;

  const UpdateInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.apkAsset,
    required this.sha256,
    this.mandatory = false,
    this.releaseNotes = '',
    required this.downloadUrl,
  });

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
