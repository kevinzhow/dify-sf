/// dify-ui's radio group (packages/dify-ui/src/radio-group): [DifyRadioGroup] (Base UI RadioGroup: one value, one tab
/// stop, the arrow keys move and check), [DifyRadioItem] (RadioItem: any content that checks its value),
/// [DifyRadio] (Radio: the 16 px control itself, here with an optional label as a FieldLabel would wrap it),
/// [DifyRadioControl] (RadioControl: the indicator) and [DifyRadioSkeleton].
library;

import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dify_tokens.g.dart';
import 'form_control_shared.dart' show difyFocusRingShadow;
import 'text.dart';

/// An item's state, for [DifyRadioItem.builder].
typedef DifyRadioState = ({bool checked, bool hovered, bool focused, bool disabled});

/// RadioGroup (`flex items-center gap-2`): its [children] hold the [DifyRadioItem]s / [DifyRadio]s (anywhere below).
/// Controlled with [value] (and [onValueChange]); uncontrolled from [defaultValue]. [disabled] disables every item.
/// Named [label] (the Fieldset's legend) for assistive technology. [direction] / [spacing] / [crossAxisAlignment]
/// stand for the className overrides (`flex-col items-stretch gap-1`, …).
class DifyRadioGroup<T> extends StatefulWidget {
  const DifyRadioGroup({
    super.key,
    this.value,
    this.defaultValue,
    this.onValueChange,
    this.disabled = false,
    this.label,
    this.direction = Axis.horizontal,
    this.spacing = 8,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.mainAxisSize = MainAxisSize.min,
    required this.children,
  });

  final T? value, defaultValue;
  final ValueChanged<T>? onValueChange;
  final bool disabled;
  final String? label;
  final Axis direction;
  final double spacing;
  final CrossAxisAlignment crossAxisAlignment;
  final MainAxisSize mainAxisSize;
  final List<Widget> children;

  @override
  State<DifyRadioGroup<T>> createState() => _DifyRadioGroupState<T>();
}

class _DifyRadioGroupState<T> extends State<DifyRadioGroup<T>> {
  late Object? _value = widget.value ?? widget.defaultValue;
  final _items = <_DifyRadioItemState<Object?>>[];

  /// Controlled unless only [DifyRadioGroup.defaultValue] is given.
  bool get _controlled => widget.value != null || widget.defaultValue == null;

  @override
  void didUpdateWidget(DifyRadioGroup<T> old) {
    super.didUpdateWidget(old);
    if (_controlled && widget.value != old.value) _value = widget.value;
  }

  void _select(Object? v) {
    if (_controlled) {
      if (v != _value) widget.onValueChange?.call(v as T);
      return;
    }
    if (v == _value) return;
    setState(() => _value = v);
    widget.onValueChange?.call(v as T);
  }

  List<_DifyRadioItemState<Object?>> get _enabled => [
    for (final i in _items)
      if (!i._disabled) i,
  ];

  /// The checked item when it is enabled, else the first enabled one.
  _DifyRadioItemState<Object?>? get _tabStop {
    final enabled = _enabled;
    for (final i in enabled) {
      if (i.widget.value == _value) return i;
    }
    return enabled.isEmpty ? null : enabled.first;
  }

  void _move(_DifyRadioItemState<Object?> from, int delta) {
    final enabled = _enabled;
    if (enabled.isEmpty) return;
    final at = enabled.indexOf(from);
    final next = enabled[((at < 0 ? 0 : at) + delta) % enabled.length];
    next._focus.requestFocus();
    _select(next.widget.value);
  }

  @override
  Widget build(BuildContext context) => _DifyRadioGroupScope(
    state: this,
    value: _value,
    disabled: widget.disabled,
    child: Semantics(
      container: true,
      explicitChildNodes: true,
      role: SemanticsRole.radioGroup,
      label: widget.label,
      child: Flex(
        direction: widget.direction,
        spacing: widget.spacing,
        mainAxisSize: widget.mainAxisSize,
        crossAxisAlignment: widget.crossAxisAlignment,
        children: widget.children,
      ),
    ),
  );
}

