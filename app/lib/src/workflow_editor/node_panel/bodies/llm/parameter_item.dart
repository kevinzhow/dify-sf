/// One model parameter of the "Model Settings" popover (model-parameter-modal/parameter-item.tsx), the presets
/// dropdown (presets-parameter.tsx, presets-parameter-utils.ts) and the stop-sequence tag input (base/tag-input).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart' show jsTruthy;
import '../../../../workflow/model_catalog.dart' show renderI18nObject;
import '../../../panel_fields/var_picker_model.dart' show VarGroup;
import '../../../prompt_editor/prompt_editor.dart';
import 'group_host.dart';
import 'model_parameter_modal.dart' show ModelParameterRule;

String _c(String key) => DifyI18n.tr('common', key);

// ---- presets -----------------------------------------------------------------------------------------------------

/// `TONE_LIST` (config/index.ts) without Custom: id, name, config.
const toneList = [
  (
    id: 1,
    name: 'Creative',
    config: {'temperature': 0.8, 'top_p': 0.9, 'presence_penalty': 0.1, 'frequency_penalty': 0.1},
  ),
  (
    id: 2,
    name: 'Balanced',
    config: {'temperature': 0.5, 'top_p': 0.85, 'presence_penalty': 0.2, 'frequency_penalty': 0.3},
  ),
  (
    id: 3,
    name: 'Precise',
    config: {'temperature': 0.2, 'top_p': 0.75, 'presence_penalty': 0.5, 'frequency_penalty': 0.5},
  ),
];

/// `PROVIDER_WITH_PRESET_TONE`.
const providerWithPresetTone = ['langgenius/openai/openai', 'langgenius/azure_openai/azure_openai'];

/// `getSupportedPresetConfig`: tone [toneId]'s values for the parameters the model has (all without a list).
Map<String, num> getSupportedPresetConfig(int toneId, [List<String>? supportedParameterNames]) {
  final tone = toneList.where((t) => t.id == toneId).firstOrNull;
  if (tone == null) return const {};
  if (supportedParameterNames == null) return {...tone.config};
  return {
    for (final e in tone.config.entries)
      if (supportedParameterNames.contains(e.key)) e.key: e.value,
  };
}

/// PresetsParameter: the "Load Presets" small secondary dropdown of the tones that set a supported parameter
/// (nothing when none does).
class PresetsParameter extends StatelessWidget {
  const PresetsParameter({super.key, required this.onSelect, this.supportedParameterNames});
  final ValueChanged<int> onSelect;
  final List<String>? supportedParameterNames;

  static const _icons = {
    1: DifyIcon('vender/solid/editor/brush-01', size: 14, color: Color(0xFF6938EF)),
    2: DifyIcon('vender/solid/FinanceAndECommerce/scales-02', size: 14, color: Color(0xFF444CE7)),
    3: DifyIcon('vender/solid/general/target-04', size: 14, color: Color(0xFF107569)),
  };

  @override
  Widget build(BuildContext context) {
    final names = supportedParameterNames;
    final tones = [
      for (final t in toneList)
        if (names == null || t.config.keys.any(names.contains)) t,
    ];
    if (tones.isEmpty) return const SizedBox.shrink();
    final label = _c('modelProvider.loadPresets');
    return DifyDropdownMenu(
      builder: (context, controller) => DifyButton(
        size: DifyButtonSize.small,
        semanticLabel: label,
        onPressed: controller.toggle,
        trailing: const RemixIcon('arrow-down-s-line', size: 14),
        child: Text(label),
      ),
      children: [
        for (final t in tones)
          DifyMenuItem(
            onSelect: () => onSelect(t.id),
            leading: Padding(padding: const EdgeInsets.only(right: 8), child: _icons[t.id]),
            child: Text(_c('model.tone.${t.name}')),
          ),
      ],
    );
  }
}

// ---- parameter item ----------------------------------------------------------------------------------------------

/// `isNullOrUndefined`.
bool _unset(Object? v) => v == null;

