/// dify-ui's NumberField (packages/dify-ui/src/number-field).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// dify-ui's NumberField (Group + Input + Unit): a number typed as text, committed on blur or Enter (parsed, clamped
/// to [min]..[max] and rounded to [step]; text that is no number reports null and shows [value] again); ArrowUp /
/// ArrowDown step it at once. [unit] trails the input (`pe-2 system-sm-regular text-text-tertiary`).
class DifyNumberField extends StatefulWidget {
  const DifyNumberField({
    super.key,
    required this.value,
    this.onChanged,
    this.min,
    this.max,
    this.step = 1,
    this.unit,
    this.disabled = false,
    this.readOnly = false,
    this.invalid = false,
    this.incrementLabel = 'Increment value',
    this.decrementLabel = 'Decrement value',
    this.incrementIcon,
    this.decrementIcon,
    this.semanticLabel,
    this.focusNode,
    this.inputPaddingRight = 12,
    this.showControls = false,
  });

  final num value;
  final ValueChanged<num?>? onChanged;
  final num? min, max;
  final num step;
  final String? unit;
  final bool disabled, readOnly, invalid;
  final String incrementLabel, decrementLabel;
  final Widget? incrementIcon, decrementIcon;
  final String? semanticLabel;
  final FocusNode? focusNode;

  /// `pr-0` on the input (the memory window).
  final double inputPaddingRight;

  /// NumberFieldControls: the increment / decrement buttons stacked at the end (`border-l border-divider-subtle`,
  /// `i-ri-arrow-up-s-line` / `i-ri-arrow-down-s-line`).
  final bool showControls;

  @override
  State<DifyNumberField> createState() => _DifyNumberFieldState();
}

class _DifyNumberFieldState extends State<DifyNumberField> with DifyControlledText<DifyNumberField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'DifyNumberField'));

  static String format(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  @override
  String textOf(DifyNumberField w) => format(w.value);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(DifyNumberField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus || old.value != widget.value) syncText();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) _commit();
  }

  num _normalize(num v) {
    final w = widget;
    var n = v;
    if (w.min != null && n < w.min!) n = w.min!;
    if (w.max != null && n > w.max!) n = w.max!;
    final base = w.min ?? 0;
    n = base + ((n - base) / w.step).round() * w.step;
    return n == n.roundToDouble() ? n.round() : n;
  }

  void _commit() {
    final parsed = num.tryParse(controller.text.trim());
    if (parsed == null) {
      widget.onChanged?.call(null);
    } else {
      final n = _normalize(parsed);
      if (n != widget.value) widget.onChanged?.call(n);
    }
    // The parent shows the value it keeps; until it rebuilds, show the committed one.
    final shown = parsed == null ? widget.value : _normalize(parsed);
    controller.value = TextEditingValue(
      text: format(shown),
      selection: TextSelection.collapsed(offset: format(shown).length),
    );
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (widget.readOnly || widget.disabled || (e is! KeyDownEvent && e is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final up = e.logicalKey == LogicalKeyboardKey.arrowUp, down = e.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!up && !down) return KeyEventResult.ignored;
    _stepBy(up ? 1 : -1);
    return KeyEventResult.handled;
  }

  /// One [DifyNumberField.step] up (1) or down (-1), reported at once.
  void _stepBy(int direction) {
    if (widget.readOnly || widget.disabled) return;
    final current = num.tryParse(controller.text.trim()) ?? widget.value;
    final n = _normalize(current + direction * widget.step);
    controller.text = format(n);
    if (n != widget.value) widget.onChanged?.call(n);
  }

  Widget _control(int direction) {
    final w = widget;
    final atLimit = direction > 0 ? (w.max != null && w.value >= w.max!) : (w.min != null && w.value <= w.min!);
    return Expanded(
      child: DifyPressable(
        disabled: w.disabled || w.readOnly || atLimit,
        semanticLabel: direction > 0 ? w.incrementLabel : w.decrementLabel,
        onPressed: () => _stepBy(direction),
        builder: (context, hovered, focused) => Container(
          width: 24,
          alignment: Alignment.center,
          color: hovered ? DifyColors.stateBaseHover : null,
          child:
              (direction > 0 ? w.incrementIcon : w.decrementIcon) ??
              RemixIcon(
                direction > 0 ? 'arrow-up-s-line' : 'arrow-down-s-line',
                size: 12,
                color: DifyColors.textTertiary,
              ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    return Semantics(
      label: w.semanticLabel,
      validationResult: w.invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
      child: DifyInputBox(
        focusNode: _focus,
        disabled: w.disabled,
        readOnly: w.readOnly,
        invalid: w.invalid,
        child: Row(
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _key,
                canRequestFocus: false,
                skipTraversal: true,
                child: difyTextField(
                  context: context,
                  controller: controller,
                  focusNode: _focus,
                  style: style,
                  padding: EdgeInsets.fromLTRB(12, 7, w.inputPaddingRight, 7),
                  readOnly: w.readOnly,
                  disabled: w.disabled,
                  onSubmitted: (_) => _commit(),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                ),
              ),
            ),
            if (w.unit != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                // Units are short ("times", "ms"); a long one is cut rather than squeezing the number.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 56),
                  child: DifyTextLine(
                    w.unit!,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: style.copyWith(color: DifyColors.textTertiary),
                  ),
                ),
              ),
            if (w.showControls)
              Container(
                height: 30,
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: DifyColors.dividerSubtle)),
                ),
                child: Column(children: [_control(1), _control(-1)]),
              ),
          ],
        ),
      ),
    );
  }
}

/// `DifyNumberField`'s number text (integers without `.0`).
abstract final class DifyNumberFieldText {
  static String format(num v) => v == v.roundToDouble() && v.abs() < 9e15 ? '${v.round()}' : '$v';
}
