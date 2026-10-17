/// The plugin parameter forms of the trigger and data source panels: TriggerForm / TriggerFormItem
/// (nodes/trigger-plugin/components/trigger-form), ToolForm / ToolFormItem (nodes/tool/components/tool-form) and a
/// lean FormInputItem (nodes/_base/components/form-input-item.tsx + .helpers.ts) over Dify's `ResourceVarInputs`
/// (`{<variable>: {type, value}}`).
///
/// Not ported (they need backend services): app and model selectors, the date pickers (a text field stands in) and
/// fetched dynamic options (the host's options, else the schema's, are shown).
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/model_catalog.dart' show languageOfLocale;
import '../../../../../workflow/var_types.dart';
import '../../../../code_editor/code_editor.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import 'trigger_plugin_default.dart';

/// `useLanguage`: the UI locale as plugin labels key it (`en_US`).
String uiLanguage() {
  final t = DifyI18n.current;
  return languageOfLocale(t is DifyI18n ? t.language : DifyI18n.fallbackLanguage);
}

/// `getFormInputState` (form-input-item.helpers.ts) of a schema and its current value.
class FormInputState {
  FormInputState(Json schema, Object? varInput)
    : type = jsStr(schema['type']) ?? '',
      rawType = jsStr(schema['_type']) ?? '',
      variable = '${schema['variable']}',
      multiple = schema['multiple'] == true,
      options = [
        for (final o in jsList(schema['options']))
          if (o is Map) o.cast<String, Object?>(),
      ],
      defaultValue = schema['default'],
      varType = jsGet(varInput, 'type');

  final String type, rawType, variable;
  final bool multiple;
  final List<Json> options;
  final Object? defaultValue, varType;

  bool get isDateRange => type == 'date-range';
  bool get isDate => type == 'date';
  bool get isString => type == 'text-input' || type == 'secret-input';
  bool get isNumber => type == 'number-input';
  bool get isObject => type == 'object';
  bool get isArray => type == 'array';
  bool get isShowJSONEditor => isObject || isArray;
  bool get isFile => type == 'file' || type == 'files';
  bool get isFiles => type == 'files';
  bool get isBoolean => rawType == 'boolean';
  bool get isCheckbox => rawType == 'checkbox';
  bool get isSelect => type == 'select';
  bool get isDynamicSelect => type == 'dynamic-select';
  bool get showTypeSwitch => isNumber || isBoolean || isObject || isArray || isSelect || isDate;
  bool get isConstant => varType == 'constant' || !jsTruthy(varType);
  bool get showVariableSelector => isFile || varType == 'variable';
  bool get isMultipleSelect => multiple && (isSelect || isDynamicSelect);

  /// `getVarKindType`: the kind a value typed in this field gets.
  String? get varKindType {
    if (isFile) return 'variable';
    if (isSelect || isDynamicSelect || isBoolean || isNumber || isArray || isObject || isDate || isDateRange) {
      return 'constant';
    }
    if (isString) return 'mixed';
    return null;
  }

  /// `getTargetVarType`.
  String get targetVarType {
    if (isString) return VarType.string;
    if (isNumber) return VarType.number;
    if (isFile) return isFiles ? VarType.arrayFile : VarType.file;
    if (isSelect && isMultipleSelect) return VarType.arrayString;
    if (isSelect) return VarType.string;
    if (isBoolean) return VarType.boolean;
    if (isObject) return VarType.object;
    if (isArray) return VarType.arrayObject;
    return VarType.string;
  }

  /// `getFilterVar`.
  VarFilter? get filterVar {
    bool of(PickerVar v, Set<String> types) => types.contains(v.type);
    if (isNumber) return (v, _) => v.type == VarType.number;
    if (isSelect && isMultipleSelect) return (v, _) => of(v, {VarType.array, VarType.arrayString});
    if (isString || isDate) return (v, _) => of(v, {VarType.string, VarType.number, VarType.secret});
    if (isFile) return (v, _) => of(v, {VarType.file, VarType.arrayFile});
    if (isBoolean) return (v, _) => v.type == VarType.boolean;
    if (isObject) return (v, _) => v.type == VarType.object;
    if (isArray) {
      return (v, _) => of(v, {VarType.array, VarType.arrayString, VarType.arrayNumber, VarType.arrayObject});
    }
    return null;
  }
}

