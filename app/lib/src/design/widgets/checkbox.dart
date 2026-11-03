/// dify-ui's Checkbox (packages/dify-ui/src/checkbox).
library;

import 'dart:ui' show SemanticsValidationResult;

import 'package:flutter/material.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// dify-ui's Checkbox box (16 px, `rounded-[4px] shadow-xs`): the accent background with a white check (or a dash
/// when [indeterminate]) when checked; the hover and disabled colours. Only the look: [DifyCheckbox] is the control.
class DifyCheckboxBox extends StatelessWidget {
  const DifyCheckboxBox({
    super.key,
    required this.checked,
    this.indeterminate = false,
    this.disabled = false,
    this.hovered = false,
    this.focused = false,
  });

  final bool checked, indeterminate, disabled, hovered, focused;

  @override
  Widget build(BuildContext context) {
    final on = checked || indeterminate;
    final Color bg, border;
    if (disabled) {
      bg = on ? DifyColors.componentsCheckboxBgDisabledChecked : DifyColors.componentsCheckboxBgDisabled;
      border = on ? const Color(0x00000000) : DifyColors.componentsCheckboxBorderDisabled;
    } else if (on) {
      bg = hovered ? DifyColors.componentsCheckboxBgHover : DifyColors.componentsCheckboxBg;
      border = const Color(0x00000000);
    } else {
      bg = hovered ? DifyColors.componentsCheckboxBgUncheckedHover : DifyColors.componentsCheckboxBgUnchecked;
      border = hovered ? DifyColors.componentsCheckboxBorderHover : DifyColors.componentsCheckboxBorder;
    }
    final icon = disabled ? DifyColors.componentsCheckboxIconDisabled : DifyColors.componentsCheckboxIcon;
    return Container(
      width: 16,
      height: 16,
      decoration: DifyFocusDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(4),
        boxShadow: focused
            ? [difyFocusRingShadow()]
            : [BoxShadow(color: DifyColors.shadowShadow3, offset: Offset(0, 1), blurRadius: 2)],
      ),
      child: !on
          ? null
          : indeterminate
          ? Center(child: Container(width: 8, height: 1.5, color: icon))
          : RemixIcon('check-line', size: 12, color: icon),
    );
  }
}

/// dify-ui's Checkbox: a [DifyCheckboxBox] that toggles on a click (or Space / Enter), named [label]. One node for
/// assistive technology (Base UI's `role="checkbox"` button): its name, state and tap together (a state node without
/// the tap and an unnamed button beside it were two stops for TalkBack).
class DifyCheckbox extends StatelessWidget {
  const DifyCheckbox({
    super.key,
    required this.checked,
    this.onChanged,
    this.disabled = false,
    this.indeterminate = false,
    this.label,
    this.invalid = false,
    this.description,
  });

  final bool checked, disabled, indeterminate;
  final ValueChanged<bool>? onChanged;
  final String? label;

  /// `aria-invalid`, and the text it is described by (`aria-describedby`).
  final bool invalid;
  final String? description;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      checked: checked,
      mixed: indeterminate,
      enabled: !disabled,
      label: label,
      hint: description,
      validationResult: invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
      child: DifyPressable(
        disabled: disabled,
        onPressed: onChanged == null ? null : () => onChanged!(!checked),
        builder: (context, hovered, focused) => DifyCheckboxBox(
          checked: checked,
          indeterminate: indeterminate,
          disabled: disabled,
          hovered: hovered,
          focused: focused,
        ),
      ),
    ),
  );
}

/// A [DifyCheckbox] and its text in a `<label>` (`flex h-6 items-center space-x-2`): a tap on the text toggles too.
/// [child] is the visible text (by default [label] in system-sm-medium text-secondary); [label] names the box.
///
/// One node for assistive technology (the box's name, state and tap; the text is not a stop of its own). In a compact
/// window (a phone) the row is at least [DifyTouch.controlHeight] tall and that node is the whole row, box and text:
/// the 16 px box alone is no target for a finger or for TalkBack's focus. Wider windows keep the `h-6` row.
class DifyCheckboxLabel extends StatelessWidget {
  const DifyCheckboxLabel({
    super.key,
    required this.label,
    required this.checked,
    this.onChanged,
    this.disabled = false,
    this.child,
  });

  final String label;
  final bool checked, disabled;
  final ValueChanged<bool>? onChanged;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final toggle = disabled || onChanged == null ? null : () => onChanged!(!checked);
    final text =
        child ??
        DifyTextLine(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
        );
    final box = DifyCheckbox(checked: checked, disabled: disabled, label: label, onChanged: onChanged);
    final phone = DifyTouch.compactOf(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        box,
        Flexible(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: toggle,
            // The box carries the name: the text is no unlabelled button of its own.
            excludeFromSemantics: true,
            child: ExcludeSemantics(child: text),
          ),
        ),
      ],
    );
    if (!phone) return SizedBox(height: 24, child: row);
    // A phone: the row is the target (a tap anywhere on it toggles) and the box's node grows to it.
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: toggle,
        excludeFromSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DifyTouch.controlHeight),
          child: Padding(padding: const EdgeInsets.only(right: 8), child: row),
        ),
      ),
    );
  }
}
