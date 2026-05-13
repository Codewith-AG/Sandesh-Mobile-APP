import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_profile_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _usernameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  late AnimationController _animController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _usernameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim().toLowerCase();
    final phone = _phoneController.text.trim();

    setState(() => _isLoading = true);

    try {
      // Smart normalization for Indian contacts
      final cleanedPhone = phone.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
      final normalizedPhone = cleanedPhone.length > 10 
          ? cleanedPhone.substring(cleanedPhone.length - 10) 
          : cleanedPhone;

      // Hash phone number for privacy
      final hashedPhone = sha256.convert(utf8.encode(normalizedPhone)).toString();

      // Create profile
      final profile = UserProfile(
        username: username,
        phone: phone,
        hashedPhone: hashedPhone,
      );

      // Save locally
      await LocalDbService().saveProfile(profile);

      // Save session
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', username);
      await prefs.setString('phone', phone); // Save original phone so Profile can read it
      await prefs.setString('hashed_phone', hashedPhone);

      // Sync to Supabase (best-effort)
      await SupabaseBroadcastService().syncProfile(profile);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Purple gradient header
          Container(
            height: MediaQuery.of(context).size.height * 0.42,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.primaryPurple, AppTheme.darkPurple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(40),
                bottomRight: Radius.circular(40),
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 20),
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Sandesh',
                    style: GoogleFonts.urbanist(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your messages, your device.',
                    style: GoogleFonts.urbanist(
                      fontSize: 14,
                      color: Colors.white70,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Form card
          Positioned.fill(
            top: MediaQuery.of(context).size.height * 0.34,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: Card(
                    elevation: 8,
                    shadowColor: AppTheme.primaryPurple.withOpacity(0.15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Get Started',
                              style: GoogleFonts.urbanist(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textDark,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Enter your details to continue',
                              style: GoogleFonts.urbanist(
                                fontSize: 14,
                                color: AppTheme.textLight,
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Username field
                            TextFormField(
                              controller: _usernameController,
                              textInputAction: TextInputAction.next,
                              validator: (val) {
                                if (val == null || val.trim().length < 3) {
                                  return 'Username must be at least 3 characters';
                                }
                                return null;
                              },
                              decoration: InputDecoration(
                                hintText: 'Username',
                                prefixIcon: const Icon(Icons.person_outline,
                                    color: AppTheme.primaryPurple),
                                filled: true,
                                fillColor: AppTheme.lightGrey,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Phone field
                            TextFormField(
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              textInputAction: TextInputAction.done,
                              validator: (val) {
                                if (val == null || val.trim().length < 10) {
                                  return 'Enter a valid phone number';
                                }
                                return null;
                              },
                              decoration: InputDecoration(
                                hintText: 'Phone Number',
                                prefixIcon: const Icon(Icons.phone_outlined,
                                    color: AppTheme.primaryPurple),
                                filled: true,
                                fillColor: AppTheme.lightGrey,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Login button
                            SizedBox(
                              height: 56,
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _login,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryPurple,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 2,
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2.5,
                                        ),
                                      )
                                    : Text(
                                        'Continue',
                                        style: GoogleFonts.urbanist(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Privacy note
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.lock_outline,
                                    size: 14, color: AppTheme.textLight),
                                const SizedBox(width: 6),
                                Text(
                                  'Your phone number is hashed for privacy',
                                  style: GoogleFonts.urbanist(
                                    fontSize: 12,
                                    color: AppTheme.textLight,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