/// `filterVisibleOptions`: options whose `show_on` conditions all hold for [values].
List<Json> filterVisibleOptions(List<Json> options, Json values) => [
  for (final o in options)
    if (jsList(o['show_on']).isEmpty ||
        jsList(o['show_on']).every((c) {
          final v = values['${jsGet(c, 'variable')}'];
          return jsGet(v, 'value') == jsGet(c, 'value') || v == jsGet(c, 'value');
        }))
      o,
];

/// One field of a plugin form: its label row (label, `*`, tooltip as an Infotip or a description line, a
/// "JSON Schema" button for object / array fields) above the [FormInputItem].
class PluginFormItem extends StatelessWidget {
  const PluginFormItem({
    super.key,
    required this.schema,
    required this.value,
    required this.onChange,
    this.readOnly = false,
    this.disableVariableInsertion = false,
    this.scope = const VarScope(),
    this.showManageInputField = false,
    this.onManageInputField,
    this.dynamicOptions,
    this.onShowSchema,
    this.wrapLabel = false,
  });

  final Json schema;
  final Json value;
  final ValueChanged<Json> onChange;
  final bool readOnly, disableVariableInsertion;
  final VarScope scope;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;
  final List<Json>? dynamicOptions;

  /// The "JSON Schema" button (Dify's SchemaModal over `input_schema`).
  final void Function(String name, Object? inputSchema)? onShowSchema;

  /// ToolFormItem's `min-h-6 wrap-break-word` label (TriggerFormItem's is one 24 px line).
  final bool wrapLabel;

  @override
  Widget build(BuildContext context) {
    final lang = uiLanguage();
    final type = jsStr(schema['type']) ?? '';
    final showSchemaButton = type == 'object' || type == 'array';
    final showDescription = const {'text-input', 'number-input', 'secret-input', 'date', 'date-range'}.contains(type);
    final tooltip = schema['tooltip'] == null ? '' : labelOf(schema['tooltip'], lang);
    final label = labelOf(schema['label'], lang);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 2,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 24),
                child: Row(
                  children: [
                    Flexible(
                      child: DifyText(
                        label,
                        DifyType.systemSmMedium,
                        color: DifyColors.textSecondary,
                        maxLines: wrapLabel ? null : 1,
                      ),
                    ),
                    if (schema['required'] == true)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: DifyText('*', DifyType.systemXsRegular, color: DifyColors.textDestructiveSecondary),
                      ),
                    if (!showDescription && tooltip.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Infotip(label: tooltip, width: 200, content: Text(tooltip)),
                      ),
                    if (showSchemaButton) ...[
                      const Padding(
                        padding: EdgeInsets.only(left: 4, right: 2),
                        child: DifyText('·', DifyType.systemXsRegular, color: DifyColors.textQuaternary),
                      ),
                      DifyButton(
                        variant: DifyButtonVariant.ghost,
                        size: DifyButtonSize.small,
                        onPressed: () => onShowSchema?.call('${schema['name']}', schema['input_schema']),
                        leading: const RemixIcon('braces-line', size: 14, color: DifyColors.textTertiary),
                        child: const DifyText('JSON Schema', DifyType.systemXsRegular, color: DifyColors.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (showDescription && tooltip.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: DifyText(tooltip, DifyType.bodyXsRegular, color: DifyColors.textTertiary, maxLines: null),
                ),
            ],
          ),
          FormInputItem(
            schema: schema,
            value: value,
            onChange: onChange,
            readOnly: readOnly,
            disableVariableInsertion: disableVariableInsertion,
            scope: scope,
            showManageInputField: showManageInputField,
            onManageInputField: onManageInputField,
            dynamicOptions: dynamicOptions,
          ),
        ],
      ),
    );
  }
}

/// TriggerForm / ToolForm: the fields `space-y-1`.
class PluginForm extends StatelessWidget {
  const PluginForm({
    super.key,
    required this.schema,
    required this.value,
    required this.onChange,
    this.readOnly = false,
    this.disableVariableInsertion = false,
    this.scope = const VarScope(),
    this.showManageInputField = false,
    this.onManageInputField,
    this.dynamicOptionsOf,
    this.onShowSchema,
    this.wrapLabel = false,
  });

