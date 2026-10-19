/// Shared by dify-ui's form controls (packages/dify-ui/src/form-control-shared.ts): pointer, focus and keyboard
/// activation for controls that are not buttons, and the focus-visible ring.
library;

import 'package:flutter/material.dart';

import '../dify_tokens.g.dart';

/// Pointer, focus and keyboard activation for controls that are not buttons (switch, segmented item).
class DifyControl extends StatefulWidget {
  const DifyControl({super.key, required this.builder, this.onActivate, this.disabled = false, this.focusNode});
  final FocusNode? focusNode;
  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final VoidCallback? onActivate;
  final bool disabled;

  @override
  State<DifyControl> createState() => _DifyControlState();
}

class _DifyControlState extends State<DifyControl> {
  bool _hovered = false, _focused = false;

  void _activate() {
    if (!widget.disabled) widget.onActivate?.call();
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    focusNode: widget.focusNode,
    enabled: !widget.disabled,
    mouseCursor: widget.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
    actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate())},
    onShowFocusHighlight: (v) => setState(() => _focused = v),
    onShowHoverHighlight: (v) => setState(() => _hovered = v),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: widget.disabled ? null : _activate,
      child: widget.builder(context, _hovered && !widget.disabled, _focused),
    ),
  );
}

/// `focus-visible:ring-2 focus-visible:ring-state-accent-solid` ([width] 1: `ring-1`); null when not [focused].
List<BoxShadow>? difyFocusRing(bool focused, {double width = 2}) =>
    focused ? [difyFocusRingShadow(width: width)] : null;

/// The ring's shadow alone, for a list that holds other shadows too.
BoxShadow difyFocusRingShadow({double width = 2}) => BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: width);
