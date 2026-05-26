import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile_model.dart';
import '../services/local_db_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class PhoneSetupScreen extends StatefulWidget {
  final String googleName;

  const PhoneSetupScreen({super.key, required this.googleName});

  @override
  State<PhoneSetupScreen> createState() => _PhoneSetupScreenState();
}

class _PhoneSetupScreenState extends State<PhoneSetupScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _phoneValid = false;
  String? _e164Phone;

  // phone_form_field controller — default to India (+91)
  final PhoneController _phoneController = PhoneController(
    initialValue: const PhoneNumber(isoCode: IsoCode.IN, nsn: ''),
  );

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
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || !_phoneValid || _e164Phone == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please enter a valid phone number',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.w500),
          ),
          backgroundColor: AppTheme.errorRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;
      if (user == null) throw Exception('No authenticated user found');

      final profile = UserProfile(
        username: widget.googleName,
        phone: _e164Phone!,
        phoneE164: _e164Phone!,
      );

      // Upsert to Supabase profiles table keyed by auth UUID
      await supabase.from('profiles').upsert(
        profile.toSupabaseMap(authId: user.id),
        onConflict: 'id',
      );

      // Save to local SQLite
      await LocalDbService().saveProfile(profile);

      // Cache in SharedPreferences for quick access
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', widget.googleName);
      await prefs.setString('phone_e164', _e164Phone!);

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const HomeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
            transitionDuration: const Duration(milliseconds: 400),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error: ${e.toString()}',
              style: GoogleFonts.urbanist(fontWeight: FontWeight.w500),
            ),
            backgroundColor: AppTheme.errorRed,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = MediaQuery.of(context).platformBrightness;
    final isDark = brightness == Brightness.dark;
    final size = MediaQuery.of(context).size;

    // Adaptive colors
    final bgColor = AppTheme.background;
    final cardColor = AppTheme.surfaceContainerLowest;
    final textColor = AppTheme.onSurface;
    final subtitleColor = AppTheme.onSurfaceVariant;
    final fieldFill = AppTheme.surfaceContainerLow;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: bgColor,
        body: Stack(
          children: [
            // Background gradient orbs
            Positioned(
              top: -60,
              left: -40,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.primaryPurple.withValues(alpha: 0.22),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              right: -60,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.accentPurple.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Content
            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: SlideTransition(
                    position: _slideAnimation,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: size.height * 0.07),

                        // Header icon
                        Center(
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primary.withValues(alpha: 0.35),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.phone_iphone_rounded,
                              size: 38,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Welcome with name
                        Text(
                          'Hi, ${widget.googleName.split(' ').first}! 👋',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'One last step — add your phone number\nso your contacts can find you.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            color: subtitleColor,
                            height: 1.6,
                          ),
                        ),
                        SizedBox(height: size.height * 0.06),

                        // Card
                        Container(
                          padding: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(32),
                            border: Border.all(
                              color: AppTheme.surfaceVariant,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.primary
                                    .withValues(alpha: 0.07),
                                blurRadius: 32,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Name display (read-only)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                  decoration: BoxDecoration(
                                    color: fieldFill,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: AppTheme.primary,
                                        child: Icon(
                                          Icons.person_outline,
                                          color: AppTheme.onPrimary,
                                          size: 18,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Your Name',
                                              style: GoogleFonts.outfit(
                                                fontSize: 11,
                                                color: subtitleColor,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              widget.googleName,
                                              style: GoogleFonts.outfit(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                                color: textColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppTheme.primary
                                              .withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          'Google',
                                          style: GoogleFonts.outfit(
                                            fontSize: 11,
                                            color: AppTheme.primary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),

                                // Phone field label
                                Text(
                                  'Phone Number',
                                  style: GoogleFonts.outfit(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: subtitleColor,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // Phone form field (Dart 3 compatible, E.164 output)
                                Theme(
                                  data: Theme.of(context).copyWith(
                                    inputDecorationTheme: InputDecorationTheme(
                                      filled: true,
                                      fillColor: fieldFill,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: BorderSide.none,
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: const BorderSide(
                                          color: AppTheme.primary,
                                          width: 1.5,
                                        ),
                                      ),
                                      errorBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(24),
                                        borderSide: const BorderSide(
                                          color: AppTheme.error,
                                          width: 1.5,
                                        ),
                                      ),
                                      contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 18,
                                      ),
                                    ),
                                  ),
                                  child: PhoneFormField(
                                    controller: _phoneController,
                                    countrySelectorNavigator:
                                        const CountrySelectorNavigator.dialog(),
                                    style: GoogleFonts.outfit(
                                      fontSize: 15,
                                      color: textColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '98765 43210',
                                      hintStyle: GoogleFonts.outfit(
                                        color: subtitleColor,
                                        fontSize: 15,
                                      ),
                                    ),
                                    validator: PhoneValidator.compose([
                                      PhoneValidator.required(context,
                                          errorText: 'Phone number is required'),
                                      PhoneValidator.valid(context,
                                          errorText: 'Enter a valid phone number'),
                                    ]),
                                    onChanged: (PhoneNumber phone) {
                                      final valid = phone.isValid();
                                      setState(() {
                                        _phoneValid = valid;
                                        _e164Phone = valid ? phone.international : null;
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // E.164 preview badge
                                if (_e164Phone != null && _phoneValid) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: AppTheme.onlineGreen.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.check_circle_rounded,
                                          color: Colors.green,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Formatted: $_e164Phone',
                                          style: GoogleFonts.outfit(
                                            fontSize: 13,
                                            color: Colors.green,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],

                                const SizedBox(height: 20),

                                // Continue button
                                SizedBox(
                                  height: 58,
                                  child: ElevatedButton(
                                    onPressed: _isLoading ? null : _submit,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.transparent,
                                      shadowColor: Colors.transparent,
                                      padding: EdgeInsets.zero,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                    ),
                                    child: Ink(
                                      decoration: BoxDecoration(
                                        color: _isLoading ? AppTheme.surfaceContainerHigh : AppTheme.primary,
                                        borderRadius: BorderRadius.circular(999),
                                        boxShadow: _isLoading
                                            ? null
                                            : [
                                                BoxShadow(
                                                  color: AppTheme.primary
                                                      .withValues(alpha: 0.38),
                                                  blurRadius: 16,
                                                  offset: const Offset(0, 6),
                                                ),
                                              ],
                                      ),
                                      child: Container(
                                        alignment: Alignment.center,
                                        child: _isLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                  color: Colors.white,
                                                  strokeWidth: 2.5,
                                                ),
                                              )
                                            : Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    'Set Up My Account',
                                                    style: GoogleFonts.outfit(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w700,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  const Icon(
                                                    Icons.arrow_forward_rounded,
                                                    color: Colors.white,
                                                    size: 20,
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 13,
                              color: subtitleColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Your number is only used to find your contacts',
                              style: GoogleFonts.outfit(
                                fontSize: 12,
                                color: subtitleColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