  final List<Json> schema;
  final Json value;
  final ValueChanged<Json> onChange;
  final bool readOnly, disableVariableInsertion, showManageInputField, wrapLabel;
  final VarScope scope;
  final VoidCallback? onManageInputField;
  final List<Json>? Function(String variable)? dynamicOptionsOf;
  final void Function(String name, Object? inputSchema)? onShowSchema;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      for (final s in schema)
        PluginFormItem(
          schema: s,
          value: value,
          onChange: onChange,
          readOnly: readOnly,
          disableVariableInsertion: disableVariableInsertion,
          scope: scope,
          showManageInputField: showManageInputField,
          onManageInputField: onManageInputField,
          dynamicOptions: dynamicOptionsOf?.call('${s['variable']}'),
          onShowSchema: onShowSchema,
          wrapLabel: wrapLabel,
        ),
    ],
  );
}

/// FormInputItem: the type switch (Variable / Input) for numbers, booleans, objects, arrays, selects and dates,
/// then the control for the field's type, or the variable picker.
class FormInputItem extends StatelessWidget {
  const FormInputItem({
    super.key,
    required this.schema,
    required this.value,
    required this.onChange,
    this.readOnly = false,
    this.disableVariableInsertion = false,
    this.scope = const VarScope(),
    this.showManageInputField = false,
    this.onManageInputField,
    this.dynamicOptions,
  });

  final Json schema;
  final Json value;
  final ValueChanged<Json> onChange;
  final bool readOnly, disableVariableInsertion, showManageInputField;
  final VarScope scope;
  final VoidCallback? onManageInputField;
  final List<Json>? dynamicOptions;

  @override
  Widget build(BuildContext context) {
    final lang = uiLanguage();
    final s = FormInputState(schema, value['${schema['variable']}']);
    final variable = s.variable;
    final varInput = value[variable] is Map ? (value[variable]! as Map).cast<String, Object?>() : <String, Object?>{};
    final current = varInput['value'];
    final placeholder = schema['placeholder'] == null ? null : labelOf(schema['placeholder'], lang);

    void set(String type, Object? v) => onChange({
      ...value,
      variable: {...varInput, 'type': type, 'value': v},
    });
    void valueChange(Object? v) =>
        set(s.varKindType ?? jsStr(varInput['type']) ?? 'constant', s.isNumber ? parseFloatJs(v) : v);

    String optionLabel(Json o) => o['label'] is String
        ? o['label']! as String
        : (labelOf(o['label'], lang).isEmpty ? '${o['value']}' : labelOf(o['label'], lang));
    final visible = filterVisibleOptions(s.isDynamicSelect ? (dynamicOptions ?? s.options) : s.options, value);
    final items = [for (final o in visible) (value: '${o['value']}', label: optionLabel(o))];

    final controls = <Widget>[];
    if (s.isString) {
      controls.add(
        MixedVariableTextInput(
          value: jsStr(current) ?? '',
          readOnly: readOnly,
          onChange: valueChange,
          variables: scope.vars,
          disableVariableInsertion: disableVariableInsertion,
          showManageInputField: showManageInputField,
          onManageInputField: onManageInputField,
        ),
      );
    }
    if (s.isNumber && s.isConstant) {
      controls.add(
        DifyInput(
          value: current is num ? DifyNumberFieldText.format(current) : (jsStr(current) ?? ''),
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          placeholder: placeholder,
          readOnly: readOnly,
          onChanged: valueChange,
        ),
      );
    }
    if ((s.isDate && s.isConstant) || (s.isDateRange && s.varType != 'variable')) {
      controls.add(
        DifyInput(value: jsStr(current) ?? '', placeholder: placeholder, readOnly: readOnly, onChanged: valueChange),
      );
    }
    if (s.isCheckbox && s.isConstant) {
      final allowed = {for (final o in visible) '${o['value']}'};
      final List<String> checked = switch (current) {
        final List l => [for (final i in l) '$i'],
        final String v => [v],
        _ => s.defaultValue is List ? [for (final i in s.defaultValue! as List) '$i'] : <String>[],
      }.where(allowed.contains).toList();
      controls.add(
        _CheckboxList(
          items: items,
          value: checked,
          disabled: readOnly,
          onChange: (v) => set('constant', v),
        ),
      );
    }
    if (s.isBoolean && s.isConstant) {
      controls.add(
        Row(
          spacing: 4,
          children: [
            for (final b in [true, false])
              Expanded(
                child: OptionCard(
                  title: b ? 'True' : 'False',
                  selected: b ? current == true : current != true,
                  onSelect: () => valueChange(b),
                ),
              ),
          ],
        ),
      );
    }
    if ((s.isSelect && s.isConstant) || s.isDynamicSelect) {
      if (s.isMultipleSelect) {
        controls.add(
          _MultiSelect(
            items: items,
            value: [for (final v in jsList(current)) '$v'],
            placeholder: placeholder,
            disabled: readOnly,
            onChange: valueChange,
          ),
        );
      } else {
        controls.add(
          DifySelect<String>(
            value: items.any((i) => i.value == current) ? current as String : null,
            options: items,
            placeholder: placeholder,
            disabled: readOnly,
            onChanged: valueChange,
          ),
        );
      }
    }
    if (s.isShowJSONEditor && s.isConstant) {
      controls.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: DifyCodeEditor(
            title: 'JSON',
            value: jsStr(current) ?? '',
            language: CodeLanguage.json,
            isInNode: true,
            isExpand: true,
            readOnly: readOnly,
            placeholder: placeholder,
            onChange: valueChange,
          ),
        ),
      );
    }
    if (s.showVariableSelector) {
      controls.add(
        VarReferencePicker(
          value: [for (final v in jsList(current)) '$v'],
          scope: scope,
          readonly: readOnly,
          filterVar: s.filterVar,
          valueTypePlaceHolder: s.targetVarType,
          isFilterFileVar: s.isBoolean,
          onChange: (selector, _) => set('variable', selector),
        ),
      );
    }

    final typeSwitch = s.showTypeSwitch
        ? FormInputTypeSwitch(
            value: varInput['type'] == 'variable' ? VarKindType.variable : VarKindType.constant,
            readonly: readOnly,
            onChanged: (k) => k == VarKindType.variable ? set('variable', '') : set('constant', s.defaultValue),
          )
        : null;
    if (s.isShowJSONEditor && s.isConstant) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [?typeSwitch, ...controls]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        ?typeSwitch,
        for (final c in controls) Expanded(child: c),
      ],
    );
  }
}

