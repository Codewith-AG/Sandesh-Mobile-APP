import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  UserProfile? _profile;
  String? _avatarBase64;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    // Try SQLite first
    UserProfile? profile = await LocalDbService().getProfile();

    // Fallback to SharedPreferences if SQLite is empty (e.g. first launch)
    if (profile == null) {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      final phone = prefs.getString('phone') ?? '';
      final hashedPhone = prefs.getString('hashed_phone') ?? '';
      if (username.isNotEmpty) {
        profile = UserProfile(
          username: username,
          phone: phone,
          hashedPhone: hashedPhone,
        );
        // Persist to SQLite so next time it loads from DB
        await LocalDbService().saveProfile(profile);
      }
    }

    if (profile != null) {
      _usernameController.text = profile.username;
      _bioController.text = profile.bio;
      _phoneController.text = profile.phone;
      _profile = profile;
      _avatarBase64 = profile.avatarUrl.isNotEmpty ? profile.avatarUrl : null;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveProfile() async {
    if (_usernameController.text.trim().isEmpty) return;

    setState(() => _isSaving = true);

    try {
      final updated = UserProfile(
        username: _profile?.username ?? _usernameController.text.trim(),
        phone: _phoneController.text.trim(),
        hashedPhone: _profile?.hashedPhone ?? '',
        bio: _bioController.text.trim(),
        avatarUrl: _avatarBase64 ?? _profile?.avatarUrl ?? '',
      );

      // Save locally
      await LocalDbService().saveProfile(updated);

      // Sync to Supabase
      await SupabaseBroadcastService().syncProfile(updated);

      // Re-read from DB to confirm persistence
      final confirmed = await LocalDbService().getProfile();
      if (confirmed != null) {
        _profile = confirmed;
        _usernameController.text = confirmed.username;
        _bioController.text = confirmed.bio;
        _phoneController.text = confirmed.phone;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Profile saved successfully',
                style: GoogleFonts.urbanist(fontWeight: FontWeight.w600)),
            backgroundColor: AppTheme.primaryPurple,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving profile: $e'),
            backgroundColor: AppTheme.errorRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _pickAvatar() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 60,
      );
      if (image != null) {
        final bytes = await File(image.path).readAsBytes();
        final base64String = base64Encode(bytes);

        setState(() => _avatarBase64 = base64String);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Photo selected — tap Save to persist',
                  style: GoogleFonts.urbanist(fontWeight: FontWeight.w500)),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Image picker error: $e');
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Logout', style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
        content: Text(
          'Are you sure you want to logout? Your chat history will be preserved locally.',
          style: GoogleFonts.urbanist(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.urbanist(color: AppTheme.textLight)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            child: Text('Logout', style: GoogleFonts.urbanist(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      SupabaseBroadcastService().dispose();
      // Sign out from Supabase to clear the auth session
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    }
  }

  Widget _buildAvatar() {
    Widget avatarContent;

    if (_avatarBase64 != null && _avatarBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(_avatarBase64!);
        avatarContent = CircleAvatar(
          radius: 56,
          backgroundImage: MemoryImage(bytes),
        );
      } catch (_) {
        avatarContent = _buildLetterAvatar();
      }
    } else {
      avatarContent = _buildLetterAvatar();
    }

    return GestureDetector(
      onTap: _pickAvatar,
      child: Stack(
        children: [
          avatarContent,
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppTheme.primaryPurple,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLetterAvatar() {
    return CircleAvatar(
      radius: 56,
      backgroundColor: AppTheme.lightPurple,
      child: Text(
        (_profile?.username.isNotEmpty == true)
            ? _profile!.username[0].toUpperCase()
            : '?',
        style: GoogleFonts.urbanist(
          fontSize: 42,
          fontWeight: FontWeight.w700,
          color: AppTheme.primaryPurple,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Profile', style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryPurple))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _buildAvatar(),
                  const SizedBox(height: 32),

                  // Username (read-only)
                  _buildField(
                    controller: _usernameController,
                    label: 'Username',
                    icon: Icons.person_outline,
                    readOnly: true,
                  ),
                  const SizedBox(height: 16),

                  // Phone (read-only)
                  _buildField(
                    controller: _phoneController,
                    label: 'Phone',
                    icon: Icons.phone_outlined,
                    readOnly: true,
                  ),
                  const SizedBox(height: 16),

                  // Bio (editable)
                  _buildField(
                    controller: _bioController,
                    label: 'Bio',
                    icon: Icons.edit_note_outlined,
                    readOnly: false,
                    maxLines: 3,
                    hintText: 'Tell something about yourself...',
                  ),
                  const SizedBox(height: 32),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: _isSaving ? null : _saveProfile,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline, color: Colors.white),
                      label: Text(
                        'Save Profile',
                        style: GoogleFonts.urbanist(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryPurple,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Logout
                  TextButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout, color: AppTheme.errorRed),
                    label: Text(
                      'Logout',
                      style: GoogleFonts.urbanist(
                        color: AppTheme.errorRed,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool readOnly = false,
    int maxLines = 1,
    String? hintText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            label,
            style: GoogleFonts.urbanist(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textLight,
              letterSpacing: 0.5,
            ),
          ),
        ),
        TextFormField(
          controller: controller,
          readOnly: readOnly,
          maxLines: maxLines,
          style: GoogleFonts.urbanist(fontSize: 15, color: AppTheme.textDark),
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: Icon(icon, color: AppTheme.primaryPurple, size: 22),
            filled: true,
            fillColor: readOnly
                ? AppTheme.lightGrey.withValues(alpha: 0.5)
                : AppTheme.lightGrey,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}
