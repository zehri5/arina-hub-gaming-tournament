import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ArenaTheme {
  ArenaTheme._();

  static const Color midnightBg = Color(0xFF050614);
  static const Color glassFill = Color(0xC7080B22);
  static const Color cyanNeon = Color(0xFF00E5FF);
  static const Color electricBlue = Color(0xFF3B82F6);
  static const Color purpleNeon = Color(0xFF9333EA);
  static const Color magentaNeon = Color(0xFFC026D3);
  static const Color goldBright = Color(0xFFFFF380);
  static const Color goldPrimary = Color(0xFFFFC524);
  static const Color goldOrange = Color(0xFFFF8A00);
  static const Color errorRed = Color(0xFFFB7185);
  static const Color hintColor = Color(0xD9A9B5D1);

  static const String backgroundAsset = 'assets/images/arena_auth_background.png';

  static TextStyle displayStyle({
    required double fontSize,
    Color color = Colors.white,
    FontWeight fontWeight = FontWeight.w900,
    FontStyle fontStyle = FontStyle.italic,
    double letterSpacing = 0.5,
    double? height,
  }) {
    return GoogleFonts.barlowCondensed(
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  static TextStyle bodyStyle({
    required double fontSize,
    Color color = Colors.white,
    FontWeight fontWeight = FontWeight.w500,
    FontStyle fontStyle = FontStyle.normal,
    double? letterSpacing,
  }) {
    return GoogleFonts.plusJakartaSans(
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
    );
  }
}

// FIX 31 — AI Studio voice-room theme (file 2, verbatim classes),
// merged ALONGSIDE item 30's ArenaTheme above — that class is
// untouched. Design gold royalGold FFD700 applies AS-IS inside
// the voice room screen (splash/auth precedent).
class ArenaColors {
  static const primaryBg = Color(0xFF070816);
  static const secondaryBg = Color(0xFF0A0D1C);
  static const cardBg = Color(0xFF15102B);
  static const glassSurface = Color(0xFF1A1533);

  static const purple = Color(0xFF6A00FF);
  static const electricBlue = Color(0xFF00D4FF);
  static const royalGold = Color(0xFFFFD700);
  static const neonPink = Color(0xFFFF00C8);
  static const connectedGreen = Color(0xFF00F59F);
  static const liveRed = Color(0xFFFF334F);

  static const primaryText = Color(0xFFFFFFFF);
  static const secondaryText = Color(0xFFB9B5D5);
}

class ArenaTypography {
  static TextStyle heading(double size, {Color color = ArenaColors.primaryText}) =>
      GoogleFonts.rajdhani(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.15,
      );

  static TextStyle orbitron(double size, {Color color = ArenaColors.primaryText}) =>
      GoogleFonts.orbitron(
        fontSize: size,
        fontWeight: FontWeight.w800,
        color: color,
        letterSpacing: 0.8,
      );

  static TextStyle body(double size,
          {Color color = ArenaColors.primaryText, FontWeight weight = FontWeight.w500}) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color,
      );
}
