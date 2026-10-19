/// The small form controls more than one node panel group uses: ListNoDataPlaceholder, BoolValue / ArrayBoolList
/// (chat-variable-panel), InputNumberWithSlider, VariableTag, and the config-var modal's parts (config-modal/field.tsx,
/// type-select.tsx, config-select). The shared controls (checkbox, textarea, tag input, ...) live in design/widgets.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/output_vars.dart' show inputVarTypeToVarType;
import 'field.dart';
import 'var_picker_model.dart' show VarScope;
import 'var_reference_picker.dart' show isExceptionVariable;

// ---- Checkbox ----------------------------------------------------------------------------------------------------

/// ListNoDataPlaceholder (list-no-data-placeholder.tsx): `flex min-h-10.5 w-full items-center justify-center
/// rounded-[10px] bg-background-section system-xs-regular text-text-tertiary`.
class ListNoDataPlaceholder extends StatelessWidget {
  const ListNoDataPlaceholder(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 42),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: DifyColors.backgroundSection, borderRadius: BorderRadius.circular(10)),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
    ),
  );
}

/// BoolValue (panel/chat-variable-panel/components/bool-value.tsx): "True" / "False" option cards side by side.
class BoolValue extends StatelessWidget {
  const BoolValue({super.key, required this.value, required this.onChange, this.disabled = false});
  final bool value;
  final ValueChanged<bool> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 4,
    children: [
      Expanded(
        child: OptionCard(title: 'True', selected: value, disabled: disabled, onSelect: () => onChange(true)),
      ),
      Expanded(
        child: OptionCard(title: 'False', selected: !value, disabled: disabled, onSelect: () => onChange(false)),
      ),
    ],
  );
}

/// ArrayBoolList (chat-variable-panel/components/array-bool-list.tsx): a [BoolValue] and a remove button per item,
/// then "Add value".
class ArrayBoolList extends StatelessWidget {
  const ArrayBoolList({super.key, required this.list, required this.onChange});
  final List<bool> list;
  final ValueChanged<List<bool>> onChange;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      for (final (i, item) in list.indexed)
        Row(
          spacing: 4,
          children: [
            Expanded(
              child: BoolValue(value: item, onChange: (v) => onChange([...list]..[i] = v)),
            ),
            RemoveButton(onPressed: () => onChange([...list]..removeAt(i))),
          ],
        ),
      DifyButton(
        variant: DifyButtonVariant.tertiary,
        onPressed: () => onChange([...list, false]),
        leading: const RemixIcon('add-line', size: 16),
        child: Text(DifyI18n.tr('workflow', 'chatVariable.modal.addArrayValue')),
      ),
    ],
  );
}

/// InputNumberWithSlider (nodes/_base/components/input-number-with-slider.tsx): a `h-8 w-12` number input (`rounded-lg bg-components-input-bg-normal pl-3 text-[13px]`)
/// beside a growing slider, 8 px apart. Typing reports `parseFloat` of the text (NaN when it is none); on blur a
/// NaN goes back to [defaultValue] and a value outside [min]..[max] is clamped.
class InputNumberWithSlider extends StatefulWidget {
  const InputNumberWithSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChange,
    this.defaultValue = 0,
    this.min,
    this.max,
    this.readonly = false,
  });

  final String label;
  final num value;
  final ValueChanged<num> onChange;
  final num defaultValue;
  final int? min, max;
  final bool readonly;

  @override
  State<InputNumberWithSlider> createState() => _InputNumberWithSliderState();
}

class _InputNumberWithSliderState extends State<InputNumberWithSlider> {
  late final _text = TextEditingController(text: _format(widget.value));
  late final _focus = FocusNode()..addListener(_onFocus);

  static String _format(num v) => v.isNaN ? '' : (v == v.roundToDouble() ? '${v.round()}' : '$v');

