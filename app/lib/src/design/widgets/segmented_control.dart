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

/// dify-ui's SegmentedControl: `inline-flex gap-px rounded-[10px] bg-components-segmented-control-bg-normal p-0.5`
/// around radio items (`h-7 rounded-lg border-[0.5px] px-2 py-1 system-sm-medium`; checked: the active background,
/// border and accent text with shadow-xs). [itemPadding], [textColor], [checkedTextColor] and [bordered] take
/// call-site overrides (FormInputTypeSwitch: `border-0 px-2.5 py-1.5`, tertiary / secondary text). [tooltip] wraps
/// unchecked items.
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
  Color get textColor => _textColor ?? DifyColors.textSecondary;
  Color get checkedTextColor => _checkedTextColor ?? DifyColors.textAccentLightModeOnly;
  final bool bordered, tooltip;

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
    final height = w.height, padding = w.padding, radius = w.radius, itemRadius = w.itemRadius;
    final itemPadding = w.itemPadding, textColor = w.textColor, checkedTextColor = w.checkedTextColor;
    final bordered = w.bordered, tooltip = w.tooltip;
    return Semantics(
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
          spacing: 1,
          children: [
            for (final s in segments)
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
                        return Container(
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
                      },
                    ),
                  ),
                );
                if (tooltip && !checked) item = DifyTooltip(content: DifyTextLine(s.label), child: item);
                return item;
              }(),
          ],
        ),
      ),
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
