/// dify-ui's SegmentedControl (packages/dify-ui/src/segmented-control).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// One option of a [DifySegmentedControl]: its [value], what it shows and its accessible [label].
typedef DifySegment<T> = ({T value, Widget child, String label});

/// [DifySegmentedControl] sizes.
enum DifySegmentedControlSize {
  /// dify-ui's control: [DifySegmentedControl.height] and the padding parameters.
  regular,

  /// dify-sf's phone control (mockup 2 "Steps | Canvas", gen.py `.seg`): 36 px tall, `p-[3px] gap-0.5`, items
  /// `h-[30px] px-3.5 rounded-lg`, text-tertiary text and text-primary when checked, centred in a 48 px tall box.
  /// The whole box is the items' touch target: the control's padding and the 6 px above and below it
  /// ([DifyTouchTarget] inside the box, so the target never depends on the parent); each item is a 44 px tall node
  /// for accessibility.
  touch,
}

/// A segment's content with a leading icon (`gap-[5px]`), e.g. `DifySegmentLabel(icon: RemixIcon('list-unordered'),
/// text: 'Steps')`. The icon takes the item's text colour.
class DifySegmentLabel extends StatelessWidget {
  const DifySegmentLabel({super.key, required this.icon, required this.text});

  final Widget icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 5,
    children: [icon, DifyTextLine(text)],
  );
}

/// dify-ui's SegmentedControl: `inline-flex gap-px rounded-[10px] bg-components-segmented-control-bg-normal p-0.5`
/// around radio items (`h-7 rounded-lg border-[0.5px] px-2 py-1 system-sm-medium`; checked: the active background,
/// border and accent text with shadow-xs). [itemPadding], [textColor], [checkedTextColor] and [bordered] take
/// call-site overrides (FormInputTypeSwitch: `border-0 px-2.5 py-1.5`, tertiary / secondary text). [tooltip] wraps
/// unchecked items. [size] [DifySegmentedControlSize.touch] is the phone control; it ignores [height], [itemPadding],
/// [padding], [radius] and [itemRadius].
class DifySegmentedControl<T> extends StatefulWidget {
  const DifySegmentedControl({
    super.key,
    required this.value,
    required this.segments,
    this.onChanged,
    this.disabled = false,
    this.disabledValues = const {},
    this.semanticLabel,
    this.height = 32,
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this._textColor,
    this._checkedTextColor,
    this.bordered = true,
    this.tooltip = false,
    this.padding = 2,
    this.radius = 10,
    this.itemRadius = DifyRadius.lg,
    this.size = DifySegmentedControlSize.regular,
  });

  final T value;
  final List<DifySegment<T>> segments;
  final ValueChanged<T>? onChanged;
  final bool disabled;
  final Set<T> disabledValues;
  final String? semanticLabel;
  final double height;
  final EdgeInsets itemPadding;
  final Color? _textColor, _checkedTextColor;
  bool get _touch => size == DifySegmentedControlSize.touch;
  Color get textColor => _textColor ?? (_touch ? DifyColors.textTertiary : DifyColors.textSecondary);
  Color get checkedTextColor =>
      _checkedTextColor ?? (_touch ? DifyColors.textPrimary : DifyColors.textAccentLightModeOnly);
  final bool bordered, tooltip;
  final DifySegmentedControlSize size;

  /// A call site's `p-*` and `rounded-*` over the control's `p-0.5 rounded-[10px]` and the items' `rounded-lg`.
  final double padding, radius, itemRadius;

  @override
  State<DifySegmentedControl<T>> createState() => _DifySegmentedControlState<T>();
}

class _DifySegmentedControlState<T> extends State<DifySegmentedControl<T>> {
  final _nodes = <T, FocusNode>{};
  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _choose(T value) {
    if (!widget.disabled && !widget.disabledValues.contains(value) && value != widget.value) {
      widget.onChanged?.call(value);
    }
  }

