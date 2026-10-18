/// Choosers of panels: dify-ui's Select, the node `TypeSelector` (nodes/_base/components/selector.tsx), the output
/// type picker (variable/var-type-picker.tsx) and FormInputTypeSwitch (form-input-type-switch.tsx).
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart';
import 'controls.dart';
import 'var_picker_model.dart';

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
  });

  final T? value;
  final List<SelectOption<T>> options;
  final List<SelectGroup<T>> groups;
  final ValueChanged<T>? onChanged;
  final String? placeholder;
  final bool readonly, disabled, capitalize;
  final double? width, popupWidth;

  /// The trigger's text (`text-[13px]` and the like); `system-sm-regular` by default.
  final TextStyle? textStyle;
  final double paddingX;

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
      focusNode: selected ? _selectedNode : null,
      child: Text(_label(o.label)),
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
          placement: DifyPlacement.bottomStart,
          sideOffset: 4,
          width: w.popupWidth ?? (c.maxWidth.isFinite ? c.maxWidth : null),
          builder: (context, controller) => _SelectTrigger(
            text: selected == null ? w.placeholder ?? '' : _label(selected.label),
            placeholder: selected == null,
            readonly: w.readonly,
            disabled: w.disabled,
            textStyle: w.textStyle,
            paddingX: w.paddingX,
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
  });
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
      button: true,
      enabled: !w.disabled,
      value: w.text,
      onTap: w.onTap,
      child: MouseRegion(
        cursor: w.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: w.onTap,
          child: Container(
            height: 32,
            padding: EdgeInsets.symmetric(horizontal: w.paddingX),
            decoration: BoxDecoration(
              color: w.disabled
                  ? DifyColors.componentsInputBgDisabled
                  : active
                  ? DifyColors.stateBaseHoverAlt
                  : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              spacing: 2,
              children: [
                Expanded(
                  child: Text(w.text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    );
  }
}

/// VarTypePicker: the output type select (`h-8 w-30 rounded-lg px-2.5 text-[13px]`, capitalised) offering string,
/// number, boolean, array[number], array[string], array[boolean], array[object] and object.
class VarTypePicker extends StatelessWidget {
  const VarTypePicker({super.key, required this.value, required this.onChanged, this.readonly = false});
  final String value;
  final ValueChanged<String> onChanged;
  final bool readonly;

  static const types = [
    VarType.string,
    VarType.number,
    VarType.boolean,
    VarType.arrayNumber,
    VarType.arrayString,
    VarType.arrayBoolean,
    VarType.arrayObject,
    VarType.object,
  ];

  @override
  Widget build(BuildContext context) => DifySelect<String>(
    value: value,
    options: [for (final t in types) (value: t, label: t)],
    onChanged: onChanged,
    readonly: readonly,
    width: 120,
    paddingX: 10,
    capitalize: true,
    textStyle: const TextStyle(fontSize: 13, height: 16 / 13),
  );
}

/// TypeSelector (selector.tsx): a small chooser whose list (`w-30 rounded-lg border bg-components-panel-bg p-1
/// shadow-lg`, items `h-7.5 px-3 text-[13px] font-medium text-text-secondary`, a check on the value with
/// [showChecked]) opens below the trigger. Without a [trigger] it shows the value's label (`text-sm font-semibold`)
/// and a vertical chevron in an `h-5` box pulled 8 px left (unless [noLeft]).
class TypeSelector<T> extends StatefulWidget {
  const TypeSelector({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.trigger,
    this.noLeft = false,
    this.placeholder = '',
    this.uppercase = false,
    this.triggerUppercase = false,
    this.readonly = false,
    this.showChecked = false,
    this.sideOffset = 4,
    this.popupWidth = 120,
    this.onTriggerTap,
  });

  final T? value;
  final List<SelectOption<T>> options;
  final ValueChanged<T> onChanged;
  final Widget? trigger;
  final bool noLeft, uppercase, readonly, showChecked;

  /// The trigger's label upper-cased, the list's not (an `uppercase` the trigger inherits, as a code editor's title).
  final bool triggerUppercase;
  final String placeholder;

  /// The gap below the trigger (the list sits at `top-6` of the selector: 4 px under the `h-5` trigger).
  final double sideOffset;
  final double popupWidth;

  /// Called on each trigger tap before the list toggles.
  final VoidCallback? onTriggerTap;

  @override
  State<TypeSelector<T>> createState() => _TypeSelectorState<T>();
}

class _TypeSelectorState<T> extends State<TypeSelector<T>> {
  final _controller = DifyFloatingController();

  @override
  Widget build(BuildContext context) {
    final TypeSelector(:value, :options, :onChanged, :trigger, :noLeft, :uppercase, :readonly, :showChecked) = widget;
    final TypeSelector(:placeholder, :sideOffset, :popupWidth, :onTriggerTap) = widget;
    final item = options.where((o) => o.value == value).firstOrNull;
    final noValue = value == null || value == '';
    Widget selector = DifyFloating(
      controller: _controller,
      placement: DifyPlacement.bottomStart,
      sideOffset: sideOffset,
      collision: DifyCollision.dropdown,
      builder: (context, c) => MouseRegion(
        cursor: readonly ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            onTriggerTap?.call();
            if (!readonly) c.toggle();
          },
          child:
              trigger ??
              _DefaultTrigger(
                label: noValue ? placeholder : item?.label ?? '',
                noValue: noValue,
                uppercase: uppercase || widget.triggerUppercase,
                readonly: readonly,
                open: c.isOpen,
              ),
        ),
      ),
      popupBuilder: (context) => Container(
        width: popupWidth,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.componentsPanelBorder),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final o in options)
              _TypeSelectorItem(
                label: uppercase ? o.label.toUpperCase() : o.label,
                checked: showChecked && o.value == value,
                onTap: () {
                  _controller.close();
                  onChanged(o.value);
                },
              ),
          ],
        ),
      ),
    );
    if (trigger == null && !noLeft) selector = Transform.translate(offset: const Offset(-8, 0), child: selector);
    return selector;
  }
}

