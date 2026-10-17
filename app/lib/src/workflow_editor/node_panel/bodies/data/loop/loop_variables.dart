/// The Loop Variables list (nodes/loop/components/loop-variables: index, empty, item, form-item,
/// variable-type-select, input-mode-selec).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../code_editor/code_editor.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../data_common.dart';

/// chat-variable-panel/utils.ts placeholders of the JSON editors.
const objectPlaceholder = '#  example\n#  {\n#     "name": "ray",\n#     "age": 20\n#  }';
const arrayStringPlaceholder = '#  example\n#  [\n#     "value1",\n#     "value2"\n#  ]';
const arrayNumberPlaceholder = '#  example\n#  [\n#     100,\n#     200\n#  ]';
const arrayObjectPlaceholder =
    '#  example\n#  [\n#     {\n#       "name": "ray",\n#       "age": 20\n#     },\n#     {\n#       "name": "lily",\n'
    '#       "age": 18\n#     }\n#  ]';
const arrayBoolPlaceholder = '#  example\n#  [\n#     "True",\n#     "False"\n#  ]';

/// The loop's variables: [LoopVariableItem]s, or the empty tip.
class LoopVariables extends StatelessWidget {
  const LoopVariables({
    super.key,
    required this.variables,
    required this.scope,
    required this.onRemove,
    required this.onUpdate,
  });

  final List<Json> variables;

  /// The variables a variable-mode value may reference.
  final VarScope scope;
  final ValueChanged<String> onRemove;
  final void Function(String id, Json update) onUpdate;

  @override
  Widget build(BuildContext context) {
    if (variables.isEmpty) {
      return Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: DifyColors.backgroundSection, borderRadius: BorderRadius.circular(10)),
        child: DifyText(wf('nodes.loop.setLoopVariables'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, v) in variables.indexed)
          Padding(
            key: ValueKey(v['id']),
            padding: EdgeInsets.only(bottom: i == variables.length - 1 ? 0 : 16),
            child: LoopVariableItem(item: v, scope: scope, onRemove: onRemove, onUpdate: onUpdate),
          ),
      ],
    );
  }
}

/// item.tsx: name, type and input mode in three columns over the value, a remove button on the right. Names are
/// checked as typed (spaces become `_`; an invalid name is refused with a toast) and again on blur.
class LoopVariableItem extends StatefulWidget {
  const LoopVariableItem({
    super.key,
    required this.item,
    required this.onRemove,
    required this.onUpdate,
    this.scope = const VarScope(),
  });

  final Json item;
  final VarScope scope;
  final ValueChanged<String> onRemove;
  final void Function(String id, Json update) onUpdate;

  @override
  State<LoopVariableItem> createState() => _LoopVariableItemState();
}

class _LoopVariableItemState extends State<LoopVariableItem> {
  late final _nameFocus = FocusNode(debugLabel: 'loop variable name')..addListener(_onNameFocus);

  String get _id => '${widget.item['id']}';
  String get _label => jsStr(widget.item['label']) ?? '';

  @override
  void initState() {
    super.initState();
    if (_label.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _nameFocus.requestFocus() : null);
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    super.dispose();
  }

  bool _check(String value) {
    final bad = checkKey(value);
    if (bad == null) return true;
    showDataToast(
      context,
      DataToastType.error,
      DifyI18n.tr('app-debug', 'varKeyError.$bad', {'key': wf('env.modal.name')}),
    );
    return false;
  }

  void _onNameFocus() {
    if (!_nameFocus.hasFocus) _check(_label);
  }

  void _onName(String value) {
    if (value.isNotEmpty && !_check(value)) {
      setState(() {}); // shows the stored name again
      return;
    }
    widget.onUpdate(_id, {'label': value});
  }

  /// `getDefaultValue`.
  static Object? _defaultValue(Object? varType, Object? valueType) {
    if (valueType == 'variable') return null;
    return switch (varType) {
      VarType.boolean => false,
      VarType.arrayBoolean => [false],
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final nameLabel = wf('nodes.loop.variableName');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  spacing: 4,
                  children: [
                    Expanded(
                      child: DifyInput(
                        value: _label,
                        semanticLabel: nameLabel,
                        placeholder: nameLabel,
                        focusNode: _nameFocus,
                        formatters: [
                          TextInputFormatter.withFunction(
                            (_, next) => next.copyWith(text: next.text.replaceAll(' ', '_')),
                          ),
                        ],
                        onChanged: _onName,
                      ),
                    ),
                    Expanded(
                      child: VariableTypeSelect(
                        value: jsStr(item['var_type']),
                        onChange: (v) =>
                            widget.onUpdate(_id, {'var_type': v, 'value': _defaultValue(v, item['value_type'])}),
                      ),
                    ),
                    Expanded(
                      child: InputModeSelect(
                        value: jsStr(item['value_type']),
                        onChange: (v) =>
                            widget.onUpdate(_id, {'value_type': v, 'value': _defaultValue(item['var_type'], v)}),
                      ),
                    ),
                  ],
                ),
              ),
              LoopVariableFormItem(
                item: item,
                scope: widget.scope,
                onChange: (v) => widget.onUpdate(_id, {'value': v}),
              ),
            ],
          ),
        ),
        DifyIconButton(
          label: cm('operation.remove'),
          size: DifyIconButtonSize.lg,
          onPressed: () => widget.onRemove(_id),
          icon: const RemixIcon('delete-bin-line', size: 16, color: DifyColors.textTertiary),
        ),
      ],
    );
  }
}