class _DifyRadioGroupScope extends InheritedWidget {
  const _DifyRadioGroupScope({required this.state, required this.value, required this.disabled, required super.child});

  final _DifyRadioGroupState<dynamic> state;
  final Object? value;
  final bool disabled;

  @override
  bool updateShouldNotify(_DifyRadioGroupScope old) => value != old.value || disabled != old.disabled;
}

/// RadioItem: [builder]'s content checks [value] in the enclosing [DifyRadioGroup] (a click, Space or Enter; the
/// arrow keys move to the next or previous item). Outside a group, [checked] and [onSelect] drive it. A
/// [DifyRadioControl] inside shows the item's state.
class DifyRadioItem<T> extends StatefulWidget {
  const DifyRadioItem({
    super.key,
    required this.value,
    required this.builder,
    this.disabled = false,
    this.checked,
    this.onSelect,
    this.semanticLabel,
    this.mouseCursor,
    this.excludeChildSemantics = false,
  });

  final T value;
  final Widget Function(BuildContext context, DifyRadioState state) builder;
  final bool disabled;

  /// Outside a group: whether it is checked, and what a click does.
  final bool? checked;
  final VoidCallback? onSelect;

  /// The item's accessible name (its label).
  final String? semanticLabel;

  /// Defaults to `pointer` (`not-allowed` when disabled).
  final MouseCursor? mouseCursor;

  /// Leaves the content out of the semantics tree (the [semanticLabel] names the item).
  final bool excludeChildSemantics;

  @override
  State<DifyRadioItem<T>> createState() => _DifyRadioItemState<T>();
}

class _DifyRadioItemState<T> extends State<DifyRadioItem<T>> {
  late final FocusNode _focus = FocusNode(debugLabel: 'radio', onKeyEvent: _onKey);
  _DifyRadioGroupState<dynamic>? _group;
  bool _hovered = false, _focused = false;

  _DifyRadioGroupScope? get _scope => context.dependOnInheritedWidgetOfExactType<_DifyRadioGroupScope>();

  bool get _disabled => widget.disabled || (_group?.widget.disabled ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final group = _scope?.state;
    if (group != _group) {
      _group?._items.remove(this);
      _group = group;
      group?._items.add(this as _DifyRadioItemState<Object?>);
    }
  }

  @override
  void dispose() {
    _group?._items.remove(this);
    _focus.dispose();
    super.dispose();
  }

  bool get _checked => _group != null ? _scope!.value == widget.value : (widget.checked ?? false);

  void _select() {
    if (_disabled) return;
    _focus.requestFocus();
    if (_group case final g?) {
      g._select(widget.value);
    } else {
      widget.onSelect?.call();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final g = _group;
    if (g == null || (e is! KeyDownEvent && e is! KeyRepeatEvent)) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final delta = switch (k) {
      LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (delta == 0) return KeyEventResult.ignored;
    g._move(this as _DifyRadioItemState<Object?>, delta);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final checked = _checked;
    final disabled = _disabled;
    final state = (checked: checked, hovered: _hovered && !disabled, focused: _focused, disabled: disabled);
    // One tab stop per group: the checked item, else the first enabled one.
    _focus
      ..canRequestFocus = !disabled
      ..skipTraversal = disabled || (_group != null && _group!._tabStop != this);
    return Semantics(
      container: true,
      checked: checked,
      inMutuallyExclusiveGroup: true,
      enabled: !disabled,
      label: widget.semanticLabel,
      onTap: disabled ? null : _select,
      child: FocusableActionDetector(
        focusNode: _focus,
        enabled: !disabled,
        mouseCursor: widget.mouseCursor ?? (disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _select())},
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: disabled ? null : _select,
          child: _DifyRadioItemScope(
            state: state,
            child: ExcludeSemantics(
              excluding: widget.excludeChildSemantics,
              child: Builder(builder: (c) => widget.builder(c, state)),
            ),
          ),
        ),
      ),
    );
  }
}

