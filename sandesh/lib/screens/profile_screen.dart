import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../services/media_upload_service.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String? peerUsername;
  const ProfileScreen({super.key, this.peerUsername});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isUploadingAvatar = false;
  UserProfile? _profile;

  // We now store an HTTPS URL, not base64.
  // _pendingAvatarFile holds a locally-picked file before it's uploaded.
  File? _pendingAvatarFile;

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

  bool get _isReadOnly => widget.peerUsername != null;

  Future<void> _loadProfile() async {
    if (_isReadOnly) {
      final peer = widget.peerUsername!;
      final client = Supabase.instance.client;
      try {
        // SECURITY: never request `phone_e164` for someone else's profile.
        // That value should only be visible to the owner.
        final data = await client
            .from('profiles')
            .select('username, bio, avatar_url')
            .eq('username', peer)
            .maybeSingle();

        if (data != null) {
          // Fall back to the locally-stored phone (only present if this peer
          // matched against our device contacts during phone-sync).
          final contacts = await LocalDbService().getContacts();
          String localPhone = '';
          try {
            localPhone = contacts
                .firstWhere(
                    (c) => c.username.toLowerCase() == peer.toLowerCase())
                .phone;
          } catch (_) {}

          final profile = UserProfile(
            username: (data['username'] as String?) ?? peer,
            phone: localPhone,
            hashedPhone: '',
            bio: (data['bio'] as String?) ?? '',
            avatarUrl: (data['avatar_url'] as String?) ?? '',
          );
          _usernameController.text = profile.username;
          _bioController.text = profile.bio;
          _phoneController.text = profile.phone;
          _profile = profile;
        } else {
          // Supabase row not found — fall back to local contacts DB
          final contacts = await LocalDbService().getContacts();
          try {
            final c = contacts.firstWhere(
                (c) => c.username.toLowerCase() == peer.toLowerCase());
            _usernameController.text = c.username;
            _bioController.text = c.bio;
            _phoneController.text = c.phone;
            _profile = UserProfile(
              username: c.username,
              phone: c.phone,
              hashedPhone: '',
              bio: c.bio,
              avatarUrl: c.avatarUrl,
            );
          } catch (_) {
            // Absolute fallback: just show the username
            _usernameController.text = peer;
          }
        }
      } catch (e) {
        debugPrint('Peer profile load error: $e');
        _usernameController.text = peer;
      }
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    UserProfile? profile = await LocalDbService().getProfile();

    if (profile == null) {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username') ?? '';
      final phone = prefs.getString('phone_e164') ?? '';
      final hashedPhone = prefs.getString('hashed_phone') ?? '';
      if (username.isNotEmpty) {
        profile = UserProfile(
          username: username,
          phone: phone,
          hashedPhone: hashedPhone,
        );
        await LocalDbService().saveProfile(profile);
      }
    }

    if (profile != null) {
      _usernameController.text = profile.username;
      _bioController.text = profile.bio;
      _phoneController.text = profile.phone;
      _profile = profile;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _pickAvatar() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90, // we'll compress properly in MediaUploadService
      );
      if (image != null) {
        setState(() => _pendingAvatarFile = File(image.path));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Photo selected — tap Save Profile to upload',
                  style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
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

  Future<void> _saveProfile() async {
    if (_usernameController.text.trim().isEmpty) return;
    setState(() => _isSaving = true);

    try {
      String avatarUrl = _profile?.avatarUrl ?? '';

      // If the user picked a new avatar, upload it first
      if (_pendingAvatarFile != null) {
        setState(() => _isUploadingAvatar = true);
        final username = _profile?.username ?? _usernameController.text.trim();
        avatarUrl = await MediaUploadService().uploadAvatar(_pendingAvatarFile!, username);
        setState(() {
          _isUploadingAvatar = false;
          _pendingAvatarFile = null;
        });
      }

      final updated = UserProfile(
        username: _profile?.username ?? _usernameController.text.trim(),
        phone: _phoneController.text.trim(),
        hashedPhone: _profile?.hashedPhone ?? '',
        bio: _bioController.text.trim(),
        avatarUrl: avatarUrl,
      );

      await LocalDbService().saveProfile(updated);
      await SupabaseBroadcastService().syncProfile(updated);

      final confirmed = await LocalDbService().getProfile();
      if (confirmed != null && mounted) {
        setState(() {
          _profile = confirmed;
          _usernameController.text = confirmed.username;
          _bioController.text = confirmed.bio;
          _phoneController.text = confirmed.phone;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Profile saved!',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w600)),
            backgroundColor: Colors.green.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final cs = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving profile: $e', style: GoogleFonts.outfit()),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dcs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: dcs.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Logout',
              style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w700, color: dcs.onSurface)),
          content: Text(
            'Are you sure you want to logout? Your chat history will be preserved locally.',
            style: GoogleFonts.outfit(color: dcs.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: GoogleFonts.outfit(color: dcs.outline)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: dcs.error),
              child: Text('Logout',
                  style: GoogleFonts.outfit(color: dcs.onError)),
            ),
          ],
        );
      },
    );

    if (confirm == true && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      SupabaseBroadcastService().dispose();
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

  Widget _buildAvatar(ColorScheme cs) {
    Widget avatarContent;

    if (_pendingAvatarFile != null) {
      // Locally picked but not yet uploaded — show preview from disk
      avatarContent = CircleAvatar(
        radius: 56,
        backgroundImage: FileImage(_pendingAvatarFile!),
      );
    } else if (_isUploadingAvatar) {
      avatarContent = CircleAvatar(
        radius: 56,
        backgroundColor: cs.surfaceContainerHighest,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_profile?.avatarUrl.isNotEmpty == true &&
        _profile!.avatarUrl.startsWith('http')) {
      // URL-based avatar from Supabase Storage
      avatarContent = CircleAvatar(
        radius: 56,
        backgroundImage: NetworkImage(_profile!.avatarUrl),
        onBackgroundImageError: (_, __) {},
        child: null,
      );
    } else {
      avatarContent = _buildLetterAvatar(cs);
    }

    return GestureDetector(
      onTap: (_isSaving || _isReadOnly) ? null : _pickAvatar,
      child: Stack(
        children: [
          avatarContent,
          if (!_isReadOnly)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: cs.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.surface, width: 2),
                ),
                child: Icon(Icons.camera_alt, size: 18, color: cs.onPrimary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLetterAvatar(ColorScheme cs) {
    return CircleAvatar(
      radius: 56,
      backgroundColor: cs.surfaceContainerHigh,
      child: Text(
        (_profile?.username.isNotEmpty == true)
            ? _profile!.username[0].toUpperCase()
            : '?',
        style: GoogleFonts.outfit(
          fontSize: 40,
          fontWeight: FontWeight.w600,
          color: cs.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        title: Text(
          _isReadOnly
              ? (_usernameController.text.isNotEmpty
                  ? _usernameController.text
                  : (widget.peerUsername ?? 'Profile'))
              : 'Profile',
          style: GoogleFonts.outfit(
              fontWeight: FontWeight.w700,
              color: cs.onSurface)),
        iconTheme: IconThemeData(color: cs.onSurface),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _buildAvatar(cs),
                  if (_isUploadingAvatar) ...[
                    const SizedBox(height: 8),
                    Text('Uploading avatar...',
                        style: GoogleFonts.outfit(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 32),

                  _buildField(
                    cs: cs,
                    controller: _usernameController,
                    label: 'Username',
                    icon: Icons.person_outline,
                    readOnly: true,
                  ),
                  const SizedBox(height: 16),

                  _buildField(
                    cs: cs,
                    controller: _phoneController,
                    label: 'Phone',
                    icon: Icons.phone_outlined,
                    readOnly: true,
                  ),
                  const SizedBox(height: 16),

                  _buildField(
                    cs: cs,
                    controller: _bioController,
                    label: 'Bio',
                    icon: Icons.edit_note_outlined,
                    readOnly: _isReadOnly,
                    maxLines: 3,
                    hintText: 'Tell something about yourself...',
                  ),
                  const SizedBox(height: 32),

                  if (!_isReadOnly) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveProfile,
                        icon: _isSaving
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: cs.onPrimary,
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(Icons.check_circle_outline,
                                color: cs.onPrimary),
                        label: Text(
                          _isUploadingAvatar ? 'Uploading...' : 'Save Profile',
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: cs.onPrimary,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: cs.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 48),

                    TextButton.icon(
                      onPressed: _logout,
                      icon: Icon(Icons.logout, color: cs.error),
                      label: Text(
                        'Logout',
                        style: GoogleFonts.outfit(
                          color: cs.error,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildField({
    required ColorScheme cs,
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
            style: GoogleFonts.outfit(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
        ),
        TextFormField(
          controller: controller,
          readOnly: readOnly,
          maxLines: maxLines,
          style: GoogleFonts.outfit(fontSize: 15, color: cs.onSurface),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: GoogleFonts.outfit(color: cs.outline),
            prefixIcon: Icon(icon, color: cs.onSurfaceVariant, size: 20),
            filled: true,
            fillColor: readOnly
                ? cs.surfaceContainerLowest
                : cs.surfaceContainer,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: cs.primary, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
