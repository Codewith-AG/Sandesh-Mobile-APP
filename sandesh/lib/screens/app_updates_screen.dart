import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:intl/intl.dart';
import '../services/update_preferences.dart';
import 'update_screen.dart';

/// Dedicated "App Updates" settings screen.
///
/// Previously all of these controls lived inline on the main Settings screen.
/// They are now grouped into their own folder (just like Notification
/// Settings), reachable via a single row on the Settings screen.
class AppUpdatesScreen extends StatefulWidget {
  const AppUpdatesScreen({super.key});

  @override
  State<AppUpdatesScreen> createState() => _AppUpdatesScreenState();
}

class _AppUpdatesScreenState extends State<AppUpdatesScreen> {
  bool _autoUpdate = true;
  bool _wifiOnly = true;
  String _appVersion = '';
  String _lastCheckText = 'Never';
  final UpdatePreferences _updatePrefs = UpdatePreferences();

  @override
  void initState() {
    super.initState();
    _loadUpdatePrefs();
    _loadAppVersion();
  }

  Future<void> _loadUpdatePrefs() async {
    final auto = await _updatePrefs.autoUpdateEnabled;
    final wifi = await _updatePrefs.wifiOnlyEnabled;
    final lastCheck = await _updatePrefs.lastCheckTime;
    if (!mounted) return;
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
    if (!mounted) return;
    setState(() {
      _appVersion = '${info.version} (${info.buildNumber})';
    });
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
        title: Text('App Updates', style: GoogleFonts.inter()),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'UPDATE PREFERENCES',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: cs.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: Text('Auto-update Sandesh',
                style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text('Automatically download and install updates',
                style: GoogleFonts.inter(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            value: _autoUpdate,
            onChanged: _toggleAutoUpdate,
            activeThumbColor: cs.primary,
            activeTrackColor: cs.primaryContainer,
          ),
          SwitchListTile(
            title: Text('Update using Wi-Fi only',
                style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text('Only download updates over Wi-Fi',
                style: GoogleFonts.inter(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            value: _wifiOnly,
            onChanged: _toggleWifiOnly,
            activeThumbColor: cs.primary,
            activeTrackColor: cs.primaryContainer,
          ),
          const Divider(),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'ABOUT UPDATES',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: cs.primary,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.system_update, color: cs.primary),
            title: Text('Check for updates',
                style: GoogleFonts.inter(fontSize: 16)),
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
                style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text(_appVersion,
                style: GoogleFonts.inter(
                    color: cs.onSurfaceVariant, fontSize: 14)),
          ),
          ListTile(
            leading: Icon(Icons.schedule, color: cs.primary),
            title: Text('Last update check',
                style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text(_lastCheckText,
                style: GoogleFonts.inter(
                    color: cs.onSurfaceVariant, fontSize: 14)),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