class _DifyRadioItemScope extends InheritedWidget {
  const _DifyRadioItemScope({required this.state, required super.child});
  final DifyRadioState state;

  @override
  bool updateShouldNotify(_DifyRadioItemScope old) => state != old.state;
}

/// Radio: the control as its own item (focus ring on the circle), with [label] / [child] after it as the FieldLabel
/// around it reads in Dify (`flex items-center gap-1.5 system-sm-regular text-text-secondary`); a click on the label
/// checks it too.
class DifyRadio<T> extends StatelessWidget {
  const DifyRadio({
    super.key,
    required this.value,
    this.label,
    this.child,
    this.spacing = 6,
    this.disabled = false,
    this.checked,
    this.onSelect,
    this.semanticLabel,
  });

  final T value;
  final String? label;
  final Widget? child;
  final double spacing;
  final bool disabled;
  final bool? checked;
  final VoidCallback? onSelect;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => DifyRadioItem<T>(
    value: value,
    disabled: disabled,
    checked: checked,
    onSelect: onSelect,
    semanticLabel: semanticLabel ?? label,
    excludeChildSemantics: (semanticLabel ?? label) != null,
    builder: (context, s) {
      final control = DifyRadioControl(focused: s.focused);
      final text =
          child ??
          (label == null
              ? null
              : Text(label!, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary)));
      if (text == null) return control;
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: spacing,
        children: [
          control,
          Flexible(child: text),
        ],
      );
    },
  );
}

/// RadioControl / Radio's look: `size-4 rounded-full border border-components-radio-border bg-components-radio-bg
/// shadow-xs shadow-shadow-shadow-3`, hover `border-components-radio-border-hover bg-components-radio-bg-hover`,
/// checked `border-[5px] border-components-radio-border-checked` (hover `…-checked-hover`), disabled
/// `…-border-disabled bg-components-radio-bg-disabled` (checked `…-border-checked-disabled`), `focus-visible:ring-2`.
/// [checked] and [disabled] default to the enclosing [DifyRadioItem]'s; [hovered] to the pointer being over the
/// control itself (CSS `:hover` on the indicator).
class DifyRadioControl extends StatefulWidget {
  const DifyRadioControl({super.key, this.checked, this.disabled, this.hovered, this.focused = false});

  final bool? checked, disabled, hovered;
  final bool focused;

  @override
  State<DifyRadioControl> createState() => _DifyRadioControlState();
}

class _DifyRadioControlState extends State<DifyRadioControl> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = context.dependOnInheritedWidgetOfExactType<_DifyRadioItemScope>()?.state;
    final checked = widget.checked ?? item?.checked ?? false;
    final disabled = widget.disabled ?? item?.disabled ?? false;
    final hovered = !disabled && (widget.hovered ?? _hovered);
    final Color border;
    if (disabled) {
      border = checked ? DifyColors.componentsRadioBorderCheckedDisabled : DifyColors.componentsRadioBorderDisabled;
    } else if (checked) {
      border = hovered ? DifyColors.componentsRadioBorderCheckedHover : DifyColors.componentsRadioBorderChecked;
    } else {
      border = hovered ? DifyColors.componentsRadioBorderHover : DifyColors.componentsRadioBorder;
    }
    final Color bg = disabled
        ? DifyColors.componentsRadioBgDisabled
        : (hovered && !checked ? DifyColors.componentsRadioBgHover : DifyColors.componentsRadioBg);
    final dot = Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(color: border, width: checked ? 5 : 1),
        boxShadow: [
          for (final s in DifyShadows.xs) s.copyWith(color: DifyColors.shadowShadow3),
          if (widget.focused) difyFocusRingShadow(),
        ],
      ),
    );
    if (widget.hovered != null) return dot;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: dot,
    );
  }
}

/// RadioSkeleton: `size-4 shrink-0 rounded-full bg-text-quaternary opacity-20`, no radio semantics.
class DifyRadioSkeleton extends StatelessWidget {
  const DifyRadioSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: 0.2,
    child: Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(shape: BoxShape.circle, color: DifyColors.textQuaternary),
    ),
  );
}
