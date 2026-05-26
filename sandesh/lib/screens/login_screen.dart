import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'phone_setup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  // Native Google Sign-In — bypasses the browser redirect entirely
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId:
        '105713787389-6pjrhl6t5nuup11dehfttgbscl9pk8ja.apps.googleusercontent.com',
  );

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.65, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOutCubic),
    ));
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;

      if (idToken == null) throw Exception('Could not retrieve ID token.');

      final response = await Supabase.instance.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );

      if (response.user != null && mounted) {
        await _handleSuccessfulSignIn(response.user!);
      }
    } catch (e) {
      final msg = e.toString();
      final isUserCancelled =
          msg.contains('sign_in_cancelled') || msg.contains('sign_in_canceled');

      if (mounted) {
        if (!isUserCancelled) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Sign-in failed: ${msg.replaceAll('Exception:', '').trim()}',
                style: GoogleFonts.outfit(fontWeight: FontWeight.w500),
              ),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleSuccessfulSignIn(User user) async {
    if (!mounted) return;

    try {
      final profile = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      if (profile != null && profile['phone_e164'] != null) {
        final username = profile['username'] as String?;
        final phone = profile['phone_e164'] as String?;

        final prefs = await SharedPreferences.getInstance();
        if (username != null) {
          await prefs.setString('username', username);
        }
        if (phone != null) {
          await prefs.setString('phone_e164', phone);
        }

        if (!mounted) return;
        setState(() => _isLoading = false);

        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const HomeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
            transitionDuration: const Duration(milliseconds: 350),
          ),
        );
        return;
      }
    } catch (e) {
      // Fallback to PhoneSetupScreen on error
    }

    if (!mounted) return;
    final meta = user.userMetadata ?? {};
    final googleName = (meta['full_name'] as String? ??
            meta['name'] as String? ??
            user.email?.split('@').first ??
            'User')
        .trim();

    setState(() => _isLoading = false);
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PhoneSetupScreen(googleName: googleName),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SlideTransition(
            position: _slideAnimation,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(height: size.height * 0.08),

                  // ── App Icon ──
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(
                        color: AppTheme.surfaceVariant,
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.12),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.chat_bubble_rounded,
                        size: 42,
                        color: AppTheme.primary,
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Brand Name ──
                  Text(
                    'Sandesh',
                    style: GoogleFonts.outfit(
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.onSurface,
                      letterSpacing: -0.02,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Private messaging, built for trust.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      color: AppTheme.onSurfaceVariant,
                      fontWeight: FontWeight.w400,
                      height: 1.5,
                    ),
                  ),

                  const Spacer(),

                  // ── Feature pills row ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      _FeaturePill(icon: Icons.lock_outline_rounded, label: 'Encrypted'),
                      SizedBox(width: 10),
                      _FeaturePill(icon: Icons.bolt_rounded, label: 'Instant'),
                      SizedBox(width: 10),
                      _FeaturePill(icon: Icons.do_not_disturb_on_outlined, label: 'No Ads'),
                    ],
                  ),

                  const SizedBox(height: 36),

                  // ── Sign-in card ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: AppTheme.surfaceVariant.withValues(alpha: 0.5), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.08),
                          blurRadius: 32,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Get started',
                          style: GoogleFonts.outfit(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.onSurface,
                            letterSpacing: -0.01,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Sign in with your Google account to continue.',
                          style: GoogleFonts.outfit(
                            fontSize: 14,
                            color: AppTheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Google Sign-In Button ──
                        _GoogleSignInButton(
                          isLoading: _isLoading,
                          onPressed: _isLoading ? null : _signInWithGoogle,
                        ),

                        const SizedBox(height: 20),

                        // ── Security note ──
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              size: 14,
                              color: AppTheme.outline,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'End-to-end encrypted · Zero server storage',
                              style: GoogleFonts.outfit(
                                fontSize: 12,
                                color: AppTheme.outline,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Terms ──
                  Text(
                    'By continuing, you agree to our Terms of Service\nand Privacy Policy.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: AppTheme.outlineVariant,
                      fontWeight: FontWeight.w500,
                      height: 1.6,
                    ),
                  ),
                  SizedBox(height: size.height * 0.04),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Feature Pill ──────────────────────────────────────────────────────────────

class _FeaturePill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FeaturePill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.surfaceVariant, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Google Sign-In Button ─────────────────────────────────────────────────────

const String _googleSvg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
  <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
  <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
  <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
  <path fill="none" d="M0 0h48v48H0z"/>
</svg>''';

class _GoogleSignInButton extends StatefulWidget {
  final bool isLoading;
  final VoidCallback? onPressed;
  const _GoogleSignInButton({required this.isLoading, required this.onPressed});

  @override
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pressCtrl;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: GestureDetector(
        onTapDown: (_) => _pressCtrl.forward(),
        onTapUp: (_) {
          _pressCtrl.reverse();
          widget.onPressed?.call();
        },
        onTapCancel: () => _pressCtrl.reverse(),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: AppTheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppTheme.surfaceVariant, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: widget.isLoading
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
                    ),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SvgPicture.string(_googleSvg, width: 24, height: 24),
                    const SizedBox(width: 14),
                    Text(
                      'Continue with Google',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.onSurface,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
