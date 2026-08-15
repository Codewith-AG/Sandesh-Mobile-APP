import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Local, fast-access cache for the user's notification toggles.
///
/// The [NotificationSettingsScreen] persists each toggle here (and to Supabase)
/// so the realtime / local-notification / call code paths can read the user's
/// preference synchronously-ish (a single SharedPreferences read) instead of a
/// network round-trip for every incoming message.
///
/// All toggles default to `true` (ON) when nothing has been cached yet, which
/// matches the server-side column defaults in `notification_settings`.
class NotificationPrefs {
  NotificationPrefs._();

  // SharedPreferences keys (local mirror of the notification_settings columns).
  static const String kMessages = 'notif_messages_enabled';
  static const String kGroups = 'notif_groups_enabled';
  static const String kCalls = 'notif_calls_enabled';
  static const String kSounds = 'notif_sounds_enabled';
  static const String kVibrate = 'notif_vibrate_enabled';

  /// Maps the server column name (used by the settings screen) to the local key.
  static const Map<String, String> _serverKeyToLocal = {
    'messages_enabled': kMessages,
    'groups_enabled': kGroups,
    'calls_enabled': kCalls,
    'sounds_enabled': kSounds,
    'vibrate_enabled': kVibrate,
  };

  static Future<bool> _get(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? true; // default ON
  }

  static Future<bool> messagesEnabled() => _get(kMessages);
  static Future<bool> groupsEnabled() => _get(kGroups);
  static Future<bool> callsEnabled() => _get(kCalls);
  static Future<bool> soundsEnabled() => _get(kSounds);
  static Future<bool> vibrateEnabled() => _get(kVibrate);

  /// Persist a single toggle locally, keyed by its server column name
  /// (e.g. `'messages_enabled'`). Called by the settings screen alongside the
  /// Supabase upsert so the cache never drifts from what the user just chose.
  static Future<void> setOne(String serverKey, bool value) async {
    final localKey = _serverKeyToLocal[serverKey];
    if (localKey == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(localKey, value);
  }

  /// Cache the full set of toggles at once (used after a server load).
  static Future<void> cacheAll({
    required bool messages,
    required bool groups,
    required bool calls,
    required bool sounds,
    required bool vibrate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kMessages, messages);
    await prefs.setBool(kGroups, groups);
    await prefs.setBool(kCalls, calls);
    await prefs.setBool(kSounds, sounds);
    await prefs.setBool(kVibrate, vibrate);
  }

  /// Pull the latest notification settings from Supabase and cache them locally.
  /// Fire-and-forget safe — call on login / service init so a freshly installed
  /// (or reinstalled) device honours the user's saved preferences immediately.
  static Future<void> syncFromServer() async {
    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) return;

      final profile = await client
          .from('profiles')
          .select('username')
          .eq('id', user.id)
          .maybeSingle();
      final username = profile?['username'] as String?;
      if (username == null) return;

      final data = await client
          .from('notification_settings')
          .select()
          .eq('username', username)
          .maybeSingle();
      if (data == null) return;

      await cacheAll(
        messages: data['messages_enabled'] ?? true,
        groups: data['groups_enabled'] ?? true,
        calls: data['calls_enabled'] ?? true,
        sounds: data['sounds_enabled'] ?? true,
        vibrate: data['vibrate_enabled'] ?? true,
      );
    } catch (e) {
      debugPrint('NotificationPrefs.syncFromServer error: $e');
    }
  }
}