  KeyEventResult _key(T value, KeyEvent event) {
    if (event is! KeyDownEvent || widget.disabled) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final next = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown;
    final prev = key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp;
    if (!next && !prev) return KeyEventResult.ignored;
    final enabled = widget.segments.where((s) => !widget.disabledValues.contains(s.value)).toList();
    if (enabled.isEmpty) return KeyEventResult.handled;
    final index = enabled.indexWhere((s) => s.value == value);
    final target = enabled[(index + (next ? 1 : -1)) % enabled.length].value;
    _nodes[target]?.requestFocus();
    _choose(target);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final value = w.value, segments = w.segments, disabled = w.disabled;
    final touch = w._touch;
    // The touch size moves the control's padding into the items, so every point of it belongs to an item.
    final height = touch ? 36.0 : w.height, padding = touch ? 0.0 : w.padding;
    final radius = touch ? 10.0 : w.radius, itemRadius = touch ? DifyRadius.lg : w.itemRadius;
    final itemPadding = touch ? const EdgeInsets.symmetric(horizontal: 14) : w.itemPadding;
    final textColor = w.textColor, checkedTextColor = w.checkedTextColor;
    final bordered = w.bordered, tooltip = w.tooltip;
    final control = Semantics(
      container: true,
      role: SemanticsRole.radioGroup,
      label: w.semanticLabel,
      child: Container(
        height: height,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: DifyColors.componentsSegmentedControlBgNormal,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: touch ? 0 : 1,
          children: [
            for (final (i, s) in segments.indexed)
              () {
                final checked = s.value == value;
                final unavailable = disabled || w.disabledValues.contains(s.value);
                final node = _nodes.putIfAbsent(s.value, () => FocusNode(debugLabel: 'segment ${s.label}'));
                Widget item = Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (_, e) => _key(s.value, e),
                  child: Semantics(
                    container: true,
                    checked: checked,
                    inMutuallyExclusiveGroup: true,
                    enabled: !unavailable,
                    label: s.label,
                    onTap: unavailable ? null : () => _choose(s.value),
                    child: DifyControl(
                      disabled: unavailable,
                      focusNode: node,
                      onActivate: () => _choose(s.value),
                      builder: (context, hovered, focused) {
                        final color = unavailable && !checked
                            ? DifyColors.textDisabled
                            : checked
                            ? checkedTextColor
                            : textColor;
                        final pill = Container(
                          height: touch ? 30 : null,
                          alignment: touch ? Alignment.center : null,
                          padding: itemPadding,
                          decoration: DifyFocusDecoration(
                            color: checked
                                ? DifyColors.componentsSegmentedControlItemActiveBg
                                : hovered && !unavailable
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
                            boxShadow: difyFocusRing(focused) ?? (checked ? DifyShadows.xs : null),
                          ),
                          child: IconTheme.merge(
                            data: IconThemeData(color: color),
                            child: DefaultTextStyle.merge(
                              style: difyTextStyle(DifyType.systemSmMedium, color),
                              child: ExcludeSemantics(
                                child: DifyControlLabelScope(
                                  child: _Tint(color: color, child: s.child),
                                ),
                              ),
                            ),
                          ),
                        );
                        if (!touch) return pill;
                        return Padding(
                          padding: EdgeInsets.fromLTRB(i == 0 ? 3 : 1, 3, i == segments.length - 1 ? 3 : 1, 3),
                          child: pill,
                        );
                      },
                    ),
                  ),
                );
                if (tooltip && !checked) item = DifyTooltip(content: DifyTextLine(s.label), child: item);
                // The touch size: each item's accessible bounds are a 44 px target (inside the 48 px box, where the
                // control's own target already sends taps to the nearest item), not the 36 px item.
                if (touch) item = DifyTouchTarget(minSize: DifyTouch.controlHeight, accessible: true, child: item);
                return item;
              }(),
          ],
        ),
      ),
    );
    if (!touch) return control;
    return SizedBox(
      height: DifyTouch.minTarget,
      child: Center(widthFactor: 1, child: DifyTouchTarget(child: control)),
    );
  }
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
