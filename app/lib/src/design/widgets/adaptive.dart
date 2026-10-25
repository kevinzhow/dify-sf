import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Compact Dify chrome uses the viewport, not the device name: rotation and
/// browser split-screen must update it without changing saved desktop widths.
abstract final class DifyAdaptive {
  static const compactWidth = 720.0;

  /// Tailwind's `sm:` media query is relative to the full viewport, not a panel.
  static const smallMediaWidth = 640.0;
  static bool smallMediaOf(BuildContext context) => MediaQuery.sizeOf(context).width >= smallMediaWidth;
  static double widthOf(BuildContext context) => DifyViewport.maybeWidthOf(context) ?? MediaQuery.sizeOf(context).width;
  static bool compactOf(BuildContext context) => widthOf(context) < compactWidth;
  static bool toolbarCompactOf(BuildContext context) => MediaQuery.sizeOf(context).width < 1280;
  static double panelWidth(BuildContext context, double desktop, {double inset = 8}) =>
      compactOf(context) ? math.min(desktop, math.max(0, widthOf(context) - inset)) : desktop;
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

/// The usable page width inside existing navigation, without changing the
/// global MediaQuery used by dialogs and screen-coordinate overlays.
class DifyViewport extends InheritedWidget {
  const DifyViewport({super.key, required this.width, required super.child});
  final double width;
  static double? maybeWidthOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DifyViewport>()?.width;
  @override
  bool updateShouldNotify(DifyViewport oldWidget) => width != oldWidget.width;
}

/// CSS `flex justify-between` without wrapping. Intrinsically wide translated
/// controls stay reachable by scrolling instead of producing a RenderFlex overflow.
class DifyJustifiedRow extends StatelessWidget {
  const DifyJustifiedRow({super.key, required this.children, this.crossAxisAlignment = CrossAxisAlignment.center});
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0),
        child: IntrinsicWidth(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: crossAxisAlignment,
            children: children,
          ),
        ),
      ),
    ),
  );
}
