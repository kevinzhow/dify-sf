/// The dify-ui form controls node panels are built from (packages/dify-ui: switch, slider, input, number-field,
/// segmented-control; web/app/components/base: badge, infotip).
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';

/// Pointer, focus and keyboard activation for controls that are not buttons (switch, segmented item).
class _Control extends StatefulWidget {
  const _Control({required this.builder, this.onActivate, this.disabled = false});
  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final VoidCallback? onActivate;
  final bool disabled;

  @override
  State<_Control> createState() => _ControlState();
}

class _ControlState extends State<_Control> {
  bool _hovered = false, _focused = false;

  void _activate() {
    if (!widget.disabled) widget.onActivate?.call();
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
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

/// `focus-visible:ring-2 focus-visible:ring-state-accent-solid`.
List<BoxShadow>? _ring(bool focused) =>
    focused ? const [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)] : null;

/// Switch sizes (switch/index.tsx): track, radius, padding, thumb, thumb radius, checked travel.
enum DifySwitchSize {
  xs(Size(14, 10), 2, 2, Size(4, 6), 1, 6),
  sm(Size(20, 12), 3.5, 2, Size(7, 8), 2, 9),
  md(Size(28, 16), 5, 2, Size(10, 12), 3, 14),
  lg(Size(36, 20), 6, 3, Size(14, 14), 4, 16);

  const DifySwitchSize(this.track, this.radius, this.padding, this.thumb, this.thumbRadius, this.travel);
  final Size track;
  final double radius, padding;
  final Size thumb;
  final double thumbRadius, travel;
}

/// dify-ui's Switch: the toggle background and knob, sliding over 200 ms.
class DifySwitch extends StatelessWidget {
  const DifySwitch({
    super.key,
    required this.checked,
    this.onCheckedChange,
    this.size = DifySwitchSize.md,
    this.disabled = false,
    this.semanticLabel,
  });

