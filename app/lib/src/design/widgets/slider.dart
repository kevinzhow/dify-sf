/// dify-ui's Slider (packages/dify-ui/src/slider).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../css_metrics.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// dify-ui's Slider (Root + Control + Track + Indicator + Thumb): a 20 px control with a 4 px track, the range
/// filled up to the value and an 8 x 20 knob; drag or tap to set, arrow keys step, Home / End jump. [valueText] is
/// the thumb's `getAriaValueText`. Disabled: 30 % opacity.
class DifySlider extends StatefulWidget {
  const DifySlider({
    super.key,
    required int this.value,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    ValueChanged<int>? onChanged,
    this.disabled = false,
    this.semanticLabel,
    String Function(int value)? valueText,
    this.trackColor,
    this.rangeColor,
  }) : _integerChanged = onChanged,
       _decimalChanged = null,
       _integerText = valueText,
       _decimalText = null,
       _decimal = false;

  /// Decimal values share the same rendering and interactions while preserving the integer constructor's API.
  const DifySlider.decimal({
    super.key,
    required double this.value,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    ValueChanged<double>? onChanged,
    this.disabled = false,
    this.semanticLabel,
    String Function(double value)? valueText,
    this.trackColor,
    this.rangeColor,
  }) : _integerChanged = null,
       _decimalChanged = onChanged,
       _integerText = null,
       _decimalText = valueText,
       _decimal = true;

  final num value, min, max, step;
  final bool disabled;
  final String? semanticLabel;
  final Color? trackColor, rangeColor;
  final bool _decimal;
  final ValueChanged<int>? _integerChanged;
  final ValueChanged<double>? _decimalChanged;
  final String Function(int)? _integerText;
  final String Function(double)? _decimalText;

  ValueChanged<num>? get onChanged {
    if (_decimal) {
      return _decimalChanged == null ? null : (v) => _decimalChanged(v.toDouble());
    }
    return _integerChanged == null ? null : (v) => _integerChanged(v.toInt());
  }

  String Function(num)? get valueText {
    if (_decimal) {
      return _decimalText == null ? null : (v) => _decimalText(v.toDouble());
    }
    return _integerText == null ? null : (v) => _integerText(v.toInt());
  }

  @override
  State<DifySlider> createState() => _DifySliderState();
}

class _DifySliderState extends State<DifySlider> {
  bool _hovered = false, _focused = false;

  num _clamp(num v) {
    final n = v.clamp(widget.min, widget.max);
    // Decimal steps must not report binary floating point tails (0.2 + 0.1).
    return widget._decimal ? double.parse(n.toStringAsFixed(12)) : n.round();
  }

  void _set(num v) {
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
    String text(num v) => w.valueText?.call(_clamp(v)) ?? '$v';
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
                              boxShadow: _focused ? difyFocusRing(true) : (w.disabled ? null : DifyShadows.sm),
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