/// The number a value shows as (`+value`).
num _asNum(Object? v) => v is num ? v : (num.tryParse('$v') ?? 0);

/// A number as text, without float noise (`0.30000000000000004` reads `0.3`).
String _numText(num n) {
  if (n is int || n == n.roundToDouble() && n.abs() < 1e15) return '${n.toInt()}';
  return double.parse(n.toStringAsFixed(10)).toString();
}

/// ParameterItem: the enable switch (optional parameters other than `stop`), the label and its help, then the
/// rule's control: a slider with a number input (`int` / `float` with both bounds), a number input, True / False
/// radios (`boolean`), a prompt editor with workflow variables or a plain input (`string`), a taller one or a
/// textarea (`text`), a select (`string` with options), the tag input (`tag`). An edit is reported only for a
/// value that is on (or `stop`, or a required rule); the local value is kept for the switch to assign.
class ParameterItem extends StatefulWidget {
  const ParameterItem({
    super.key,
    required this.parameterRule,
    this.value,
    this.onChange,
    this.onSwitch,
    this.isInWorkflow = false,
    this.nodesOutputVars,
    this.availableNodes = const {},
  });

  final ModelParameterRule parameterRule;
  final Object? value;
  final ValueChanged<Object?>? onChange;

  /// `(checked, assignValue)`.
  final void Function(bool checked, Object? assignValue)? onSwitch;
  final bool isInWorkflow;

  /// The workflow variables string and text parameters can insert (null: plain inputs).
  final List<VarGroup>? nodesOutputVars;
  final Map<String, WorkflowNodeInfo> availableNodes;

  @override
  State<ParameterItem> createState() => _ParameterItemState();
}

class _ParameterItemState extends State<ParameterItem> {
  Object? _local;
  late final _number = TextEditingController();
  final _numberFocus = FocusNode(debugLabel: 'parameter number');

  ModelParameterRule get _rule => widget.parameterRule;

  @override
  void initState() {
    super.initState();
    _local = widget.value;
    _numberFocus.addListener(() {
      if (!_numberFocus.hasFocus) _number.text = _numText(_asNum(_renderValue));
    });
    _syncNumber();
  }

  @override
  void didUpdateWidget(ParameterItem old) {
    super.didUpdateWidget(old);
    _syncNumber();
  }

  @override
  void dispose() {
    _number.dispose();
    _numberFocus.dispose();
    super.dispose();
  }

  /// The effect setting the number input's DOM value from the rendered value.
  void _syncNumber() {
    if ((_rule.type == 'int' || _rule.type == 'float') && !_numberFocus.hasFocus) {
      _number.text = _numText(_asNum(_renderValue));
    }
  }

  Object? get _defaultValue => switch (_rule.type) {
    'int' || 'float' => _unset(_rule.defaultValue) ? (_rule.min ?? 0) : _rule.defaultValue,
    'string' || 'text' => jsTruthy(_rule.defaultValue) ? _rule.defaultValue : '',
    'boolean' => _unset(_rule.defaultValue) ? false : _rule.defaultValue,
    'tag' => _unset(_rule.defaultValue) ? const <String>[] : _rule.defaultValue,
    _ => null,
  };

  Object? get _renderValue => widget.value ?? _local ?? _defaultValue;

  String get _label => renderI18nObject(_rule.label, _lang);

  String get _lang => LlmGroupScope.of(context).models.language;

  void _input(Object? v) {
    setState(() => _local = v);
    if (widget.onChange != null && (_rule.name == 'stop' || !_unset(widget.value) || _rule.required)) {
      widget.onChange!(v);
    }
  }

  void _numberChanged(String text) {
    num n = text.trim().isEmpty ? 0 : (num.tryParse(text) ?? 0);
    if (_rule.max != null && n > _rule.max!) {
      n = _rule.max!;
      _number.value = TextEditingValue(
        text: _numText(n),
        selection: TextSelection.collapsed(offset: _numText(n).length),
      );
    }
    if (_rule.min != null && n < _rule.min!) n = _rule.min!;
    _input(n);
  }