  final bool checked;
  final ValueChanged<bool>? onCheckedChange;
  final DifySwitchSize size;
  final bool disabled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    toggled: checked,
    enabled: !disabled,
    label: semanticLabel,
    onTap: disabled ? null : () => onCheckedChange?.call(!checked),
    child: _Control(
      disabled: disabled,
      onActivate: () => onCheckedChange?.call(!checked),
      builder: (context, hovered, focused) {
        final bg = switch ((checked, disabled)) {
          (true, true) => DifyColors.componentsToggleBgDisabled,
          (false, true) => DifyColors.componentsToggleBgUncheckedDisabled,
          (true, false) => hovered ? DifyColors.componentsToggleBgHover : DifyColors.componentsToggleBg,
          (false, false) =>
            hovered ? DifyColors.componentsToggleBgUncheckedHover : DifyColors.componentsToggleBgUnchecked,
        };
        final knob = disabled
            ? DifyColors.componentsToggleKnobDisabled
            : hovered
            ? DifyColors.componentsToggleKnobHover
            : DifyColors.componentsToggleKnob;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: size.track.width,
          height: size.track.height,
          padding: EdgeInsets.all(size.padding),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(size.radius),
            boxShadow: _ring(focused),
          ),
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            offset: Offset(checked ? size.travel / size.thumb.width : 0, 0),
            child: Container(
              width: size.thumb.width,
              height: size.thumb.height,
              decoration: BoxDecoration(
                color: knob,
                borderRadius: BorderRadius.circular(size.thumbRadius),
                boxShadow: disabled
                    ? null
                    : hovered
                    ? DifyShadows.md
                    : DifyShadows.sm,
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// dify-ui's Slider (Root + Control + Track + Indicator + Thumb): a 20 px control with a 4 px track, the range
/// filled up to the value and an 8 x 20 knob; drag or tap to set, arrow keys step, Home / End jump. [valueText] is
/// the thumb's `getAriaValueText`. Disabled: 30 % opacity.
class DifySlider extends StatefulWidget {
  const DifySlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    this.onChanged,
    this.disabled = false,
    this.semanticLabel,
    this.valueText,
    this.trackColor,
    this.rangeColor,
  });

  final int value, min, max, step;
  final ValueChanged<int>? onChanged;
  final bool disabled;
  final String? semanticLabel;
  final String Function(int value)? valueText;

  /// Call-site track / range colours (`bg-components-slider-track`, `bg-components-slider-range` by default).
  final Color? trackColor, rangeColor;

  @override
  State<DifySlider> createState() => _DifySliderState();
}

class _DifySliderState extends State<DifySlider> {
  bool _hovered = false, _focused = false;

  int _clamp(int v) => v.clamp(widget.min, widget.max);

  void _set(int v) {
    final next = _clamp(v);
    if (next != widget.value && !widget.disabled) widget.onChanged?.call(next);
  }

  void _at(double dx, double width) {
    if (width <= 0) return;
    final raw = widget.min + (dx / width).clamp(0.0, 1.0) * (widget.max - widget.min);
    _set(widget.min + ((raw - widget.min) / widget.step).round() * widget.step);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final s = widget.step, v = widget.value;
    final k = e.logicalKey;
    final next = k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp
        ? v + s
        : k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowDown
        ? v - s
        : k == LogicalKeyboardKey.pageUp
        ? v + s * 10
        : k == LogicalKeyboardKey.pageDown
        ? v - s * 10
        : k == LogicalKeyboardKey.home
        ? widget.min
        : k == LogicalKeyboardKey.end
        ? widget.max
        : null;
    if (next == null) return KeyEventResult.ignored;
    _set(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final span = w.max - w.min;
    final fraction = span <= 0 ? 0.0 : ((w.value - w.min) / span).clamp(0.0, 1.0);
    String text(int v) => w.valueText?.call(v) ?? '$v';
    return Semantics(
      container: true,
      slider: true,
      label: w.semanticLabel,
      value: text(w.value),
      increasedValue: text(_clamp(w.value + w.step)),
      decreasedValue: text(_clamp(w.value - w.step)),
      enabled: !w.disabled,
      onIncrease: w.disabled ? null : () => _set(w.value + w.step),
      onDecrease: w.disabled ? null : () => _set(w.value - w.step),
      child: Focus(
        canRequestFocus: !w.disabled,
        onKeyEvent: _key,
        onFocusChange: (f) => setState(() => _focused = f),
        child: Opacity(
          opacity: w.disabled ? 0.3 : 1,
          child: MouseRegion(
            cursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: LayoutBuilder(
              builder: (context, c) {
                final width = c.maxWidth.isFinite ? c.maxWidth : 144.0;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTapDown: w.disabled
                      ? null
                      : (d) {
                          Focus.of(context).requestFocus();
                          _at(d.localPosition.dx, width);
                        },
                  onHorizontalDragUpdate: w.disabled ? null : (d) => _at(d.localPosition.dx, width),
                  child: SizedBox(
                    width: width,
                    height: 20,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: w.trackColor ?? DifyColors.componentsSliderTrack,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Container(
                          width: width * fraction,
                          height: 4,
                          decoration: BoxDecoration(
                            color: w.rangeColor ?? DifyColors.componentsSliderRange,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Positioned(
                          left: width * fraction - 4,
                          child: Container(
                            width: 8,
                            height: 20,
                            decoration: BoxDecoration(
                              color: w.disabled
                                  ? DifyColors.componentsSliderKnobDisabled
                                  : _hovered
                                  ? DifyColors.componentsSliderKnobHover
                                  : DifyColors.componentsSliderKnob,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: DifyColors.componentsSliderKnobBorder, width: Css.hairline),
                              boxShadow: _focused ? _ring(true) : (w.disabled ? null : DifyShadows.sm),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The text-field box shared by Input and NumberField: `rounded-lg border border-transparent
/// bg-components-input-bg-normal`, hover `border-components-input-border-hover bg-components-input-bg-hover`, focus
/// `border-components-input-border-active bg-components-input-bg-active shadow-xs`, disabled
/// `bg-components-input-bg-disabled`; read-only boxes keep the normal look.
class _InputBox extends StatefulWidget {
  const _InputBox({
    required this.focusNode,
    required this.child,
    this.disabled = false,
    this.readOnly = false,
    this.invalid = false,
  });
  final FocusNode focusNode;
  final Widget child;
  final bool disabled, readOnly, invalid;

  @override
  State<_InputBox> createState() => _InputBoxState();
}

class _InputBoxState extends State<_InputBox> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(_InputBox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final focused = w.focusNode.hasFocus && !w.readOnly && !w.disabled;
    final hovered = _hovered && !w.readOnly && !w.disabled;
    var bg = DifyColors.componentsInputBgNormal;
    var border = const Color(0x00000000);
    if (w.disabled) {
      bg = DifyColors.componentsInputBgDisabled;
    } else if (w.invalid) {
      bg = DifyColors.componentsInputBgDestructive;
      border = DifyColors.componentsInputBorderDestructive;
    } else if (focused) {
      bg = DifyColors.componentsInputBgActive;
      border = DifyColors.componentsInputBorderActive;
    } else if (hovered) {
      bg = DifyColors.componentsInputBgHover;
      border = DifyColors.componentsInputBorderHover;
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: border),
          boxShadow: focused ? DifyShadows.xs : null,
        ),
        child: w.child,
      ),
    );
  }
}

/// A [TextEditingController] kept in step with a controlled value: replaced when [value] changes from outside, left
/// alone while it matches (so the selection survives typing).
mixin _ControlledText<T extends StatefulWidget> on State<T> {
  late final controller = TextEditingController(text: textOf(widget));
  String textOf(T widget);

  void syncText() {
    final text = textOf(widget);
    if (controller.text != text) controller.value = TextEditingValue(text: text, selection: _end(text));
  }

  static TextSelection _end(String s) => TextSelection.collapsed(offset: s.length);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// [TextField] with Dify's input text: `system-sm-regular text-components-input-text-filled`, placeholder colour,
/// `caret-primary-600`, no decoration of its own.
TextField _field({
  required TextEditingController controller,
  required FocusNode focusNode,
  required TextStyle style,
  required EdgeInsets padding,
  String? placeholder,
  bool readOnly = false,
  bool disabled = false,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
  List<TextInputFormatter>? formatters,
  TextInputType? keyboardType,
  bool obscureText = false,
  Iterable<String>? autofillHints,
  int? maxLength,
  TextInputAction? textInputAction,
}) => TextField(
  controller: controller,
  focusNode: focusNode,
  readOnly: readOnly,
  enabled: !disabled,
  obscureText: obscureText,
  autofillHints: autofillHints,
  autocorrect: !obscureText && keyboardType != TextInputType.emailAddress,
  enableSuggestions: !obscureText,
  textInputAction: textInputAction,
  maxLength: maxLength,
  maxLengthEnforcement: maxLength == null ? null : MaxLengthEnforcement.enforced,
  onChanged: onChanged,
  onSubmitted: onSubmitted,
  inputFormatters: formatters,
  keyboardType: keyboardType,
  style: style.copyWith(color: disabled ? DifyColors.componentsInputTextFilledDisabled : null),
  cursorColor: const Color(0xFF155EEF), // caret-primary-600
  cursorWidth: 1,
  maxLines: 1,
  decoration: InputDecoration(
    isCollapsed: true,
    border: InputBorder.none,
    contentPadding: padding,
    // Not the desktop platforms' compact density, which takes 8 px off the box (CSS has no such thing).
    visualDensity: VisualDensity.standard,
    hintText: placeholder,
    hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
    // `maxlength` shows no counter in a browser.
    counterText: '',
  ),
);

/// dify-ui's Input: `w-full rounded-lg px-3 py-1.75 system-sm-regular` on the input box (32 px high). Controlled:
/// shows [value], reports edits with [onChanged]. [formatters] run on each edit (e.g. spaces to underscores).
class DifyInput extends StatefulWidget {
  const DifyInput({
    super.key,
    required this.value,
    this.onChanged,
    this.onSubmitted,
    this.placeholder,
    this.semanticLabel,
    this.readOnly = false,
    this.disabled = false,
    this.invalid = false,
    this.formatters,
    this.keyboardType,
    this.focusNode,
    this.height,
    this.leading,
    this.trailing,
    this.onKeyEvent,
    this.textStyle,
    this.fontFamily,
    this.obscureText = false,
    this.autofillHints,
    this.maxLength,
    this.textInputAction,
  });

  final String value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? placeholder;

  /// `aria-label`.
  final String? semanticLabel;
  final bool readOnly, disabled, invalid;
  final List<TextInputFormatter>? formatters;
  final TextInputType? keyboardType;
  final FocusNode? focusNode;

  /// A fixed height (`h-8` …); the default is the padding plus the line.
  final double? height;

  /// InputGroup addons before and after the text (the text loses its padding on that side).
  final Widget? leading, trailing;

  /// Keys pressed while the field has focus, before the text field sees them.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The text's style (`system-sm-regular text-components-input-text-filled` by default); [fontFamily] replaces
  /// just the family (`font-mono` call sites).
  final TextStyle? textStyle;
  final String? fontFamily;

  /// `type="password"`, `autocomplete`, `maxlength` and the keyboard's action (Enter submits a form).
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final TextInputAction? textInputAction;

  @override
  State<DifyInput> createState() => _DifyInputState();
}

class _DifyInputState extends State<DifyInput> with _ControlledText<DifyInput> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'DifyInput'));

  @override
  String textOf(DifyInput w) => w.value;

  @override
  void didUpdateWidget(DifyInput old) {
    super.didUpdateWidget(old);
    syncText();
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget field = _field(
      controller: controller,
      focusNode: _focus,
      style: (w.textStyle ?? difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled)).copyWith(
        fontFamily: w.fontFamily,
      ),
      padding: EdgeInsets.fromLTRB(w.leading == null ? 12 : 0, 7, w.trailing == null ? 12 : 0, 7),
      placeholder: w.placeholder,
      readOnly: w.readOnly,
      disabled: w.disabled,
      onChanged: w.onChanged,
      onSubmitted: w.onSubmitted,
      formatters: w.formatters,
      keyboardType: w.keyboardType,
      obscureText: w.obscureText,
      autofillHints: w.autofillHints,
      maxLength: w.maxLength,
      textInputAction: w.textInputAction,
    );
    if (w.height != null) {
      field = SizedBox(
        height: w.height! - 2,
        child: Center(child: field),
      );
    }
    if (w.onKeyEvent != null) {
      field = Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: w.onKeyEvent, child: field);
    }
    if (w.leading != null || w.trailing != null) {
      // Taps on the addons (the clear button) are not taps outside the field.
      field = Row(
        children: [
          if (w.leading != null) TextFieldTapRegion(child: w.leading!),
          Expanded(child: field),
          if (w.trailing != null) TextFieldTapRegion(child: w.trailing!),
        ],
      );
    }
    return Semantics(
      label: w.semanticLabel,
      child: _InputBox(
        focusNode: _focus,
        disabled: w.disabled,
        readOnly: w.readOnly,
        invalid: w.invalid,
        child: field,
      ),
    );
  }
}

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
  final bool disabled, readOnly;
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

class _DifyNumberFieldState extends State<DifyNumberField> with _ControlledText<DifyNumberField> {
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
        semanticLabel: direction > 0 ? 'Increment' : 'Decrement',
        onPressed: () => _stepBy(direction),
        builder: (context, hovered, focused) => Container(
          width: 24,
          alignment: Alignment.center,
          color: hovered ? DifyColors.stateBaseHover : null,
          child: RemixIcon(
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
      child: _InputBox(
        focusNode: _focus,
        disabled: w.disabled,
        readOnly: w.readOnly,
        child: Row(
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _key,
                canRequestFocus: false,
                skipTraversal: true,
                child: _field(
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
                  child: Text(
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
                decoration: const BoxDecoration(
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

/// One option of a [DifySegmentedControl]: its [value], what it shows and its accessible [label].
typedef DifySegment<T> = ({T value, Widget child, String label});

/// dify-ui's SegmentedControl: `inline-flex gap-px rounded-[10px] bg-components-segmented-control-bg-normal p-0.5`
/// around radio items (`h-7 rounded-lg border-[0.5px] px-2 py-1 system-sm-medium`; checked: the active background,
/// border and accent text with shadow-xs). [itemPadding], [textColor], [checkedTextColor] and [bordered] take
/// call-site overrides (FormInputTypeSwitch: `border-0 px-2.5 py-1.5`, tertiary / secondary text). [tooltip] wraps
/// unchecked items.
class DifySegmentedControl<T> extends StatelessWidget {
  const DifySegmentedControl({
    super.key,
    required this.value,
    required this.segments,
    this.onChanged,
    this.disabled = false,
    this.height = 32,
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.textColor = DifyColors.textSecondary,
    this.checkedTextColor = DifyColors.textAccentLightModeOnly,
    this.bordered = true,
    this.tooltip = false,
    this.padding = 2,
    this.radius = 10,
    this.itemRadius = DifyRadius.lg,
  });

  final T value;
  final List<DifySegment<T>> segments;
  final ValueChanged<T>? onChanged;
  final bool disabled;
  final double height;
  final EdgeInsets itemPadding;
  final Color textColor, checkedTextColor;
  final bool bordered, tooltip;

  /// A call site's `p-*` and `rounded-*` over the control's `p-0.5 rounded-[10px]` and the items' `rounded-lg`.
  final double padding, radius, itemRadius;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: DifyColors.componentsSegmentedControlBgNormal,
      borderRadius: BorderRadius.circular(radius),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 1,
      children: [
        for (final s in segments)
          () {
            final checked = s.value == value;
            Widget item = Semantics(
              container: true,
              checked: checked,
              inMutuallyExclusiveGroup: true,
              enabled: !disabled,
              label: s.label,
              onTap: disabled ? null : () => onChanged?.call(s.value),
              child: _Control(
                disabled: disabled,
                onActivate: () => onChanged?.call(s.value),
                builder: (context, hovered, focused) {
                  final color = disabled && !checked
                      ? DifyColors.textDisabled
                      : checked
                      ? checkedTextColor
                      : textColor;
                  return Container(
                    padding: itemPadding,
                    decoration: BoxDecoration(
                      color: checked
                          ? DifyColors.componentsSegmentedControlItemActiveBg
                          : hovered && !disabled
                          ? DifyColors.stateBaseHover
                          : null,
                      borderRadius: BorderRadius.circular(itemRadius),
                      border: bordered
                          ? Border.all(
                              color: checked
                                  ? DifyColors.componentsSegmentedControlItemActiveBorder
                                  : const Color(0x00000000),
                              width: Css.hairline,
                            )
                          : null,
                      boxShadow: _ring(focused) ?? (checked ? DifyShadows.xs : null),
                    ),
                    child: IconTheme.merge(
                      data: IconThemeData(color: color),
                      child: DefaultTextStyle.merge(
                        style: difyTextStyle(DifyType.systemSmMedium, color),
                        child: ExcludeSemantics(
                          child: _Tint(color: color, child: s.child),
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
            if (tooltip && !checked) item = DifyTooltip(content: Text(s.label), child: item);
            return item;
          }(),
      ],
    ),
  );
}

/// Gives a [DifyIcon] / [RemixIcon] without a colour the surrounding text colour (CSS `currentColor`).
class _Tint extends StatelessWidget {
  const _Tint({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => switch (child) {
    DifyIcon(:final name, :final size, color: null) => DifyIcon(name, size: size, color: color),
    RemixIcon(:final name, :final size, color: null) => RemixIcon(name, size: size, color: color),
    _ => child,
  };
}

/// Badge (base/badge.tsx): `inline-flex h-5 items-center rounded-[5px] border border-divider-deep px-1.25
/// text-text-tertiary`, `system-2xs-medium-uppercase` (or `system-xs-medium` without [uppercase]).
class DifyBadge extends StatelessWidget {
  const DifyBadge(this.text, {super.key, this.uppercase = true, this.capitalize = false, this.color});
  final String text;
  final bool uppercase;

  /// The text and border colour of a call site's classes (`border-text-accent-secondary text-text-accent-secondary`).
  final Color? color;

  /// `capitalize` (the picker's type placeholders).
  final bool capitalize;

  @override
  Widget build(BuildContext context) => Container(
    height: 20,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: color ?? DifyColors.dividerDeep),
    ),
    child: Center(
      widthFactor: 1,
      child: DifyText(
        capitalize ? cssCapitalize(text) : text,
        uppercase ? DifyType.system2xsMediumUppercase : DifyType.systemXsMedium,
        color: color ?? DifyColors.textTertiary,
      ),
    ),
  );
}

/// Infotip (base/infotip): a 16 px question mark (`text-text-quaternary`, hover tertiary) that opens a popover with
/// [content] on hover (300 ms in, 200 ms out) or on tap; the box is `max-w-75 rounded-md px-3 py-2 system-xs-regular
/// text-text-tertiary` on the popover surface, above the icon.
class Infotip extends StatefulWidget {
  const Infotip({
    super.key,
    required this.label,
    required this.content,
    this.icon = 'question-line',
    this.iconSize = 14,
    this.width,
  });

  /// `aria-label`.
  final String label;
  final Widget content;
  final String icon;
  final double iconSize;

  /// `popupClassName="w-[240px]"` and the like.
  final double? width;

  @override
  State<Infotip> createState() => _InfotipState();
}

class _InfotipState extends State<Infotip> {
  final _floating = DifyFloatingController();
  Timer? _timer;
  bool _hovered = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(bool open) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: open ? 300 : 200), () => open ? _floating.open() : _floating.close());
  }

  bool _mouse(PointerEvent e) => e.kind == PointerDeviceKind.mouse;

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _floating,
    placement: DifyPlacement.top,
    sideOffset: 8,
    focusPopup: false,
    builder: (context, c) => Semantics(
      container: true,
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) {
          setState(() => _hovered = true);
          if (_mouse(e)) _schedule(true);
        },
        onExit: (e) {
          setState(() => _hovered = false);
          if (_mouse(e)) _schedule(false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () {
            _timer?.cancel();
            c.toggle();
          },
          child: SizedBox.square(
            dimension: 16,
            child: Center(
              child: RemixIcon(
                widget.icon,
                size: widget.iconSize,
                color: _hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
              ),
            ),
          ),
        ),
      ),
    ),
    popupBuilder: (context) => MouseRegion(
      onEnter: (_) => _timer?.cancel(),
      onExit: (e) => _mouse(e) ? _schedule(false) : null,
      child: Container(
        width: widget.width,
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: DefaultTextStyle.merge(
          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          child: widget.content,
        ),
      ),
    ),
  );
}

/// prompt-generator-btn.tsx / code-generator-button.tsx: `IconButton` around `Generator size-4 text-primary-600`,
/// shown whether or not a model can generate (Dify's modal then has none to pick). [onPressed] null: there is no
/// generator here, and the button says so.
class GeneratorButton extends StatelessWidget {
  const GeneratorButton({super.key, this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: DifyI18n.tr('app-debug', 'operation.automatic'),
    icon: const DifyIcon('vender/other/generator', size: 16, color: DifyColors.utilColorsBlueBlue600),
    onPressed: onPressed ?? () => toast.error(DifyI18n.tr('app-debug', 'noModelProviderConfigured')),
  );
}
