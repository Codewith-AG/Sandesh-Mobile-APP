import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/update_info.dart';

class UpdatePreferences {
  static const _keyAutoUpdate = 'update_auto_update';
  static const _keyWifiOnly = 'update_wifi_only';
  static const _keyLastCheckTime = 'update_last_check_time';
  static const _keyLastCheckResult = 'update_last_check_result';
  static const _keyDismissedVersion = 'update_dismissed_version';

  Future<bool> get autoUpdateEnabled async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoUpdate) ?? true;
  }

  Future<void> setAutoUpdate(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoUpdate, value);
  }

  Future<bool> get wifiOnlyEnabled async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyWifiOnly) ?? true;
  }

  Future<void> setWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyWifiOnly, value);
  }

  Future<DateTime?> get lastCheckTime async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_keyLastCheckTime);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setLastCheckTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastCheckTime, time.millisecondsSinceEpoch);
  }

  Future<UpdateInfo?> get cachedUpdateInfo async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyLastCheckResult);
    if (jsonStr == null) return null;
    try {
      return UpdateInfo.fromCacheJson(jsonDecode(jsonStr));
    } catch (e) {
      return null;
    }
  }

  Future<void> setCachedUpdateInfo(UpdateInfo? info) async {
    final prefs = await SharedPreferences.getInstance();
    if (info == null) {
      await prefs.remove(_keyLastCheckResult);
    } else {
      await prefs.setString(_keyLastCheckResult, jsonEncode(info.toJson()));
    }
  }

  Future<int?> get dismissedVersionCode async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyDismissedVersion);
  }

  Future<void> setDismissedVersion(int? versionCode) async {
    final prefs = await SharedPreferences.getInstance();
    if (versionCode == null) {
      await prefs.remove(_keyDismissedVersion);
    } else {
      await prefs.setInt(_keyDismissedVersion, versionCode);
    }
  }

  Future<bool> shouldCheckForUpdate() async {
    final lastCheck = await lastCheckTime;
    if (lastCheck == null) return true;
    final now = DateTime.now();
    final diff = now.difference(lastCheck);
    return diff.inHours >= 6;
  }
}
