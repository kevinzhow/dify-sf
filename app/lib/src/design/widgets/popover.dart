import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'floating.dart';
import 'placement.dart';

/// The PopoverContent surface: `rounded-xl border-[0.5px] border-components-panel-border bg-components-panel-bg
/// shadow-lg`.
class DifyPopoverSurface extends StatelessWidget {
  const DifyPopoverSurface({super.key, required this.child, this.padding = EdgeInsets.zero, this.width});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? width;

  static final decoration = BoxDecoration(
    color: DifyColors.componentsPanelBg,
    border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
    borderRadius: BorderRadius.circular(DifyRadius.xl),
    boxShadow: DifyShadows.lg,
  );

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: padding,
    decoration: decoration,
    child: child,
  );
}

/// dify-ui's Popover (Root + Trigger + PopoverContent): [builder] builds the trigger, which toggles the popup with
/// the controller; [content] opens below it (placement `bottom`, sideOffset 8), scaling from 0.95 and fading in.
/// Focus moves to [initialFocus] (else the popup) and back to the trigger on close; Escape and outside taps close
/// it. [surface] false composes the bare positioner and popup (`PopoverPositioner` + `PopoverPopup`), for content
/// that draws its own surface.
class DifyPopover extends StatelessWidget {
  const DifyPopover({
    super.key,
    required this.builder,
    required this.content,
    this.controller,
    this.open,
    this.onOpenChange,
    this.placement = DifyPlacement.bottom,
    this.sideOffset = 8,
    this.alignOffset = 0,
    this.initialFocus,
    this.surface = true,
    this.semanticLabel,
  });

  final DifyTriggerBuilder builder;
  final Widget content;
  final DifyFloatingController? controller;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement placement;
  final double sideOffset;
  final double alignOffset;
  final FocusNode? initialFocus;
  final bool surface;

  /// The dialog's name (`PopoverTitle`).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => DifyFloating(
    builder: builder,
    controller: controller,
    open: open,
    onOpenChange: onOpenChange,
    placement: placement,
    sideOffset: sideOffset,
    alignOffset: alignOffset,
    initialFocus: initialFocus,
    popupBuilder: (context) => Semantics(
      container: true,
      role: SemanticsRole.dialog,
      label: semanticLabel,
      explicitChildNodes: true,
      child: surface ? DifyPopoverSurface(child: content) : content,
    ),
  );
}
