/// dify-ui's Select (packages/dify-ui/src/select).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// One option of a chooser.
typedef SelectOption<T> = ({T value, String label});

/// A titled group of options (dify-ui's Select `Group` + `GroupLabel`).
typedef SelectGroup<T> = ({String label, List<SelectOption<T>> options});

/// dify-ui's Select (Trigger + Content + Item): an input-coloured trigger (`h-8 rounded-lg px-3 system-sm-regular`,
/// hover `bg-state-base-hover-alt`, the chevron hidden when [readonly]) opening its options 4 px below, the selected
/// one checked and highlighted. [groups] follow [options] under their labels. [capitalize] applies CSS `capitalize`
/// to the labels.
class DifySelect<T> extends StatefulWidget {
  const DifySelect({
    super.key,
    required this.value,
    this.options = const [],
    this.groups = const [],
    this.onChanged,
    this.placeholder,
    this.readonly = false,
    this.disabled = false,
    this.width,
    this.popupWidth,
    this.capitalize = false,
    this.textStyle,
    this.paddingX = 12,
    this.semanticLabel,
    this.large = false,
    this.optionLeading,
    this.disabledValues = const {},
    this.placement = DifyPlacement.bottomStart,
    this.sideOffset = 4,
    this.alignOffset = 0,
  });

  final T? value;
  final Set<T> disabledValues;
  final DifyPlacement placement;
  final double sideOffset, alignOffset;
  final List<SelectOption<T>> options;
  final List<SelectGroup<T>> groups;
  final ValueChanged<T>? onChanged;
  final String? placeholder;
  final bool readonly, disabled, capitalize;
  final double? width, popupWidth;

  /// The trigger's text (`text-[13px]` and the like); `system-sm-regular` by default.
  final TextStyle? textStyle;
  final double paddingX;

  /// The trigger's `aria-label`.
  final String? semanticLabel;

  /// `SelectTrigger size="large"`: `h-9 rounded-[10px] px-4 system-md-regular`.
  final bool large;

  /// What an option shows before its label (a call site's icon), if anything.
  final Widget? Function(T value)? optionLeading;

  @override
  State<DifySelect<T>> createState() => _DifySelectState<T>();
}

class _DifySelectState<T> extends State<DifySelect<T>> {
  final _selectedNode = FocusNode(debugLabel: 'DifySelect selected');

  @override
  void dispose() {
    _selectedNode.dispose();
    super.dispose();
  }

  String _label(String s) => widget.capitalize ? cssCapitalize(s) : s;

  Widget _item(SelectOption<T> o) {
    final selected = o.value == widget.value;
    final item = DifyMenuRadioItem<T>(
      value: o.value,
      closeOnClick: true,
      disabled: widget.disabledValues.contains(o.value),
      focusNode: selected ? _selectedNode : null,
      leading: widget.optionLeading?.call(o.value),
      child: DifyTextLine(_label(o.label)),
    );
    return selected ? _FocusOnOpen(node: _selectedNode, child: item) : item;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final all = [...w.options, for (final g in w.groups) ...g.options];
    final selected = all.where((o) => o.value == w.value).firstOrNull;
    return SizedBox(
      width: w.width,
      child: LayoutBuilder(
        builder: (context, c) => DifyDropdownMenu(
          placement: w.placement,
          sideOffset: w.sideOffset,
          alignOffset: w.alignOffset,
          // The popup and trigger both use CSS border-box dimensions. The
          // shared floating layout owns viewport collision constraints.
          width: w.popupWidth ?? (c.maxWidth.isFinite ? c.maxWidth : 240),
          builder: (context, controller) => _SelectTrigger(
            text: selected == null ? w.placeholder ?? '' : _label(selected.label),
            placeholder: selected == null,
            readonly: w.readonly,
            disabled: w.disabled,
            textStyle:
                w.textStyle ?? (w.large ? difyTextStyle(DifyType.systemMdRegular, DifyColors.textPrimary) : null),
            paddingX: w.large ? 16 : w.paddingX,
            height: w.large ? 36 : 32,
            radius: w.large ? 10 : DifyRadius.lg,
            semanticLabel: w.semanticLabel,
            open: controller.isOpen,
            onTap: w.readonly || w.disabled ? null : controller.toggle,
          ),
          children: [
            DifyMenuRadioGroup<T>(
              value: w.value,
              onValueChange: w.onChanged,
              children: [
                for (final o in w.options) _item(o),
                for (final g in w.groups) ...[DifyMenuGroupLabel(g.label), for (final o in g.options) _item(o)],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Focuses [node] (highlights the selected item) once the menu holding [child] is shown.
class _FocusOnOpen extends StatefulWidget {
  const _FocusOnOpen({required this.node, required this.child});
  final FocusNode node;
  final Widget child;

  @override
  State<_FocusOnOpen> createState() => _FocusOnOpenState();
}

class _FocusOnOpenState extends State<_FocusOnOpen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.node.context != null) widget.node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SelectTrigger extends StatefulWidget {
  const _SelectTrigger({
    required this.text,
    required this.placeholder,
    required this.readonly,
    required this.disabled,
    required this.open,
    required this.paddingX,
    this.textStyle,
    this.onTap,
    this.semanticLabel,
    this.height = 32,
    this.radius = DifyRadius.lg,
  });
  final String? semanticLabel;
  final double height, radius;
  final String text;
  final bool placeholder, readonly, disabled, open;
  final double paddingX;
  final TextStyle? textStyle;
  final VoidCallback? onTap;

  @override
  State<_SelectTrigger> createState() => _SelectTriggerState();
}

class _SelectTriggerState extends State<_SelectTrigger> {
  bool _hovered = false;
  final _focus = FocusNode(debugLabel: 'DifySelect trigger');
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final active = !w.readonly && !w.disabled && (_hovered || w.open);
    final color = w.disabled
        ? (w.placeholder ? DifyColors.componentsInputTextDisabled : DifyColors.componentsInputTextFilledDisabled)
        : w.placeholder
        ? DifyColors.componentsInputTextPlaceholder
        : DifyColors.componentsInputTextFilled;
    final style = (w.textStyle ?? difyTextStyle(DifyType.systemSmRegular, color)).copyWith(color: color);
    return Semantics(
      excludeSemantics: true,
      button: true,
      enabled: !w.disabled,
      label: w.semanticLabel ?? w.text,
      value: w.semanticLabel == null ? null : w.text,
      onTap: w.onTap,
      child: Focus(
        focusNode: _focus,
        canRequestFocus: !w.disabled,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.enter ||
                  e.logicalKey == LogicalKeyboardKey.space ||
                  e.logicalKey == LogicalKeyboardKey.arrowDown) &&
              w.onTap != null) {
            w.onTap!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: w.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: w.onTap == null
                ? null
                : () {
                    _focus.requestFocus();
                    w.onTap!();
                  },
            child: Container(
              height: w.height,
              padding: EdgeInsets.symmetric(horizontal: w.paddingX),
              decoration: BoxDecoration(
                color: w.disabled
                    ? DifyColors.componentsInputBgDisabled
                    : active
                    ? DifyColors.stateBaseHoverAlt
                    : DifyColors.componentsInputBgNormal,
                borderRadius: BorderRadius.circular(w.radius),
              ),
              child: Row(
                spacing: 2,
                children: [
                  Expanded(
                    child: DifyControlLabelScope(
                      child: DifyTextLine(w.text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  if (!w.readonly)
                    RemixIcon(
                      'arrow-down-s-line',
                      size: 16,
                      color: active ? DifyColors.textSecondary : DifyColors.textQuaternary,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
