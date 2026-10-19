/// Choosers of panels (dify-ui's Select lives in design/widgets): the node `TypeSelector` (nodes/_base/components/selector.tsx), the output
/// type picker (variable/var-type-picker.tsx) and FormInputTypeSwitch (form-input-type-switch.tsx).
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart';
import 'var_picker_model.dart';

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
              DifyIcon('vender/line/arrows/chevron-selector-vertical', size: 12, color: DifyColors.textSecondary),
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
                  style: TextStyle(
                    fontSize: 13,
                    height: 16 / 13,
                    fontWeight: FontWeight.w500,
                    color: DifyColors.textSecondary,
                  ),
                ),
              ),
              if (widget.checked) DifyIcon('vender/line/general/check', size: 16, color: DifyColors.textPrimary),
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
