import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import 'notification_settings_screen.dart';
import 'app_updates_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isDarkMode = false;

  @override
  void initState() {
    super.initState();
    _isDarkMode = themeNotifier.value == ThemeMode.dark;
  }

  void _toggleDarkMode(bool value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('isDarkMode', value);
    setState(() {
      _isDarkMode = value;
    });
    themeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: GoogleFonts.inter()),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        children: [

          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'APPEARANCE',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: cs.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: Text('Dark Mode', style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text('Enable dark theme across the app',
                style: GoogleFonts.inter(
                    color: cs.onSurfaceVariant, fontSize: 14)),
            value: _isDarkMode,
            onChanged: _toggleDarkMode,
            activeThumbColor: cs.primary,
            activeTrackColor: cs.primaryContainer,
          ),
          const Divider(),
          const SizedBox(height: 16),
          // ── Notifications section ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'NOTIFICATIONS',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: cs.primary,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.notifications_none_rounded, color: cs.primary),
            title: Text('Notification Settings', style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text('Manage message, group, and call alerts',
                style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
            trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
              );
            },
          ),
          const Divider(),
          const SizedBox(height: 16),
          // ── App Updates section ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'APP UPDATES',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: cs.primary,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.system_update_alt_rounded, color: cs.primary),
            title: Text('App Updates', style: GoogleFonts.inter(fontSize: 16)),
            subtitle: Text('Auto-update, Wi-Fi preferences & version info',
                style: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 14)),
            trailing: Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AppUpdatesScreen()),
              );
            },
          ),
          const SizedBox(height: 32),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Made with ',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Icon(
                  Icons.favorite,
                  color: Colors.red,
                  size: 24,
                ),
                Text(
                  ' in India',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
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
