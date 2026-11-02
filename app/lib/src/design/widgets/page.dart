/// Framework hosts for Dify pages and already styled content.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
///
/// The body stays inside the safe area unless [edgeToEdge]: then the page's background reaches under the system bars
/// and its own phone chrome ([DifyTopAppBar], [DifyNavigationBar], [DifyBottomToolbar], ...) keeps its content clear
/// of them. An edge-to-edge page must also be pushed edge-to-edge ([difyPageRoute]'s or [DifyApplication]'s
/// `edgeToEdge`), since those hosts keep their pages safe by default.
class DifyPage extends StatelessWidget {
  const DifyPage({super.key, required this.body, this.backgroundColor, this.edgeToEdge = false});
  final Widget body;
  final Color? backgroundColor;
  final bool edgeToEdge;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: backgroundColor ?? DifyColors.backgroundBody,
    resizeToAvoidBottomInset: true,
    body: edgeToEdge ? body : SafeArea(child: body),
  );
}

/// The system's safe-area insets for the whole window (status bar, navigation bar, display cutouts), as
/// [DifyApplication] receives them. A page's SafeArea consumes `MediaQuery.padding` for the page, but content that a
/// page puts in the root overlay (popups, editor drawers) is laid out against the whole window: it reads these
/// insets instead ([DifyFloating], [DifyOverlaySafeArea]).
class DifyWindowInsets extends InheritedWidget {
  const DifyWindowInsets({super.key, required this.padding, required super.child});

  final EdgeInsets padding;

  /// The window's insets; without a [DifyApplication] above (tests, tools), the context's `MediaQuery.padding`.
  static EdgeInsets of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DifyWindowInsets>()?.padding ?? MediaQuery.paddingOf(context);

  @override
  bool updateShouldNotify(DifyWindowInsets oldWidget) => padding != oldWidget.padding;
}

/// Lays [child] out in the root overlay's safe area: inside the [DifyWindowInsets], in a Stack that fills it, so
/// [child] may be a Positioned measured from the safe edges. This is how every overlay entry was laid out while
/// [DifyApplication] kept the whole navigator inside one SafeArea; overlay content positioned against the overlay's
/// edges (drawers, expanded editors, modal layers) keeps that geometry with it. Anchored popups use [DifyFloating],
/// which keeps clear of the insets itself.
class DifyOverlaySafeArea extends StatelessWidget {
  const DifyOverlaySafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: DifyWindowInsets.of(context),
    child: MediaQuery.removePadding(
      context: context,
      removeLeft: true,
      removeTop: true,
      removeRight: true,
      removeBottom: true,
      child: Stack(fit: StackFit.expand, children: [child]),
    ),
  );
}

/// Owns Material's framework bootstrap; pages use Dify components. Theme changes
/// are immediate, like next-themes' disableTransitionOnChange.
///
/// The navigator fills the whole window, under the transparent system bars; the app background shows wherever a
/// page does not paint. The system insets are not consumed here: every host design/ owns keeps its content safe
/// itself, so a dialog or a toast built above a page is as safe as the page:
/// - pages: [home] and [difyPageRoute] pages sit in a SafeArea unless pushed `edgeToEdge` ([DifyPage]);
/// - dialog, drawer and sheet routes ([showDifyDialog], [showDifyDrawer], [showDifyBottomSheet]) pad their content
///   while their backdrop covers the window;
/// - root-overlay content reads [DifyWindowInsets]: [DifyFloating] popups, menus, selects and tooltips stay clear of
///   the bars, [DifyOverlaySafeArea] and [DifyDrawerPortal] lay their content out in the safe area;
/// - layers in [builder] over the navigator pad themselves ([DifyToastHost], the font notice);
/// - edge-to-edge phone chrome ([DifyTopAppBar], [DifyNavigationBar], [DifyBottomToolbar], [DifySelectionBar],
///   [DifyPersistentSheet]) paints its background under the bars and pads its content by the insets.
class DifyApplication extends StatelessWidget {
  const DifyApplication({
    super.key,
    required this.home,
    required this.theme,
    this.navigatorKey,
    this.builder,
    this.title = 'dify-sf',
    this.edgeToEdge = false,
  });
  final Widget home;
  final ThemeData theme;
  final GlobalKey<NavigatorState>? navigatorKey;
  final TransitionBuilder? builder;
  final String title;

  /// Whether [home] draws under the system bars (see [DifyPage.edgeToEdge]); pages pushed later choose with
  /// [difyPageRoute].
  final bool edgeToEdge;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: title,
    home: DifySelectionRegion(child: edgeToEdge ? home : SafeArea(child: home)),
    theme: theme,
    navigatorKey: navigatorKey,
    builder: (context, child) {
      final dark = theme.brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        ),
        child: ColoredBox(
          color: DifyColors.backgroundBody,
          child: DefaultTextStyle(
            // MaterialApp's fallback style is red with yellow double lines.
            // Native chrome outside a page's Material still needs a body style.
            style: theme.textTheme.bodyMedium!.copyWith(
              color: DifyColors.textPrimary,
              decoration: TextDecoration.none,
            ),
            child: DifyWindowInsets(
              padding: MediaQuery.paddingOf(context),
              child: Builder(builder: (context) => builder?.call(context, child) ?? child!),
            ),
          ),
        ),
      );
    },
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
  );
}