  @override
  void didUpdateWidget(InputNumberWithSlider old) {
    super.didUpdateWidget(old);
    final parsed = num.tryParse(_text.text);
    if (parsed != widget.value && !(parsed == null && widget.value.isNaN)) _text.text = _format(widget.value);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus) return;
    final w = widget, v = w.value;
    if (v.isNaN) {
      w.onChange(w.defaultValue);
    } else if (w.max != null && v > w.max!) {
      w.onChange(w.max!);
    } else if (w.min != null && v < w.min!) {
      w.onChange(w.min!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final min = w.min ?? 0, max = w.max ?? 100;
    final slider = w.value.isFinite ? w.value.round() : min;
    return SizedBox(
      height: 32,
      child: Row(
        spacing: 8,
        children: [
          Container(
            width: 48,
            height: 32,
            padding: const EdgeInsets.only(left: 12),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Semantics(
              label: w.label,
              textField: true,
              child: TextField(
                controller: _text,
                focusNode: _focus,
                enabled: !w.readonly,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.eE+-]'))],
                style: TextStyle(fontSize: 13, color: DifyColors.componentsInputTextFilled),
                cursorWidth: 1,
                decoration: const InputDecoration(isCollapsed: true, border: InputBorder.none),
                onChanged: (s) => w.onChange(double.tryParse(s.trim()) ?? double.nan),
              ),
            ),
          ),
          Expanded(
            child: DifySlider(
              value: slider.clamp(min, max),
              min: min,
              max: max,
              disabled: w.readonly,
              semanticLabel: w.label,
              onChanged: w.onChange,
            ),
          ),
        ],
      ),
    );
  }
}

/// VariableTag (nodes/_base/components/variable-tag.tsx): [valueSelector] as a variable label (its node from
/// [lookup], the Start node [start] for system variables; the type unless [isShort]; "Invalid variable" when neither
/// a node nor a special variable defines it).
class VariableTag extends StatelessWidget {
  const VariableTag({
    super.key,
    required this.valueSelector,
    required this.varType,
    required this.lookup,
    this.start,
    this.isShort = false,
  });

  /// The tag over [scope]'s nodes.
  VariableTag.inScope({
    Key? key,
    required List<String> valueSelector,
    String? varType,
    required VarScope scope,
    bool isShort = false,
  }) : this(
         key: key,
         valueSelector: valueSelector,
         varType: varType,
         lookup: scope.lookup,
         start: scope.start,
         isShort: isShort,
       );

  final List<String> valueSelector;
  final String? varType;
  final Node? Function(String id) lookup;
  final Node? start;
  final bool isShort;

  @override
  Widget build(BuildContext context) {
    final v = valueSelector;
    final isRag = isRagVariableVar(v);
    final node = isSystemVar(v)
        ? start
        : v.isEmpty
        ? null
        : lookup(isRag && v.length > 1 ? v[1] : v[0]);
    final valid = node != null || isEnvVar(v) || isConversationVar(v) || isRag || isGlobalVar(v);
    final name = (isSystemVar(v) ? v : v.skip(1)).join('.');
    return VariableLabel(
      variables: v,
      nodeType: node?.type,
      nodeTitle: node?.title,
      variableType: isShort ? null : varType,
      errorMsg: valid ? null : DifyI18n.tr('workflow', 'errorMsg.invalidVariable'),
      isExceptionVariable: isExceptionVariable(name, node?.type),
    );
  }
}

// ---- the config-var modal's parts --------------------------------------------------------------------------------

/// config-modal/field.tsx: the title (`system-sm-semibold leading-8 text-text-secondary`, "(optional)"), the control
/// and the error message (`mt-1 system-xs-regular text-text-destructive`).
class ModalField extends StatelessWidget {
  const ModalField({super.key, required this.title, required this.child, this.isOptional = false, this.errorMessage});
  final String title;
  final Widget child;
  final bool isOptional;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 32,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              text: title,
              children: [
                if (isOptional)
                  TextSpan(
                    text: ' (${DifyI18n.tr('app-debug', 'variableConfig.optional')})',
                    style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  ),
              ],
            ),
            style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
          ),
        ),
      ),
      child,
      if (errorMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(errorMessage!, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive)),
        ),
    ],
  );
}