  void _slide(num n) {
    if (_rule.max != null && n > _rule.max!) n = _rule.max!;
    if (_rule.min != null && n < _rule.min!) n = _rule.min!;
    _input(n);
    _number.text = _numText(n);
  }

  /// The int slider's step: 1 below a max of 100, 10 below 1000, else 100.
  int get intStep {
    final max = _rule.max;
    if (max != null && max != 0) {
      if (max < 100) return 1;
      if (max < 1000) return 10;
    }
    return 100;
  }

  @override
  Widget build(BuildContext context) {
    final r = _rule;
    final label = _label;
    final help = r.help == null ? '' : renderI18nObject(r.help, _lang);
    final hasSwitch = !r.required && r.name != 'stop';
    final control = _control(label);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (hasSwitch)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 28,
                          child: DifySwitch(
                            checked: !_unset(widget.value),
                            semanticLabel: label,
                            onCheckedChange: (checked) => widget.onSwitch?.call(checked, _local ?? _defaultValue),
                          ),
                        ),
                      ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: DifyText(label, DifyType.systemXsRegular, color: DifyColors.textSecondary),
                      ),
                    ),
                    if (help.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: DifyInfotip(label: help, width: 150, content: Text(help)),
                      ),
                  ],
                ),
                if (r.type == 'tag')
                  DifyText(
                    r.tagPlaceholder == null ? '' : renderI18nObject(r.tagPlaceholder, _lang),
                    DifyType.systemXsRegular,
                    color: DifyColors.textTertiary,
                    maxLines: null,
                  ),
              ],
            ),
          ),
          ?control,
        ],
      ),
    );
  }

  Widget? _control(String label) {
    final r = _rule;
    final value = _renderValue;
    final withSlider = (r.type == 'int' || r.type == 'float') && r.min != null && r.max != null;
    switch (r.type) {
      case 'int' || 'float':
        final isInt = r.type == 'int';
        final num step = withSlider ? (isInt ? intStep : 0.1) : num.parse('0.${r.precision ?? 0}');
        final input = ParameterNumberInput(
          controller: _number,
          focusNode: _numberFocus,
          label: label,
          step: step,
          onChanged: _numberChanged,
        );
        if (!withSlider) return input;
        // DifySlider works in whole steps: the slider counts steps from min.
        final min = r.min!, max = r.max!;
        final steps = ((max - min) / step).ceil();
        final at = ((_asNum(value) - min) / step).round().clamp(0, steps);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 120,
              child: DifySlider(
                value: at,
                min: 0,
                max: steps,
                semanticLabel: label,
                valueText: (k) => _numText(_fix(min + k * step)),
                onChanged: (k) => _slide(_fix(k >= steps ? max : min + k * step)),
              ),
            ),
            input,
          ],
        );
      case 'boolean':
        // RadioGroup `w-37.5 gap-3` of Radios in `flex w-17.5 items-center gap-1.5` FieldLabels.
        return SizedBox(
          width: 150,
          child: DifyRadioGroup<bool>(
            label: label,
            value: value is bool ? value : null,
            spacing: 12,
            onValueChange: _input,
            children: [
              for (final (v, text) in const [(true, 'True'), (false, 'False')])
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 70),
                    child: DifyRadio<bool>(value: v, label: text),
                  ),
                ),
            ],
          ),
        );
      case 'string' when r.options.isEmpty:
        final vars = widget.nodesOutputVars;
        if (widget.isInWorkflow && vars != null) {
          return _EditorBox(
            width: 200,
            minHeight: 22,
            value: '${value ?? ''}',
            vars: vars,
            nodes: widget.availableNodes,
            onChange: _input,
            label: label,
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 16),
          child: SizedBox(
            width: widget.isInWorkflow ? 150 : 200,
            child: DifyInput(value: '${value ?? ''}', height: 32, semanticLabel: label, onChanged: _input),
          ),
        );
      case 'text':
        final vars = widget.nodesOutputVars;
        if (widget.isInWorkflow && vars != null) {
          return _EditorBox(
            width: 200,
            minHeight: 56,
            value: '${value ?? ''}',
            vars: vars,
            nodes: widget.availableNodes,
            onChange: _input,
            label: label,
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 16),
          child: SizedBox(
            width: 200,
            height: 80,
            child: ParameterTextArea(value: '${value ?? ''}', label: label, onChanged: _input),
          ),
        );
      case 'string':
        return SizedBox(
          width: 170,
          child: DifySelect<String>(
            value: value is String ? value : null,
            options: [for (final o in r.options) (value: o, label: o)],
            onChanged: _input,
          ),
        );
      case 'tag':
        return SizedBox(
          width: 170,
          child: DifyTagInput(
            items: [for (final t in (value is List ? value : const [])) '$t'],
            onChange: _input,
            customizedConfirmKey: LogicalKeyboardKey.tab,
            isInWorkflow: widget.isInWorkflow,
            required: r.required,
            label: label,
            onError: (m) => LlmGroupScope.of(context).toast?.call(LlmToastType.error, m),
          ),
        );
    }
    return null;
  }

  num _fix(num n) => n is int ? n : double.parse(n.toStringAsFixed(10));
}

