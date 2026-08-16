import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/notification_prefs.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  bool _isLoading = true;
  /// Cached username so we don't re-query `profiles` on every toggle.
  String? _username;
  bool _messagesEnabled = true;
  bool _groupsEnabled = true;
  bool _callsEnabled = true;
  bool _soundsEnabled = true;
  bool _vibrateEnabled = true;

  @override
  void initState() {
    super.initState();
    _seedFromCache(); // instant paint from local cache (no network spinner)
    _loadSettings(); // reconcile with the server in the background
  }

  /// Paint the toggles instantly from the local cache so the screen opens with
  /// no spinner; [_loadSettings] then reconciles with the server in the
  /// background.
  Future<void> _seedFromCache() async {
    final results = await Future.wait([
      NotificationPrefs.messagesEnabled(),
      NotificationPrefs.groupsEnabled(),
      NotificationPrefs.callsEnabled(),
      NotificationPrefs.soundsEnabled(),
      NotificationPrefs.vibrateEnabled(),
    ]);
    if (!mounted) return;
    setState(() {
      _messagesEnabled = results[0];
      _groupsEnabled = results[1];
      _callsEnabled = results[2];
      _soundsEnabled = results[3];
      _vibrateEnabled = results[4];
      _isLoading = false;
    });
  }

  /// Resolves the current username once and caches it. Prefers the value stored
  /// at login (SharedPreferences) and only falls back to a `profiles` query if
  /// that's missing — so toggling a switch no longer costs a network round-trip
  /// just to look the username up.
  Future<String?> _resolveUsername() async {
    if (_username != null && _username!.isNotEmpty) return _username;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('username');
    if (cached != null && cached.isNotEmpty) {
      _username = cached;
      return _username;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;
    final profile = await Supabase.instance.client
        .from('profiles')
        .select('username')
        .eq('id', user.id)
        .maybeSingle();
    _username = profile?['username'] as String?;
    return _username;
  }

  Future<void> _loadSettings() async {
    try {
      final username = await _resolveUsername();
      if (username == null) return;

      final data = await Supabase.instance.client
          .from('notification_settings')
          .select()
          .eq('username', username)
          .maybeSingle();

      if (data != null && mounted) {
        setState(() {
          _messagesEnabled = data['messages_enabled'] ?? true;
          _groupsEnabled = data['groups_enabled'] ?? true;
          _callsEnabled = data['calls_enabled'] ?? true;
          _soundsEnabled = data['sounds_enabled'] ?? true;
          _vibrateEnabled = data['vibrate_enabled'] ?? true;
        });
      }

      // Mirror the loaded settings into the local cache so the realtime /
      // notification / call code paths can read them without a network call.
      await NotificationPrefs.cacheAll(
        messages: _messagesEnabled,
        groups: _groupsEnabled,
        calls: _callsEnabled,
        sounds: _soundsEnabled,
        vibrate: _vibrateEnabled,
      );
    } catch (e) {
      debugPrint('Error loading notification settings: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateSetting(String key, bool value) async {
    // Optimistic UI update
    setState(() {
      switch (key) {
        case 'messages_enabled': _messagesEnabled = value; break;
        case 'groups_enabled': _groupsEnabled = value; break;
        case 'calls_enabled': _callsEnabled = value; break;
        case 'sounds_enabled': _soundsEnabled = value; break;
        case 'vibrate_enabled': _vibrateEnabled = value; break;
      }
    });

    try {
      final username = await _resolveUsername();
      if (username == null) return;

      await Supabase.instance.client
          .from('notification_settings')
          .upsert({
            'username': username,
            key: value,
            'updated_at': DateTime.now().toIso8601String(),
          });

      // Keep the local cache in sync so the change takes effect immediately.
      await NotificationPrefs.setOne(key, value);
    } catch (e) {
      debugPrint('Error saving notification setting: $e');
      // Revert on failure
      setState(() {
        switch (key) {
          case 'messages_enabled': _messagesEnabled = !value; break;
          case 'groups_enabled': _groupsEnabled = !value; break;
          case 'calls_enabled': _callsEnabled = !value; break;
          case 'sounds_enabled': _soundsEnabled = !value; break;
          case 'vibrate_enabled': _vibrateEnabled = !value; break;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Notifications', style: GoogleFonts.inter()),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'MESSAGE NOTIFICATIONS',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: cs.primary,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: Text('1-on-1 Messages', style: GoogleFonts.inter(fontSize: 16)),
                  subtitle: Text('Show notifications for direct messages',
                      style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
                  value: _messagesEnabled,
                  onChanged: (v) => _updateSetting('messages_enabled', v),
                  activeThumbColor: cs.primary,
                  activeTrackColor: cs.primaryContainer,
                ),
                SwitchListTile(
                  title: Text('Group Messages', style: GoogleFonts.inter(fontSize: 16)),
                  subtitle: Text('Show notifications for group chats',
                      style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
                  value: _groupsEnabled,
                  onChanged: (v) => _updateSetting('groups_enabled', v),
                  activeThumbColor: cs.primary,
                  activeTrackColor: cs.primaryContainer,
                ),
                const Divider(),
                const SizedBox(height: 16),
                
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'CALL NOTIFICATIONS',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: cs.primary,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: Text('Incoming Calls', style: GoogleFonts.inter(fontSize: 16)),
                  subtitle: Text('Ring and show incoming call screens',
                      style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
                  value: _callsEnabled,
                  onChanged: (v) => _updateSetting('calls_enabled', v),
                  activeThumbColor: cs.primary,
                  activeTrackColor: cs.primaryContainer,
                ),
                const Divider(),
                const SizedBox(height: 16),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'IN-APP ALERTS',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: cs.primary,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: Text('In-App Sounds', style: GoogleFonts.inter(fontSize: 16)),
                  subtitle: Text('Play sounds when sending/receiving messages',
                      style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
                  value: _soundsEnabled,
                  onChanged: (v) => _updateSetting('sounds_enabled', v),
                  activeThumbColor: cs.primary,
                  activeTrackColor: cs.primaryContainer,
                ),
                SwitchListTile(
                  title: Text('Vibrate', style: GoogleFonts.inter(fontSize: 16)),
                  subtitle: Text('Vibrate device on new messages and calls',
                      style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
                  value: _vibrateEnabled,
                  onChanged: (v) => _updateSetting('vibrate_enabled', v),
                  activeThumbColor: cs.primary,
                  activeTrackColor: cs.primaryContainer,
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
