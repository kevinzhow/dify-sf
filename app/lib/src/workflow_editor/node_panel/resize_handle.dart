/// The panel resize handle (web/app/components/base/resize-handle/index.tsx and keyboard.ts) with the pointer drag
/// of nodes/_base/hooks/use-resize-panel.ts.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';

/// The edge of the panel the handle sits on.
enum ResizeSide { left, right, top, bottom }

/// `getKeyboardResizeValue`: arrows move 8 px (32 with Shift) away from or towards [side], Home goes to [min], End to
/// [max]; null for other keys and with Alt, Ctrl or Meta held.
double? keyboardResizeValue(
  LogicalKeyboardKey key, {
  required ResizeSide side,
  required double value,
  required double min,
  double max = double.infinity,
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
  bool meta = false,
}) {
  if (alt || ctrl || meta) return null;
  final step = shift ? 32.0 : 8.0;
  final horizontal = side == ResizeSide.left || side == ResizeSide.right;
  final backward = horizontal ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowUp;
  final forward = horizontal ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowDown;
  final sign = side == ResizeSide.left || side == ResizeSide.top ? -1 : 1;
  final upper = math.max(min, max);
  final double next;
  if (key == backward) {
    next = value - step * sign;
  } else if (key == forward) {
    next = value + step * sign;
  } else if (key == LogicalKeyboardKey.home) {
    next = min;
  } else if (key == LogicalKeyboardKey.end && upper.isFinite) {
    next = upper;
  } else {
    return null;
  }
  return math.max(min, math.min(next, upper));
}

/// ResizeHandle as the node panel uses it (`side="left"`, `absolute top-0 -left-1 h-full w-1 cursor-col-resize`): a
/// 4 px strip with the 2 x 40 grip (`rounded-xs bg-state-base-handle`), filling the strip's height in
/// `state-accent-solid` while hovered, dragged or focused. A focusable separator named [label]: the keyboard resizes
/// to [keyboardResizeValue]'s value ([onResize]); dragging reports the pointer's travel to [onDrag] between
/// [onDragStart] and [onDragEnd].
class ResizeHandle extends StatefulWidget {
  const ResizeHandle({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onResize,
    this.side = ResizeSide.left,
    this.onDragStart,
    this.onDrag,
    this.onDragEnd,
    this.focusNode,
  });

  final double value, min, max;
  final String label;
  final ResizeSide side;
  final ValueChanged<double> onResize;
  final VoidCallback? onDragStart;

  /// The pointer's travel since the drag started, along the handle's axis.
  final ValueChanged<double>? onDrag;
  final VoidCallback? onDragEnd;
  final FocusNode? focusNode;

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'ResizeHandle'));
  bool _hovered = false, _dragging = false, _focused = false;
  double _travel = 0;

  /// The last value sent and not shown yet (keys pressed between two frames build on it).
  double? _sent;

  bool get _horizontal => widget.side == ResizeSide.left || widget.side == ResizeSide.right;

  @override
  void didUpdateWidget(ResizeHandle old) {
    super.didUpdateWidget(old);
    _sent = null;
  }

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final next = keyboardResizeValue(
      e.logicalKey,
      side: widget.side,
      value: _sent ?? widget.value,
      min: widget.min,
      max: widget.max,
      shift: keys.isShiftPressed,
      alt: keys.isAltPressed,
      ctrl: keys.isControlPressed,
      meta: keys.isMetaPressed,
    );
    if (next == null) return KeyEventResult.ignored;
    widget.onResize(_sent = next);
    return KeyEventResult.handled;
  }

  void _start() {
    _travel = 0;
    setState(() => _dragging = true);
    widget.onDragStart?.call();
  }

  void _update(double delta) {
    _travel += delta;
    widget.onDrag?.call(_travel);
  }

  void _end() {
    setState(() => _dragging = false);
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _dragging || _focused;
    // Without a size along the strip a childless Container fills it (`h-full`).
    final grip = Center(
      child: Container(
        width: _horizontal ? 2 : (active ? null : 40),
        height: _horizontal ? (active ? null : 40) : 2,
        decoration: BoxDecoration(
          color: active ? DifyColors.stateAccentSolid : DifyColors.stateBaseHandle,
          borderRadius: BorderRadius.circular(DifyRadius.xs),
        ),
      ),
    );
    final valueText = _horizontal
        ? DifyI18n.tr('common', 'resize.width', {'width': widget.value.round()})
        : DifyI18n.tr('common', 'resize.height', {'height': widget.value.round()});
    return Semantics(
      label: widget.label,
      value: valueText,
      focusable: true,
      focused: _focused,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: MouseRegion(
          cursor: _horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _horizontal ? (_) => _start() : null,
            onHorizontalDragUpdate: _horizontal ? (d) => _update(d.primaryDelta ?? 0) : null,
            onHorizontalDragEnd: _horizontal ? (_) => _end() : null,
            onHorizontalDragCancel: _horizontal ? _end : null,
            onVerticalDragStart: _horizontal ? null : (_) => _start(),
            onVerticalDragUpdate: _horizontal ? null : (d) => _update(d.primaryDelta ?? 0),
            onVerticalDragEnd: _horizontal ? null : (_) => _end(),
            onVerticalDragCancel: _horizontal ? null : _end,
            child: grip,
          ),
        ),
      ),
    );
  }
}
