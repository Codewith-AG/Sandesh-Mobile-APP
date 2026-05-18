import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
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
        _handleSuccessfulSignIn(response.user!);
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
                style: GoogleFonts.inter(fontWeight: FontWeight.w500),
              ),
              backgroundColor: AppTheme.errorRed,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        setState(() => _isLoading = false);
      }
    }
  }

  void _handleSuccessfulSignIn(User user) {
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
      backgroundColor: Colors.white,
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
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F4F6),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFE8E8EC),
                        width: 1,
                      ),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.chat_bubble_rounded,
                        size: 38,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Brand Name ──
                  Text(
                    'Sandesh',
                    style: GoogleFonts.inter(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF0D0D0D),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Private messaging, built for trust.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      color: const Color(0xFF8A8A9A),
                      fontWeight: FontWeight.w400,
                      height: 1.5,
                    ),
                  ),

                  const Spacer(),

                  // ── Feature pills row ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _FeaturePill(icon: Icons.lock_outline_rounded, label: 'Encrypted'),
                      const SizedBox(width: 10),
                      _FeaturePill(icon: Icons.bolt_rounded, label: 'Instant'),
                      const SizedBox(width: 10),
                      _FeaturePill(icon: Icons.do_not_disturb_on_outlined, label: 'No Ads'),
                    ],
                  ),

                  const SizedBox(height: 36),

                  // ── Sign-in card ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFFEAEAEF), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Get started',
                          style: GoogleFonts.inter(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF0D0D0D),
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Sign in with your Google account to continue.',
                          style: GoogleFonts.inter(
                            fontSize: 13.5,
                            color: const Color(0xFF8A8A9A),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Google Sign-In Button ──
                        _GoogleSignInButton(
                          isLoading: _isLoading,
                          onPressed: _isLoading ? null : _signInWithGoogle,
                        ),

                        const SizedBox(height: 18),

                        // ── Security note ──
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              size: 13,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'End-to-end encrypted · Zero server storage',
                              style: GoogleFonts.inter(
                                fontSize: 11.5,
                                color: Colors.grey.shade400,
                                fontWeight: FontWeight.w400,
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
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: const Color(0xFFB0B0C0),
                      height: 1.7,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F6F9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFEAEAEF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF5A5A72)),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5A5A72),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Google Sign-In Button ─────────────────────────────────────────────────────

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
          height: 54,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFDDDDE5), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: widget.isLoading
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4285F4)),
                    ),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Official Google "G" mark
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CustomPaint(painter: _GoogleGPainter()),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Continue with Google',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF1F1F2E),
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

// ─── Accurate Google "G" logo painter ─────────────────────────────────────────

class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double r = size.width / 2;

    // Draw coloured arcs: Blue, Red, Yellow, Green (clockwise from right)
    final segments = [
      // [startAngle (degrees), sweepAngle, color]
      [-10.0, 100.0, const Color(0xFF4285F4)], // Blue
      [90.0, 100.0, const Color(0xFF34A853)],  // Green
      [190.0, 80.0, const Color(0xFFFBBC05)],  // Yellow
      [270.0, 100.0, const Color(0xFFEA4335)], // Red
    ];

    const toRad = 3.1415926535 / 180;

    for (final seg in segments) {
      final paint = Paint()
        ..color = seg[2] as Color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.22;

      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.72),
        (seg[0] as double) * toRad,
        (seg[1] as double) * toRad,
        false,
        paint,
      );
    }

    // White horizontal bar for the crossbar of the G
    final barPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(cx, cy - size.height * 0.12, r * 0.72, size.height * 0.24),
      barPaint,
    );

    // Blue fill on the bar
    final bluePaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(cx, cy - size.height * 0.12, r * 0.72, size.height * 0.24),
      bluePaint,
    );
  }

  @override
  bool shouldRepaint(_GoogleGPainter oldDelegate) => false;
}
