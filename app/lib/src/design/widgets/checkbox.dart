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

/// dify-ui's Checkbox: a [DifyCheckboxBox] that toggles on a click (or Space / Enter), named [label].
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
  Widget build(BuildContext context) => Semantics(
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
  );
}
