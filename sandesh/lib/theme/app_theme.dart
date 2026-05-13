import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ──────────────────────────── Color Palette ────────────────────────────
  static const Color primaryPurple = Color(0xFF6852D6);
  static const Color darkPurple = Color(0xFF4A3AA0);
  static const Color lightPurple = Color(0xFFEDE8FB);
  static const Color accentPurple = Color(0xFF7C6BE0);

  static const Color backgroundWhite = Color(0xFFFDFDFD);
  static const Color surfaceWhite = Color(0xFFFFFFFF);
  static const Color chatBackground = Color(0xFFF5F3FA);

  static const Color chatBubbleSender = Color(0xFF6852D6);
  static const Color chatBubbleReceiver = Color(0xFFF2F0F5);

  static const Color lightGrey = Color(0xFFF0F0F2);
  static const Color mediumGrey = Color(0xFFB8B8C0);
  static const Color textDark = Color(0xFF1A1A2E);
  static const Color textMedium = Color(0xFF555568);
  static const Color textLight = Color(0xFF9E9EB0);

  static const Color onlineGreen = Color(0xFF2ECC71);
  static const Color errorRed = Color(0xFFE74C3C);

  // ──────────────────────────── Theme Data ────────────────────────────

  static ThemeData get lightTheme {
    final baseTextTheme = GoogleFonts.urbanistTextTheme();

    return ThemeData(
      useMaterial3: true,
      primaryColor: primaryPurple,
      scaffoldBackgroundColor: backgroundWhite,
      textTheme: baseTextTheme.apply(
        bodyColor: textDark,
        displayColor: textDark,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surfaceWhite,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: primaryPurple),
        titleTextStyle: GoogleFonts.urbanist(
          color: textDark,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryPurple,
        primary: primaryPurple,
        secondary: accentPurple,
        surface: surfaceWhite,
        onPrimary: Colors.white,
        onSurface: textDark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightGrey,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        hintStyle: GoogleFonts.urbanist(color: textLight, fontSize: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: const BorderSide(color: primaryPurple, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryPurple,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: GoogleFonts.urbanist(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryPurple,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: CircleBorder(),
      ),
      dividerTheme: const DividerThemeData(
        color: lightGrey,
        thickness: 1,
        space: 0,
      ),
      cardTheme: CardThemeData(
        color: surfaceWhite,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}
