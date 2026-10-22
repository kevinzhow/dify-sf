/// Dify's Next.js page navigation, distinct from its animated dialogs/drawers.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Web and desktop pages replace their content without Material's mobile slide,
/// zoom, fade-through or back-swipe transition. Dify's console/account layouts
/// mount their children directly; component-level animations remain in place.
/// Native Android/iOS retain their platform navigation behavior.
PageRoute<T> difyPageRoute<T>({required WidgetBuilder builder, RouteSettings? settings}) {
  final desktop =
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
        _ => false,
      };
  if (!desktop) return MaterialPageRoute<T>(builder: builder, settings: settings);
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}
