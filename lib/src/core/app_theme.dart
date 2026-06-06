import 'package:flutter/material.dart';

/// ODG TMS design system - shared teal/slate operations theme.
abstract final class AppTheme {
  // ══════════════════════════════════════════════════════
  // BRAND - Teal operations palette, with amber reserved for signals.
  // ══════════════════════════════════════════════════════
  static const Color brandNavyDeep = Color(0xFFF8FAFC);  // Very light gray/slate
  static const Color brandNavy = Color(0xFFF1F5F9);      // Light gray
  static const Color brandNavyMid = Color(0xFFFFFFFF);   // Pure white
  static const Color brandNavyLight = Color(0xFFE2E8F0); // Light slate border/accent

  static const Color brandOrange = Color(0xFF0E7C6B);
  static const Color brandOrangeDeep = Color(0xFF075F52);
  static const Color brandOrangeLight = Color(0xFF0D9488);
  static const Color signal = Color(0xFFD97706); // Darker amber for better legibility on white

  // Primary (CTA / focus) = Teal; amber is used for waiting and warning.
  static const Color primary = brandOrange;
  static const Color primaryDark = brandOrangeDeep;
  static const Color primaryLight = brandOrangeLight;

  // ══════════════════════════════════════════════════════
  // SEMANTIC
  // ══════════════════════════════════════════════════════
  static const Color success = Color(0xFF059669); // Slightly darker green for contrast
  static const Color warning = signal;
  static const Color error = Color(0xFFDC2626); // Slightly darker red
  static const Color info = Color(0xFF0284C7);

  // ══════════════════════════════════════════════════════
  // LIGHT SURFACES (Slate canvas)
  // ══════════════════════════════════════════════════════
  static const Color bgDark = brandNavyDeep;      // F8FAFC
  static const Color bgMid = brandNavy;          // F1F5F9
  static const Color bgCard = brandNavyMid;        // FFFFFF
  static const Color bgElevated = Color(0xFFFFFFFF);
  static const Color bgSurface = Color(0xFFECEFF1);

  // ══════════════════════════════════════════════════════
  // BORDERS
  // ══════════════════════════════════════════════════════
  static const Color surfaceBorder = Color(0xFFE2E8F0); // Solid light gray border

  // ══════════════════════════════════════════════════════
  // TEXT (on light)
  // ══════════════════════════════════════════════════════
  static const Color textBright = Color(0xFF0F172A);    // Dark slate for headings
  static const Color textPrimary = Color(0xFF1E293B);   // Slate for body text
  static const Color textSecondary = Color(0xFF475569); // Slate gray for captions
  static const Color textMuted = Color(0xFF64748B);     // Cool gray
  static const Color textDim = Color(0xFF94A3B8);       // Light gray

  // ══════════════════════════════════════════════════════
  // RADIUS
  // ══════════════════════════════════════════════════════
  static const double radiusXs = 8.0;
  static const double radiusSm = 10.0;
  static const double radiusMd = 12.0;
  static const double radiusLg = 14.0;
  static const double radiusXl = 16.0;
  static const double radiusXxl = 20.0;
  static const double radiusFull = 999.0;

  // ══════════════════════════════════════════════════════
  // SPACING
  // ══════════════════════════════════════════════════════
  static const double space1 = 4.0;
  static const double space2 = 8.0;
  static const double space3 = 12.0;
  static const double space4 = 16.0;
  static const double space5 = 20.0;
  static const double space6 = 24.0;
  static const double space8 = 32.0;
  static const double space10 = 40.0;
  static const double space12 = 48.0;

  // ══════════════════════════════════════════════════════
  // GRADIENTS
  // ══════════════════════════════════════════════════════
  static const LinearGradient accentGradient = LinearGradient(
    colors: [brandOrange, brandOrangeLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ══════════════════════════════════════════════════════
  // SHADOWS
  // ══════════════════════════════════════════════════════
  static List<BoxShadow> shadowSm = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.08),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> shadowMd = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.12),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> shadowLg = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.18),
      blurRadius: 28,
      offset: const Offset(0, 10),
    ),
  ];

  static List<BoxShadow> get cardShadow => shadowSm;

  // ══════════════════════════════════════════════════════
  // THEMES
  // ══════════════════════════════════════════════════════
  static ThemeData get darkTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light,
        primary: primary,
        secondary: signal,
        surface: bgDark,
        error: error,
      ),
      scaffoldBackgroundColor: bgDark,
    );

    return _applyCommon(base);
  }

  /// Preserved name for existing `app.dart` import — points to darkTheme.
  static ThemeData get lightTheme => darkTheme;

  static ThemeData _applyCommon(ThemeData base) {
    // Use the bundled NotoSansLao font (registered in pubspec) instead of
    // GoogleFonts runtime fetch to avoid the
    // "GoogleFonts.config.allowRuntimeFetching is false but font ... was not found"
    // exception. The .ttf is shipped under assets/fonts/.
    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: 'NotoSansLao',
        bodyColor: textPrimary,
        displayColor: textBright,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: textBright,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: textBright,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgSurface.withValues(alpha: 0.4),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textMuted, fontSize: 13),
        labelStyle: const TextStyle(color: textMuted, fontSize: 13),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: surfaceBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXl),
          side: const BorderSide(color: surfaceBorder),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: bgElevated,
        contentTextStyle: const TextStyle(
          color: textBright,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
      ),
      dividerTheme: const DividerThemeData(color: surfaceBorder, thickness: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return Colors.transparent;
        }),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXs),
        ),
        side: const BorderSide(color: textMuted, width: 1.5),
      ),
    );
  }
}