/// The number input of a parameter: `ml-4 h-8 w-16 rounded-lg bg-components-input-bg-normal pl-3 system-sm-regular`,
/// reporting each keystroke; [step] is the input's `step` attribute.
class ParameterNumberInput extends StatelessWidget {
  const ParameterNumberInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.step,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final num step;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 32,
    margin: const EdgeInsets.only(left: 16),
    padding: const EdgeInsets.only(left: 12, right: 4),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Semantics(
      label: label,
      textField: true,
      child: EditableText(
        controller: controller,
        focusNode: focusNode,
        style: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled),
        cursorColor: DifyColors.componentsInputTextFilled,
        backgroundCursorColor: DifyColors.textQuaternary,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.eE]'))],
        onChanged: onChanged,
      ),
    ),
  );
}

/// The textarea of a `text` parameter outside a workflow (`h-20 w-full rounded-lg bg-components-input-bg-normal`).
class ParameterTextArea extends StatefulWidget {
  const ParameterTextArea({super.key, required this.value, required this.label, required this.onChanged});
  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  State<ParameterTextArea> createState() => _ParameterTextAreaState();
}

class _ParameterTextAreaState extends State<ParameterTextArea> {
  late final _c = TextEditingController(text: widget.value);
  final _f = FocusNode(debugLabel: 'parameter text');

  @override
  void didUpdateWidget(ParameterTextArea old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Semantics(
      label: widget.label,
      textField: true,
      multiline: true,
      child: EditableText(
        controller: _c,
        focusNode: _f,
        maxLines: null,
        expands: true,
        style: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled),
        cursorColor: DifyColors.componentsInputTextFilled,
        backgroundCursorColor: DifyColors.textQuaternary,
        onChanged: widget.onChanged,
      ),
    ),
  );
}

/// The workflow prompt editor of a string or text parameter (`ml-4 rounded-lg bg-components-input-bg-normal px-2
/// py-1`, compact, with the workflow variable block).
class _EditorBox extends StatelessWidget {
  const _EditorBox({
    required this.width,
    required this.minHeight,
    required this.value,
    required this.vars,
    required this.nodes,
    required this.onChange,
    required this.label,
  });
  final double width, minHeight;
  final String value, label;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodes;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    margin: const EdgeInsets.only(left: 16),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: DifyPromptEditor(
      compact: true,
      minHeight: minHeight,
      value: value,
      onChange: onChange,
      semanticLabel: label,
      workflowVariableBlock: WorkflowVariableBlockConfig(show: true, variables: vars, workflowNodesMap: nodes),
    ),
  );
}