/// `DifyNumberField`'s number text (integers without `.0`).
abstract final class DifyNumberFieldText {
  static String format(num v) => v == v.roundToDouble() && v.abs() < 9e15 ? '${v.round()}' : '$v';
}

/// MixedVariableTextInput (nodes/tool/components/mixed-variable-text-input): the prompt editor in an input box
/// (`min-h-8 rounded-lg bg-components-input-bg-normal px-2 py-1`), `/` and `{` inserting variables unless
/// [disableVariableInsertion]; the placeholder says "Type or press / to insert variable" with a String badge.
class MixedVariableTextInput extends StatefulWidget {
  const MixedVariableTextInput({
    super.key,
    required this.value,
    this.onChange,
    this.readOnly = false,
    this.variables = const [],
    this.disableVariableInsertion = false,
    this.showManageInputField = false,
    this.onManageInputField,
  });

  final String value;
  final ValueChanged<String>? onChange;
  final bool readOnly, disableVariableInsertion, showManageInputField;
  final List<VarGroup> variables;
  final VoidCallback? onManageInputField;

  @override
  State<MixedVariableTextInput> createState() => _MixedVariableTextInputState();
}

class _MixedVariableTextInputState extends State<MixedVariableTextInput> {
  final _focus = FocusNode(debugLabel: 'MixedVariableTextInput');
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final focused = _focus.hasFocus;
    final placeholderStyle = difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder);
    final placeholder = Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(child: Text(DifyI18n.tr('workflow', 'nodes.tool.insertPlaceholder1'), style: placeholderStyle)),
              if (!w.disableVariableInsertion) ...[
                const Padding(padding: EdgeInsets.symmetric(horizontal: 2), child: DifyKbd('/')),
                Flexible(
                  child: Text(
                    DifyI18n.tr('workflow', 'nodes.tool.insertPlaceholder2'),
                    style: placeholderStyle.copyWith(
                      decoration: TextDecoration.underline,
                      decorationStyle: TextDecorationStyle.dotted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const DifyBadge('String', uppercase: false),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: focused
              ? DifyColors.componentsInputBgActive
              : _hovered
              ? DifyColors.componentsInputBgHover
              : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: focused
                ? DifyColors.componentsInputBorderActive
                : _hovered
                ? DifyColors.componentsInputBorderHover
                : const Color(0x00000000),
          ),
          boxShadow: focused ? DifyShadows.xs : null,
        ),
        child: DifyPromptEditor(
          value: w.value,
          onChange: w.onChange,
          focusNode: _focus,
          compact: true,
          editable: !w.readOnly,
          placeholder: placeholder,
          disableSlashPicker: w.disableVariableInsertion,
          disableBracePicker: w.disableVariableInsertion,
          workflowVariableBlock: WorkflowVariableBlockConfig(
            show: !w.disableVariableInsertion,
            variables: w.variables,
            showManageInputField: w.showManageInputField,
            onManageInputField: w.onManageInputField,
          ),
        ),
      ),
    );
  }
}

