import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';
import 'home_screen.dart';
import 'phone_setup_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _scaleController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.elasticOut),
    );

    _fadeController.forward();
    _scaleController.forward();

    _navigateAfterDelay();
  }

  Future<void> _navigateAfterDelay() async {
    await Future.delayed(const Duration(milliseconds: 2500));
    if (!mounted) return;

    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;

    Widget destination;

    if (session != null) {
      // User is authenticated — check if phone setup is done
      final prefs = await SharedPreferences.getInstance();
      final phoneE164 = prefs.getString('phone_e164') ?? '';

      if (phoneE164.isNotEmpty) {
        // Fully set up — go to HomeScreen
        destination = const HomeScreen();
      } else {
        // Authenticated but phone not set up yet — check Supabase profile
        try {
          final profileData = await supabase
              .from('profiles')
              .select('username, phone_e164')
              .eq('id', session.user.id)
              .maybeSingle();

          if (profileData != null &&
              (profileData['phone_e164'] as String? ?? '').isNotEmpty) {
            // Profile exists in DB — cache locally and go home
            await prefs.setString(
                'username', profileData['username'] as String? ?? '');
            await prefs.setString(
                'phone_e164', profileData['phone_e164'] as String);
            destination = const HomeScreen();
          } else {
            // Authenticated but no phone — send to phone setup
            final meta = session.user.userMetadata ?? {};
            final googleName = (meta['full_name'] as String? ??
                    meta['name'] as String? ??
                    session.user.email?.split('@').first ??
                    'User')
                .trim();
            destination = PhoneSetupScreen(googleName: googleName);
          }
        } catch (_) {
          // On error, fallback to phone setup
          final meta = session.user.userMetadata ?? {};
          final googleName = (meta['full_name'] as String? ??
                  meta['name'] as String? ??
                  session.user.email?.split('@').first ??
                  'User')
              .trim();
          destination = PhoneSetupScreen(googleName: googleName);
        }
      }
    } else {
      // Not authenticated — go to login
      destination = const LoginScreen();
    }

    if (mounted) {
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => destination,
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          Image.asset(
            'assets/images/red_mandala.jpg',
            fit: BoxFit.cover,
          ),
          // Light overlay for text readability
          Container(
            color: Colors.black.withValues(alpha: 0.3),
          ),
          // Content
          SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 3),
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 56,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          'Sandesh',
                          style: GoogleFonts.urbanist(
                            fontSize: 46,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Secure  •  Fast  •  Local',
                          style: GoogleFonts.urbanist(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            color: Colors.white70,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(flex: 3),
                // Loading indicator
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
