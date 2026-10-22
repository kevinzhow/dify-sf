import 'package:flutter/material.dart';

/// Monaco's square, flush-to-edge scrollbar. Colors and width come from the
/// pinned editor theme, rather than Material's theme or adaptive density.
class DifyEditorScrollbar extends StatelessWidget {
  const DifyEditorScrollbar({
    super.key,
    required this.child,
    required this.controller,
    required this.visible,
    required this.width,
    required this.color,
    required this.hoverColor,
    required this.activeColor,
  });
  final Widget child;
  final ScrollController controller;
  final bool visible;
  final double width;
  final Color color, hoverColor, activeColor;
  @override
  Widget build(BuildContext context) => ScrollbarTheme(
    data: ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(width),
      radius: Radius.zero,
      crossAxisMargin: 0,
      mainAxisMargin: 0,
      minThumbLength: 20,
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.dragged)
            ? activeColor
            : states.contains(WidgetState.hovered)
            ? hoverColor
            : color,
      ),
    ),
    child: Scrollbar(controller: controller, thumbVisibility: visible, child: child),
  );
}
