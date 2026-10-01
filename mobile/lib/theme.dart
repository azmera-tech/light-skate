import 'package:flutter/material.dart';

/// Same palette as the web app (web/src/styles.css), so the product reads as one
/// system across platforms rather than two different apps that happen to share a backend.
class LsColors {
  static const brand = Color(0xFF0B6E99);
  static const brandStrong = Color(0xFF07557A);
  static const brandSoft = Color(0xFFE1F1F8);
  static const bg = Color(0xFFF3F6F9);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFEEF2F6);
  static const text = Color(0xFF14202B);
  static const muted = Color(0xFF5A6B7A);
  static const border = Color(0xFFD8E0E8);

  static const green = Color(0xFF12783A);
  static const greenSoft = Color(0xFFDFF3E6);
  static const yellow = Color(0xFF8A6100);
  static const yellowSoft = Color(0xFFFFF1C2);
  static const orange = Color(0xFFB34700);
  static const orangeSoft = Color(0xFFFFE2CC);
  static const red = Color(0xFFB3261E);
  static const redSoft = Color(0xFFFDE1DF);
  static const gray = Color(0xFF5A6B7A);
  static const graySoft = Color(0xFFE7ECF1);
  static const slate = Color(0xFF3B4F63);
  static const slateSoft = Color(0xFFDDE6EF);
}

/// A session/warning "level" (see shared/sessions.dart) maps to one (text, background) pair,
/// exactly mirroring the web's .lvl-* classes — the same rule, enforced the same way, on both clients.
(Color, Color) levelColors(String level) {
  switch (level) {
    case 'normal':
      return (LsColors.green, LsColors.greenSoft);
    case 'yellow':
      return (LsColors.yellow, LsColors.yellowSoft);
    case 'orange':
      return (LsColors.orange, LsColors.orangeSoft);
    case 'red':
    case 'expired':
      return (LsColors.red, LsColors.redSoft);
    case 'paused':
      return (LsColors.slate, LsColors.slateSoft);
    case 'info':
      return (LsColors.brandStrong, LsColors.brandSoft);
    default:
      return (LsColors.gray, LsColors.graySoft);
  }
}

ThemeData buildLsTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: LsColors.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: LsColors.brand, primary: LsColors.brand),
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: LsColors.surface,
      foregroundColor: LsColors.text,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: LsColors.surface,
    ),
    cardTheme: CardThemeData(
      color: LsColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: LsColors.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LsColors.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: LsColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: LsColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: LsColors.brand, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: LsColors.brand,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
  );
}
