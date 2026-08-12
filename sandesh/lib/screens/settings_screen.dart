import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import '../services/update_preferences.dart';
import 'profile_screen.dart';
import 'update_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isDarkMode = false;
  bool _autoUpdate = true;
  bool _wifiOnly = true;
  String _appVersion = '';
  String _lastCheckText = 'Never';
  final UpdatePreferences _updatePrefs = UpdatePreferences();

  @override
  void initState() {
    super.initState();
    _isDarkMode = themeNotifier.value == ThemeMode.dark;
    _loadUpdatePrefs();
    _loadAppVersion();
  }

  Future<void> _loadUpdatePrefs() async {
    final auto = await _updatePrefs.autoUpdateEnabled;
    final wifi = await _updatePrefs.wifiOnlyEnabled;
    final lastCheck = await _updatePrefs.lastCheckTime;
    setState(() {
      _autoUpdate = auto;
      _wifiOnly = wifi;
      if (lastCheck != null) {
        _lastCheckText = DateFormat('MMM d, yyyy – h:mm a').format(lastCheck);
      }
    });
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = '${info.version} (${info.buildNumber})';
    });
  }

  void _toggleDarkMode(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('isDarkMode', value);
    setState(() {
      _isDarkMode = value;
    });
    themeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
  }

  void _toggleAutoUpdate(bool value) async {
    await _updatePrefs.setAutoUpdate(value);
    setState(() => _autoUpdate = value);
  }

  void _toggleWifiOnly(bool value) async {
    await _updatePrefs.setWifiOnly(value);
    setState(() => _wifiOnly = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: GoogleFonts.outfit()),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: cs.primary,
              child: Icon(Icons.person, color: cs.onPrimary),
            ),
            title: Text('Profile',
                style: GoogleFonts.outfit(
                    fontSize: 18, fontWeight: FontWeight.w500)),
            subtitle: Text('Change your name, about, or avatar',
                style: GoogleFonts.outfit(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
          const Divider(),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Appearance',
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: Text('Dark Mode', style: GoogleFonts.outfit(fontSize: 16)),
            subtitle: Text('Enable dark theme across the app',
                style: GoogleFonts.outfit(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            value: _isDarkMode,
            onChanged: _toggleDarkMode,
            activeThumbColor: cs.primary,
            activeTrackColor: cs.primaryContainer,
          ),
          const Divider(),
          const SizedBox(height: 16),
          // ── App Updates section ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'App Updates',
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: Text('Auto-update Sandesh',
                style: GoogleFonts.outfit(fontSize: 16)),
            subtitle: Text('Automatically download and install updates',
                style: GoogleFonts.outfit(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            value: _autoUpdate,
            onChanged: _toggleAutoUpdate,
            activeThumbColor: cs.primary,
            activeTrackColor: cs.primaryContainer,
          ),
          SwitchListTile(
            title: Text('Update using Wi-Fi only',
                style: GoogleFonts.outfit(fontSize: 16)),
            subtitle: Text('Only download updates over Wi-Fi',
                style: GoogleFonts.outfit(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            value: _wifiOnly,
            onChanged: _toggleWifiOnly,
            activeThumbColor: cs.primary,
            activeTrackColor: cs.primaryContainer,
          ),
          ListTile(
            leading: Icon(Icons.system_update, color: cs.primary),
            title: Text('Check for updates',
                style: GoogleFonts.outfit(fontSize: 16)),
            trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UpdateScreen()),
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.info_outline, color: cs.primary),
            title: Text('Current version',
                style: GoogleFonts.outfit(fontSize: 16)),
            subtitle: Text(_appVersion,
                style: GoogleFonts.outfit(
                    color: cs.onSurfaceVariant, fontSize: 14)),
          ),
          ListTile(
            leading: Icon(Icons.schedule, color: cs.primary),
            title: Text('Last update check',
                style: GoogleFonts.outfit(fontSize: 16)),
            subtitle: Text(_lastCheckText,
                style: GoogleFonts.outfit(
                    color: cs.onSurfaceVariant, fontSize: 14)),
          ),
          const SizedBox(height: 32),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Made with ',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Icon(
                  Icons.favorite,
                  color: Colors.red,
                  size: 16,
                ),
                Text(
                  ' in India',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