class _DefaultTrigger extends StatefulWidget {
  const _DefaultTrigger({
    required this.label,
    required this.noValue,
    required this.uppercase,
    required this.readonly,
    required this.open,
  });
  final String label;
  final bool noValue, uppercase, readonly, open;

  @override
  State<_DefaultTrigger> createState() => _DefaultTriggerState();
}

class _DefaultTriggerState extends State<_DefaultTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 20,
        padding: const EdgeInsets.only(left: 4, right: 2),
        decoration: BoxDecoration(
          color: _hovered || w.open ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              w.uppercase ? w.label.toUpperCase() : w.label,
              style: TextStyle(
                fontSize: 14,
                height: 20 / 14,
                fontWeight: FontWeight.w600,
                color: w.noValue ? DifyColors.textTertiary : DifyColors.textSecondary,
              ),
            ),
            if (!w.readonly)
              const DifyIcon('vender/line/arrows/chevron-selector-vertical', size: 12, color: DifyColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _TypeSelectorItem extends StatefulWidget {
  const _TypeSelectorItem({required this.label, required this.checked, required this.onTap});
  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  State<_TypeSelectorItem> createState() => _TypeSelectorItemState();
}

class _TypeSelectorItemState extends State<_TypeSelectorItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: widget.checked,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 30,
          constraints: const BoxConstraints(minWidth: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _hovered ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 16 / 13,
                    fontWeight: FontWeight.w500,
                    color: DifyColors.textSecondary,
                  ),
                ),
              ),
              if (widget.checked) const DifyIcon('vender/line/general/check', size: 16, color: DifyColors.textPrimary),
            ],
          ),
        ),
      ),
    ),
  );
}

/// FormInputTypeSwitch: an `h-8` segmented control between "Variable" (`variable-02`) and "Input" (`i-ri-edit-line`),
/// unchecked items with their name as a tooltip.
class FormInputTypeSwitch extends StatelessWidget {
  const FormInputTypeSwitch({super.key, required this.value, required this.onChanged, this.readonly = false});
  final VarKindType value;
  final ValueChanged<VarKindType> onChanged;
  final bool readonly;

  @override
  Widget build(BuildContext context) => DifySegmentedControl<VarKindType>(
    value: value,
    onChanged: onChanged,
    disabled: readonly,
    tooltip: true,
    bordered: false,
    itemPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    textColor: DifyColors.textTertiary,
    checkedTextColor: DifyColors.textSecondary,
    segments: [
      (
        value: VarKindType.variable,
        label: DifyI18n.tr('workflow', 'nodes.common.typeSwitch.variable'),
        child: const DifyIcon('vender/solid/development/variable-02', size: 16),
      ),
      (
        value: VarKindType.constant,
        label: DifyI18n.tr('workflow', 'nodes.common.typeSwitch.input'),
        child: const RemixIcon('edit-line', size: 16),
      ),
    ],
  );
}
