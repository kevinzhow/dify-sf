import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Compact Dify chrome uses the viewport, not the device name: rotation and
/// browser split-screen must update it without changing saved desktop widths.
abstract final class DifyAdaptive {
  static const compactWidth = 720.0;
  static bool compactOf(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidth;
  static bool toolbarCompactOf(BuildContext context) => MediaQuery.sizeOf(context).width < 1280;
  static double panelWidth(BuildContext context, double desktop, {double inset = 8}) =>
      compactOf(context) ? math.min(desktop, math.max(0, MediaQuery.sizeOf(context).width - inset)) : desktop;
}

/// A narrow toolbar keeps every existing Dify action reachable by swiping.
class DifyToolbarStrip extends StatelessWidget {
  const DifyToolbarStrip({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: child,
  );
}
