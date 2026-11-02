/// Dify's Next.js page navigation, distinct from its animated dialogs/drawers.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'page.dart' show DifyApplication, DifyPage;
import 'selection.dart';

/// Web and desktop pages replace their content without Material's mobile slide,
/// zoom, fade-through or back-swipe transition. Dify's console/account layouts
/// mount their children directly; component-level animations remain in place.
/// Native Android/iOS retain their platform navigation behavior.
///
/// The page stays inside the system's safe area (the app no longer consumes it for the whole navigator, see
/// [DifyApplication]) unless [edgeToEdge]: then it draws under the system bars and its own chrome pads its content
/// (see [DifyPage.edgeToEdge]).
PageRoute<T> difyPageRoute<T>({required WidgetBuilder builder, RouteSettings? settings, bool edgeToEdge = false}) {
  final desktop =
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
        _ => false,
      };
  Widget page(BuildContext context) =>
      DifySelectionRegion(child: edgeToEdge ? builder(context) : SafeArea(child: builder(context)));
  if (!desktop) return MaterialPageRoute<T>(builder: page, settings: settings);
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, animation, secondaryAnimation) => page(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}
