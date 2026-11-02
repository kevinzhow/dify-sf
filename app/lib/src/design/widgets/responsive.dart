/// Window size classes and touch metrics for dify-sf's phone and tablet layouts (Dify has no phone breakpoints).
library;

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';

/// Material 3's window size classes by width: [compact] below 600 dp (phones in portrait), [medium] from 600 to
/// 839 dp (tablets in portrait, large unfolded foldables), [expanded] from 840 dp (m3.material.io, "Window size
/// classes"). They describe the window, not a panel ([DifyViewport] is ignored), and are independent of
/// [DifyAdaptive]'s Dify-derived thresholds (720 / 640 / 1280 px), which existing screens keep using.
enum DifyWindowClass {
  compact,
  medium,
  expanded;

  /// The smallest [medium] width.
  static const mediumMinWidth = 600.0;

  /// The smallest [expanded] width.
  static const expandedMinWidth = 840.0;

  /// The class of a window [width] dp wide.
  static DifyWindowClass forWidth(double width) => width < mediumMinWidth
      ? compact
      : width < expandedMinWidth
      ? medium
      : expanded;

  /// The class of the window [context] is shown in (`MediaQuery.size`).
  static DifyWindowClass of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);
}

/// Touch metrics.
abstract final class DifyTouch {
  /// The smallest hit area for a touch control: Material's 48 dp (Apple's guideline is 44 pt). Smaller visual
  /// controls get it from [DifyTouchTarget].
  static const minTarget = 48.0;

  /// Whether the primary input is a finger: true on Android and iOS (the native apps and their mobile browsers, whose
  /// platform the web build reads from the browser), false on the desktop platforms, including the web on a desktop
  /// OS. It answers for the platform, not the pointer in use: an Android tablet with a mouse still answers true, a
  /// touch-screen laptop false. Follows [Theme]'s platform, so tests and previews can override it.
  static bool isCoarse(BuildContext context) => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}
