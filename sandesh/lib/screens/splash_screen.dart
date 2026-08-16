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
    // Resolve the destination (auth/profile check) AND the minimum splash hold
    // concurrently, then navigate as soon as both are done. This removes the
    // old fixed 1.4s dead-wait: on fast devices launch is gated only by the
    // short 700ms hold (so the intro animation is still seen), and on slow
    // networks it's gated only by the real auth work — never both stacked.
    final results = await Future.wait<Object>([
      _resolveDestination(),
      Future<void>.delayed(const Duration(milliseconds: 700)),
    ]);
    if (!mounted) return;
    final destination = results[0] as Widget;

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

  /// Decides the first real screen based on auth session + phone-setup state.
  Future<Widget> _resolveDestination() async {
    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;

    // Not authenticated — go to login
    if (session == null) return const LoginScreen();

    // User is authenticated — check if phone setup is done
    final prefs = await SharedPreferences.getInstance();
    final phoneE164 = prefs.getString('phone_e164') ?? '';
    if (phoneE164.isNotEmpty) {
      // Fully set up — go to HomeScreen
      return const HomeScreen();
    }

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
        return const HomeScreen();
      }
    } catch (_) {
      // fall through to phone setup on any error
    }

    // Authenticated but no phone — send to phone setup
    final meta = session.user.userMetadata ?? {};
    final googleName = (meta['full_name'] as String? ??
            meta['name'] as String? ??
            session.user.email?.split('@').first ??
            'User')
        .trim();
    return PhoneSetupScreen(googleName: googleName);
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: cs.outlineVariant,
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: cs.primary.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22.5),
                          child: Image.asset(
                            'assets/logo.png',
                            width: 100,
                            height: 100,
                            // Decode the 1.2 MB source PNG down to the display
                            // size (~3x for hi-dpi) instead of full resolution,
                            // so it costs far less memory/CPU on startup.
                            cacheWidth: 300,
                            cacheHeight: 300,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Center(
                              child: Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 48,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Sandesh',
                        style: GoogleFonts.inter(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 64),
              // Loading indicator
              FadeTransition(
                opacity: _fadeAnimation,
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