/// The select trigger box: input colours (hover `bg-state-base-hover-alt`), [content], a chevron.
class _SelectBox extends StatelessWidget {
  const _SelectBox({
    required this.content,
    required this.open,
    required this.onTap,
    this.large = true,
    this.label,
    this.focusNode,
  });
  final Widget content;
  final bool open, large;
  final VoidCallback onTap;
  final String? label;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => DifyPressable(
    focusNode: focusNode,
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: large ? 16 : 8),
      decoration: BoxDecoration(
        color: hovered || open || focused ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(large ? 10 : 8),
        boxShadow: difyFocusRing(focused),
      ),
      child: Row(
        spacing: 2,
        children: [
          Expanded(child: content),
          RemixIcon(
            'arrow-down-s-line',
            size: 16,
            color: hovered || open ? DifyColors.textSecondary : DifyColors.textQuaternary,
          ),
        ],
      ),
    ),
  );
}

/// dify-ui's Select with a `large` trigger (`h-9 rounded-[10px] px-4 system-md-regular`).
class ModalSelect<T> extends StatelessWidget {
  const ModalSelect({super.key, required this.value, required this.options, required this.onChanged, this.placeholder});
  final T? value;
  final List<SelectOption<T>> options;
  final ValueChanged<T> onChanged;
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final selected = options.where((o) => o.value == value).firstOrNull;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        width: c.maxWidth,
        builder: (context, controller) => _SelectBox(
          open: controller.isOpen,
          onTap: controller.toggle,
          label: selected?.label ?? placeholder,
          content: Text(
            selected?.label ?? placeholder ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(
              DifyType.systemMdRegular,
              selected == null ? DifyColors.componentsInputTextPlaceholder : DifyColors.componentsInputTextFilled,
            ),
          ),
        ),
        children: [
          DifyMenuRadioGroup<T>(
            value: value,
            onValueChange: onChanged,
            children: [
              for (final o in options) DifyMenuRadioItem<T>(value: o.value, closeOnClick: true, child: Text(o.label)),
            ],
          ),
        ],
      ),
    );
  }
}

/// type-select.tsx: the field type with its icon and VarType badge, in the trigger (`h-9 rounded-lg px-2 text-sm`)
/// and in each option. [semanticLabel] names the trigger (its label's text; the selected type by default);
/// [focusNode] lets the label focus it.
class InputTypeSelect extends StatelessWidget {
  const InputTypeSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onSelect,
    this.semanticLabel,
    this.focusNode,
  });
  final String value;
  final List<({String value, String name})> items;
  final ValueChanged<String> onSelect;
  final String? semanticLabel;
  final FocusNode? focusNode;

  Widget _row(({String value, String name}) item, {bool trigger = false}) => Row(
    children: [
      InputVarTypeIcon(type: item.value, size: 16, color: DifyColors.textSecondary),
      SizedBox(width: trigger ? 6 : 8),
      Expanded(
        child: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: trigger ? TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.componentsInputTextFilled) : null,
        ),
      ),
      const SizedBox(width: 8),
      DifyBadge(inputVarTypeToVarType(item.value), uppercase: false),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final selected = items.where((i) => i.value == value).firstOrNull;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        width: c.maxWidth,
        builder: (context, controller) => _SelectBox(
          large: false,
          focusNode: focusNode,
          open: controller.isOpen,
          onTap: controller.toggle,
          label: semanticLabel ?? selected?.name,
          content: selected == null ? const SizedBox.shrink() : _row(selected, trigger: true),
        ),
        children: [
          DifyMenuRadioGroup<String>(
            value: value,
            onValueChange: onSelect,
            children: [
              for (final i in items) DifyMenuRadioItem<String>(value: i.value, closeOnClick: true, child: _row(i)),
            ],
          ),
        ],
      ),
    );
  }
}

