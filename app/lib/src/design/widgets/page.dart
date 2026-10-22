/// Framework hosts for Dify pages and already styled content.
library;

import 'package:flutter/material.dart';

import '../dify_tokens.g.dart';
import 'selection.dart';

/// Inert host for text selection/overlays; it supplies no Material component
/// padding, shape, elevation or tint. Dify call sites own their CSS surface.
class DifySurface extends StatelessWidget {
  const DifySurface({super.key, required this.child, this.color, this.borderRadius, this.elevation = 0});
  final Widget child;
  final Color? color;
  final BorderRadius? borderRadius;
  final double elevation;
  @override
  Widget build(BuildContext context) => Material(
    type: color == null ? MaterialType.transparency : MaterialType.canvas,
    color: color,
    borderRadius: borderRadius,
    elevation: elevation,
    surfaceTintColor: Colors.transparent,
    child: child,
  );
}

/// A Dify document page. Keyboard insets and text selection remain available;
/// page chrome, background and navigation are supplied by the design system.
class DifyPage extends StatelessWidget {
  const DifyPage({super.key, required this.body, this.backgroundColor});
  final Widget body;
  final Color? backgroundColor;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: backgroundColor ?? DifyColors.backgroundBody,
    resizeToAvoidBottomInset: true,
    body: body,
  );
}

/// Owns Material's framework bootstrap; pages use Dify components. Theme changes
/// are immediate, like next-themes' disableTransitionOnChange.
class DifyApplication extends StatelessWidget {
  const DifyApplication({
    super.key,
    required this.home,
    required this.theme,
    this.navigatorKey,
    this.builder,
    this.title = 'dify-sf',
  });
  final Widget home;
  final ThemeData theme;
  final GlobalKey<NavigatorState>? navigatorKey;
  final TransitionBuilder? builder;
  final String title;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: title,
    home: DifySelectionRegion(child: home),
    theme: theme,
    navigatorKey: navigatorKey,
    builder: builder,
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
  );
}