/// CheckboxList (base/checkbox-list): one checkbox row per option.
class _CheckboxList extends StatelessWidget {
  const _CheckboxList({required this.items, required this.value, required this.onChange, this.disabled = false});
  final List<SelectOption<String>> items;
  final List<String> value;
  final ValueChanged<List<String>> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 200),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final i in items)
            DifyPressable(
              disabled: disabled,
              semanticLabel: i.label,
              onPressed: () => onChange(
                value.contains(i.value) ? [...value.where((v) => v != i.value)] : [...value, i.value],
              ),
              builder: (context, hovered, focused) => Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: hovered ? DifyColors.stateBaseHover : null,
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                ),
                child: Row(
                  spacing: 8,
                  children: [
                    _Checkbox(checked: value.contains(i.value), disabled: disabled),
                    Expanded(child: DifyText(i.label, DifyType.systemSmRegular, color: DifyColors.textSecondary)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// dify-ui's Checkbox: 16 px, `rounded-sm`, the accent fill with a check when checked.
class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.checked, this.disabled = false});
  final bool checked, disabled;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: disabled ? 0.5 : 1,
    child: Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? DifyColors.componentsCheckboxBg : DifyColors.componentsCheckboxBgUnchecked,
        borderRadius: BorderRadius.circular(DifyRadius.sm),
        border: checked ? null : Border.all(color: DifyColors.componentsCheckboxBorder),
      ),
      child: checked
          ? const Center(child: RemixIcon('check-line', size: 12, color: DifyColors.componentsCheckboxIcon))
          : null,
    ),
  );
}

/// MultiSelectField (form-input-item.sections.tsx): a select trigger with the chosen labels ("N selected" past two)
/// and a checkable list.
class _MultiSelect extends StatelessWidget {
  const _MultiSelect({
    required this.items,
    required this.value,
    required this.onChange,
    this.placeholder,
    this.disabled = false,
  });
  final List<SelectOption<String>> items;
  final List<String> value;
  final ValueChanged<List<String>> onChange;
  final String? placeholder;
  final bool disabled;

  /// `getSelectedLabels`.
  String get _selectedLabel {
    final selected = items.where((i) => value.contains(i.value)).toList();
    if (value.isEmpty || selected.isEmpty) return '';
    return selected.length <= 2 ? selected.map((i) => i.label).join(', ') : '${selected.length} selected';
  }

  @override
  Widget build(BuildContext context) {
    final label = _selectedLabel;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        width: c.maxWidth.isFinite ? c.maxWidth : null,
        builder: (context, controller) => DifyPressable(
          disabled: disabled,
          semanticLabel: placeholder ?? (label.isEmpty ? 'Options' : label),
          onPressed: controller.toggle,
          builder: (context, hovered, focused) => Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: hovered && !disabled ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              children: [
                Expanded(
                  child: DifyText(
                    label.isNotEmpty ? label : placeholder ?? 'Select options',
                    DifyType.systemSmRegular,
                    color: value.isNotEmpty
                        ? DifyColors.componentsInputTextFilled
                        : DifyColors.componentsInputTextPlaceholder,
                  ),
                ),
                const RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
              ],
            ),
          ),
        ),
        children: [
          for (final i in items)
            DifyMenuCheckboxItem(
              checked: value.contains(i.value),
              onCheckedChange: (on) => onChange(on ? [...value, i.value] : [...value.where((v) => v != i.value)]),
              child: Text(i.label),
            ),
        ],
      ),
    );
  }
}