/// variable-type-select.tsx.
class VariableTypeSelect extends StatelessWidget {
  const VariableTypeSelect({super.key, required this.value, required this.onChange});
  final String? value;
  final ValueChanged<String> onChange;

  static const options = <SelectOption<String>>[
    (value: VarType.string, label: 'String'),
    (value: VarType.number, label: 'Number'),
    (value: VarType.object, label: 'Object'),
    (value: VarType.boolean, label: 'Boolean'),
    (value: VarType.arrayString, label: 'Array[string]'),
    (value: VarType.arrayNumber, label: 'Array[number]'),
    (value: VarType.arrayObject, label: 'Array[object]'),
    (value: VarType.arrayBoolean, label: 'Array[boolean]'),
  ];

  @override
  Widget build(BuildContext context) => DifySelect<String>(value: value, options: options, onChanged: onChange);
}

/// input-mode-selec.tsx: Variable / Constant ("Input Mode" when unset).
class InputModeSelect extends StatelessWidget {
  const InputModeSelect({super.key, required this.value, required this.onChange});
  final String? value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) => DifySelect<String>(
    value: value,
    options: const [(value: 'variable', label: 'Variable'), (value: 'constant', label: 'Constant')],
    placeholder: wf('nodes.loop.inputMode'),
    onChanged: onChange,
  );
}

/// form-item.tsx: the value editor for the variable's mode and type, named after the variable (or "Variable
/// Value" while it has no name).
class LoopVariableFormItem extends StatelessWidget {
  const LoopVariableFormItem({super.key, required this.item, required this.onChange, this.scope = const VarScope()});

  final Json item;
  final VarScope scope;
  final ValueChanged<Object?> onChange;

  @override
  Widget build(BuildContext context) {
    final valueType = item['value_type'], varType = item['var_type'], value = item['value'];
    final label = jsStr(item['label']);
    final valueLabel = label == null || label.isEmpty ? wf('errorMsg.fields.variableValue') : label;
    if (valueType == 'variable') {
      return VarReferencePicker(
        value: [for (final s in jsList(value)) '$s'],
        onChange: (sel, _) => onChange(sel),
        scope: scope,
        filterVar: (v, _) => v.type == varType,
        placeholder: wf('nodes.assigner.setParameter'),
      );
    }
    if (valueType != 'constant') return const SizedBox.shrink();
    switch (varType) {
      case VarType.string:
        return DifyTextarea(value: jsStr(value) ?? '', semanticLabel: valueLabel, minHeight: 48, onChanged: onChange);
      case VarType.number:
        return DifyInput(
          value: value == null ? '' : jsKey(value),
          semanticLabel: valueLabel,
          placeholder: cm('placeholder.input'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.eE+-]'))],
          onChanged: onChange,
        );
      case VarType.boolean:
        return BoolValue(value: value == true, onChange: onChange);
      case VarType.object || VarType.arrayString || VarType.arrayNumber || VarType.arrayObject:
        return Container(
          height: varType == VarType.arrayObject ? 240 : 120,
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(10),
          ),
          child: DifyCodeEditor(
            value: value,
            language: CodeLanguage.json,
            noWrapper: true,
            isExpand: true,
            onChange: onChange,
            placeholder: switch (varType) {
              VarType.arrayString => arrayStringPlaceholder,
              VarType.arrayNumber => arrayNumberPlaceholder,
              VarType.arrayObject => arrayObjectPlaceholder,
              _ => objectPlaceholder,
            },
          ),
        );
      case VarType.arrayBoolean:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ArrayBoolList(
            list: value is List && value.isNotEmpty ? [for (final b in value) b == true] : const [false],
            onChange: onChange,
          ),
        );
    }
    return const SizedBox.shrink();
  }
}
