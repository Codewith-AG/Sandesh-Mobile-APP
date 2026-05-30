import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../main.dart';
import 'profile_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', value);
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
            activeColor: cs.primary,
          ),
          // Add more settings here in the future
        ],
      ),
    );
  }
}
