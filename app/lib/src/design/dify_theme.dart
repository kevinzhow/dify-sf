import 'package:flutter/material.dart';

/// The app's Material theme ([brightness]: the Dify theme's, for the few Material defaults left), in [fontFamily] (Dify's font stack: the system UI font, Noto Sans on Linux), with no
/// letter spacing in any text style. Browsers lay text out with `letter-spacing: normal` unless a Tailwind
/// `tracking-*` class says otherwise; Material 3's text theme tracks most styles (bodyLarge 0.5 px, bodyMedium 0.25,
/// labelLarge 0.1, ...), which text fields (bodyLarge under their style) and Material's default text style pass on to
/// every style that does not set its own: such lines came out 3-8 % wider than Dify's.
ThemeData difyTheme({String? fontFamily, List<String>? fontFamilyFallback, Brightness brightness = Brightness.light}) {
  final base = ThemeData(
    colorSchemeSeed: const Color(0xFF3F51B5),
    useMaterial3: true,
    // CSS input padding is platform independent. Material's desktop default
    // compact density otherwise subtracts 8px and shifts multiline text by 4px.
    visualDensity: VisualDensity.standard,
    fontFamily: fontFamily,
    brightness: brightness,
  );
  return base.copyWith(
    textTheme: _untracked(base.textTheme).apply(fontFamilyFallback: fontFamilyFallback),
    primaryTextTheme: _untracked(base.primaryTextTheme).apply(fontFamilyFallback: fontFamilyFallback),
  );
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
