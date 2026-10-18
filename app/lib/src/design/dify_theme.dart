import 'package:flutter/material.dart';

/// The app's Material theme, in [fontFamily] (Dify's font stack: the system UI font, Noto Sans on Linux), with no
/// letter spacing in any text style. Browsers lay text out with `letter-spacing: normal` unless a Tailwind
/// `tracking-*` class says otherwise; Material 3's text theme tracks most styles (bodyLarge 0.5 px, bodyMedium 0.25,
/// labelLarge 0.1, ...), which text fields (bodyLarge under their style) and Material's default text style pass on to
/// every style that does not set its own: such lines came out 3-8 % wider than Dify's.
ThemeData difyTheme({String? fontFamily}) {
  final base = ThemeData(colorSchemeSeed: const Color(0xFF3F51B5), useMaterial3: true, fontFamily: fontFamily);
  return base.copyWith(textTheme: _untracked(base.textTheme), primaryTextTheme: _untracked(base.primaryTextTheme));
}

TextTheme _untracked(TextTheme t) {
  TextStyle? z(TextStyle? s) => s?.copyWith(letterSpacing: 0);
  return TextTheme(
    displayLarge: z(t.displayLarge),
    displayMedium: z(t.displayMedium),
    displaySmall: z(t.displaySmall),
    headlineLarge: z(t.headlineLarge),
    headlineMedium: z(t.headlineMedium),
    headlineSmall: z(t.headlineSmall),
    titleLarge: z(t.titleLarge),
    titleMedium: z(t.titleMedium),
    titleSmall: z(t.titleSmall),
    bodyLarge: z(t.bodyLarge),
    bodyMedium: z(t.bodyMedium),
    bodySmall: z(t.bodySmall),
    labelLarge: z(t.labelLarge),
    labelMedium: z(t.labelMedium),
    labelSmall: z(t.labelSmall),
  );
}