/// config-select: the options editor, rows of a drag handle, an `h-9` input and a delete button, then "Add option".
class ConfigSelect extends StatefulWidget {
  const ConfigSelect({super.key, required this.options, required this.onChange, this.invalid = false});
  final List<String> options;
  final ValueChanged<List<String>> onChange;
  final bool invalid;

  @override
  State<ConfigSelect> createState() => _ConfigSelectState();
}

class _ConfigSelectState extends State<ConfigSelect> {
  int? _focusId, _deletingId;

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final label = DifyI18n.tr('app-debug', 'variableConfig.options');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ReorderableList(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: options.length,
              proxyDecorator: (child, _, _) => Opacity(opacity: 0.5, child: child),
              onReorderItem: (from, to) {
                if (from == to) return;
                final next = [...options]..insert(to, options[from]);
                next.removeAt(from < to ? from : from + 1);
                widget.onChange(next);
              },
              itemBuilder: (context, i) {
                final focused = _focusId == i, deleting = _deletingId == i;
                return Padding(
                  key: ValueKey('option-$i'),
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                  child: Container(
                    padding: const EdgeInsets.only(left: 10),
                    decoration: BoxDecoration(
                      color: deleting
                          ? DifyColors.stateDestructiveHover
                          : focused
                          ? DifyColors.componentsInputBgActive
                          : DifyColors.componentsPanelOnPanelItemBg,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                      border: Border.all(
                        color: deleting
                            ? DifyColors.componentsInputBorderDestructive
                            : focused
                            ? DifyColors.componentsInputBorderActive
                            : DifyColors.componentsPanelBorderSubtle,
                      ),
                    ),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: SizedBox.square(
                              dimension: 24,
                              child: Center(child: RemixIcon('draggable', size: 16, color: DifyColors.textQuaternary)),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Focus(
                            onFocusChange: (f) => setState(() => _focusId = f ? i : null),
                            child: _OptionInput(
                              value: options[i],
                              label: '$label ${i + 1}',
                              onChanged: (v) => widget.onChange([for (final (j, o) in options.indexed) j == i ? v : o]),
                            ),
                          ),
                        ),
                        MouseRegion(
                          onEnter: (_) => setState(() => _deletingId = i),
                          onExit: (_) => setState(() => _deletingId = null),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: DifyIconButton(
                              label: DifyI18n.tr('common', 'operation.delete'),
                              tone: DifyButtonTone.destructive,
                              size: DifyIconButtonSize.md,
                              onPressed: () {
                                widget.onChange([
                                  for (final (j, o) in options.indexed)
                                    if (j != i) o,
                                ]);
                                setState(() => _deletingId = null);
                              },
                              icon: const RemixIcon('delete-bin-line', size: 14),
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
        SizedBox(
          height: 36,
          child: DifyButton(
            variant: DifyButtonVariant.tertiary,
            onPressed: () => widget.onChange([...options, '']),
            leading: const RemixIcon('add-line', size: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                DifyI18n.tr('app-debug', 'variableConfig.addOption'),
                style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary).copyWith(fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// An option's bare input (`h-9 bg-transparent pl-1.5 text-sm/9 text-text-secondary`).
class _OptionInput extends StatefulWidget {
  const _OptionInput({required this.value, required this.label, required this.onChanged});
  final String value, label;
  final ValueChanged<String> onChanged;

  @override
  State<_OptionInput> createState() => _OptionInputState();
}

class _OptionInputState extends State<_OptionInput> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_OptionInput old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: SizedBox(
      height: 36,
      child: Center(
        child: TextField(
          controller: _controller,
          onChanged: widget.onChanged,
          style: TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary),
          cursorColor: const Color(0xFF155EEF),
          cursorWidth: 1,
          decoration: const InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.only(left: 6, right: 8),
          ),
        ),
      ),
    ),
  );
}
