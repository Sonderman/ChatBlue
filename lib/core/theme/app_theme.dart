import 'package:flutter/material.dart';

/// App-wide theme definitions.
///
/// Both themes share the ChatBlue identity (cyan seed); the dark theme uses
/// the deep navy canvas that the chat screens are built with, the light
/// theme a bright variant of it.
class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF00D2FF);

  /// Bright background, dark text, cyan accents.
  static ThemeData get light => _base(Brightness.light, const Color(0xFFF4F7FC));

  /// Navy canvas (matching the chat UI kit), light text, cyan accents.
  static ThemeData get dark => _base(Brightness.dark, const Color(0xFF0A1122));

  static ThemeData _base(Brightness brightness, Color background) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xFF0E1830)
            : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}