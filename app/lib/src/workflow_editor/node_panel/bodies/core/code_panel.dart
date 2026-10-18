/// The Code node's panel (nodes/code/panel.tsx, use-config.ts with _base/hooks/use-output-var-list.ts).
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/output_vars.dart' show VarType;
import '../../../code_editor/code_editor.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import '../../panel_edit.dart';
import 'code_parser.dart';
import 'core_kit.dart';

/// The language selector's options.
const codeLanguageOptions = <SelectOption<String>>[
  (value: 'python3', label: 'Python3'),
  (value: 'javascript', label: 'JavaScript'),
];

/// use-config.ts and useOutputVarList over Dify's data (`outputs` a map name -> `{type, children}`): [inputs] read
/// live, every change through [setInputs]. The hooks it calls come in as callbacks; [onStateChange] reports the
/// local state ([outputKeyOrders], the remove confirmation).
class CodeConfig {
  CodeConfig({
    required this.id,
    required this.inputs,
    required this.setInputs,
    this.readOnly = false,
    this.defaultConfig,
    this.allLanguageDefault,
    this.isVarUsedInNodes = _unused,
    this.removeUsedVarInNodes = _noop,
    this.handleOutVarRenameChange = _noRename,
    this.onStateChange,
  });

  final String id;
  final Map<String, Object?> Function() inputs;
  final ValueChanged<Map<String, Object?>> setInputs;
  final bool readOnly;

  /// `nodesDefaultConfigs.code`.
  final Map<String, Object?>? defaultConfig;

  /// The fetched default config of each language (`fetchNodeDefault` with `code_language`); null before it loads.
  final Map<String, Map<String, Object?>>? allLanguageDefault;
  final bool Function(List<String> selector) isVarUsedInNodes;
  final void Function(List<String> selector) removeUsedVarInNodes;
  final void Function(String nodeId, List<String> oldSelector, List<String> newSelector) handleOutVarRenameChange;
  final VoidCallback? onStateChange;

  static bool _unused(List<String> _) => false;
  static void _noop(List<String> _) {}
  static void _noRename(String _, List<String> _, List<String> _) {}

  List<String> outputKeyOrders = [];
  bool isShowRemoveVarConfirm = false;
  List<String> _removedVar = [];

  void _setOrders(List<String> orders) {
    outputKeyOrders = orders;
    onStateChange?.call();
  }

  Map<String, Object?> _outputs(Map<String, Object?> i) => switch (i['outputs']) {
    final Map m => {for (final e in m.entries) '${e.key}': e.value},
    _ => {},
  };

  /// The mount effect: existing code keeps its outputs' order; empty code takes the backend's default config.
  void init() {
    final i = inputs();
    if (jsTruthy(i['code'])) {
      final outputs = _outputs(i);
      if (outputs.isNotEmpty) _setOrders(outputs.keys.toList());
      return;
    }
    final d = defaultConfig;
    if (d != null && d.isNotEmpty) {
      setInputs({...i, ...d});
      _setOrders([for (final k in jsEntries(d['outputs'])) k.key]);
    }
  }

  void handleVarListChange(List<Object?> list) => setInputs({...inputs(), 'variables': list});

  void handleAddVariable() {
    final i = inputs();
    setInputs({
      ...i,
      'variables': [
        ...jsList(i['variables']),
        {'variable': '', 'value_selector': <Object?>[]},
      ],
    });
  }

  void handleCodeChange(String code) => setInputs({...inputs(), 'code': code});

  /// A language switch takes that language's default code, inputs and outputs when they are loaded.
  void handleCodeLanguageChange(String language) {
    final d = allLanguageDefault?[language];
    final next = {...inputs(), 'code_language': language};
    if (d != null) {
      next['code'] = d['code'];
      next['variables'] = d['variables'];
      next['outputs'] = d['outputs'];
    }
    setInputs(next);
  }

  void handleSyncFunctionSignature() {
    final i = inputs();
    setInputs({
      ...i,
      'code': syncFunctionSignature(jsStr(i['code']) ?? '', jsStr(i['code_language']), jsList(i['variables'])),
    });
  }

  /// [i] with `default_value` recomputed from [outputs] when the node falls back to default values.
  Map<String, Object?> _withDefaults(Map<String, Object?> i, Map<String, Object?> outputs) {
    if (i['type'] != 'code' || i['error_strategy'] != ErrorHandleType.defaultValue.value) return i;
    return {
      ...i,
      'default_value': errorDefaultValues(
        'code',
        codeOutputs: {for (final e in outputs.entries) e.key: jsStr(jsGet(e.value, 'type')) ?? ''},
      ),
    };
  }

  /// useOutputVarList handleVarsChange: a rename ([changedIndex], [newKey]) moves the key in the order and renames
  /// the uses downstream.
  void handleVarsChange(Map<String, Object?> newVars, [int? changedIndex, String? newKey]) {
    final old = [...outputKeyOrders];
    if (changedIndex != null) outputKeyOrders = [...old]..[changedIndex] = newKey!;
    setInputs(_withDefaults({...inputs(), 'outputs': newVars}, newVars));
    if (changedIndex != null) _setOrders(outputKeyOrders);
    if (newKey != null) handleOutVarRenameChange(id, [id, old[changedIndex!]], [id, newKey]);
  }

  /// generateNewKey: `var_<count + 1>`, counting up while taken.
  String _newKey(Map<String, Object?> outputs) {
    var i = outputs.length + 1;
    while (outputs.containsKey('var_$i')) {
      i++;
    }
    return 'var_$i';
  }

  void handleAddOutputVariable() {
    final i = inputs();
    final outputs = _outputs(i);
    final key = _newKey(outputs);
    final next = {...outputs, key: outputVarOf(VarType.string)};
    outputKeyOrders = [...outputKeyOrders, key];
    setInputs(_withDefaults({...i, 'outputs': next}, next));
    _setOrders(outputKeyOrders);
  }

  /// A used output asks first; confirming only clears the uses downstream (Dify's quirk: the output stays).
  void handleRemoveVariable(int index) {
    final key = outputKeyOrders[index];
    if (isVarUsedInNodes([id, key])) {
      isShowRemoveVarConfirm = true;
      _removedVar = [id, key];
      onStateChange?.call();
      return;
    }
    final orders = [
      for (final (j, k) in outputKeyOrders.indexed)
        if (j != index) k,
    ];
    final i = inputs();
    final outputs = _outputs(i);
    if (!orders.contains(key)) outputs.remove(key);
    outputKeyOrders = orders;
    setInputs(_withDefaults({...i, 'outputs': outputs}, outputs));
    _setOrders(orders);
  }

  void hideRemoveVarConfirm() {
    isShowRemoveVarConfirm = false;
    onStateChange?.call();
  }

  void onRemoveVarConfirm() {
    removeUsedVarInNodes(_removedVar);
    hideRemoveVarConfirm();
  }

  static const _types = {
    VarType.string,
    VarType.number,
    VarType.boolean,
    VarType.secret,
    VarType.object,
    VarType.array,
    VarType.arrayNumber,
    VarType.arrayString,
    VarType.arrayObject,
    VarType.arrayBoolean,
    VarType.file,
    VarType.arrayFile,
  };

  /// The input variables' types.
  static bool filterVar(String? type) => _types.contains(type);

  void handleCodeAndVarsChange(String code, List<Object?> inputVariables, Map<String, Object?> outputVariables) {
    outputKeyOrders = outputVariables.keys.toList();
    setInputs({...inputs(), 'code': code, 'variables': inputVariables, 'outputs': outputVariables});
    _setOrders(outputKeyOrders);
  }

  /// The panel's handleGeneratedCode: `main`'s parameters become the inputs, the returned keys string outputs.
  void handleGeneratedCode(String value) {
    final language = jsStr(inputs()['code_language']) ?? 'python3';
    handleCodeAndVarsChange(
      value,
      [
        for (final p in extractFunctionParams(value, language)) {'variable': p, 'value_selector': <Object?>[]},
      ],
      extractReturnType(value, language),
    );
  }
}

// ---- the document side -------------------------------------------------------------------------------------------

/// The Code node's Dify data from the document's: `outputs` (a keyed list of `{name, type, children}`) as Dify's
/// map, and the names in item order.
({Map<String, Object?> inputs, List<String> orders}) codeInputsOf(Map<String, Object?> data) {
  final outputs = data['outputs'];
  if (outputs is! List) return (inputs: data, orders: [for (final e in jsEntries(outputs)) e.key]);
  final orders = <String>[];
  final map = <String, Object?>{};
  for (final o in outputs) {
    final name = jsStr(jsGet(o, 'name'));
    if (name == null) continue;
    orders.add(name);
    map[name] = {
      for (final e in jsEntries(o))
        if (e.key != 'name') e.key: e.value,
    };
  }
  return (inputs: {...data, 'outputs': map}, orders: orders);
}

/// Dify's `outputs` map as the document's list, in [orders] (a name twice stays twice), then the other keys.
List<Object?> codeOutputsListOf(Object? outputs, List<String> orders) {
  final map = {for (final e in jsEntries(outputs)) e.key: e.value};
  Map<String, Object?> item(String k) => {...?(map[k] as Map?)?.cast<String, Object?>(), 'name': k};
  return [
    for (final k in orders)
      if (map.containsKey(k)) item(k),
    for (final k in map.keys)
      if (!orders.contains(k)) item(k),
  ];
}

/// Writes Dify's [next] data for [props]' node; a change to [textKey] alone is typed text (written with [base]).
void writeCoreInputs(NodePanelProps props, Map<String, Object?> next, {String? textKey, int Function()? base}) =>
    PanelInputs(props).setInputs(next, textKey: textKey, textBase: base);

// ---- the panel ---------------------------------------------------------------------------------------------------

Widget codePanelBody(BuildContext context, NodePanelProps props) => _CodePanel(props: props);

class _CodePanel extends StatefulWidget {
  const _CodePanel({required this.props});
  final NodePanelProps props;

  @override
  State<_CodePanel> createState() => _CodePanelState();
}

class _CodePanelState extends State<_CodePanel> {
  late final _base = TypingBase(() => widget.props.controller.seenVersion);
  CodeConfig? _c;
  bool _confirming = false;

  CodeConfig get _config => _c ??= () {
    final host = CorePanelHost.of(context);
    final c = widget.props.controller;
    return CodeConfig(
      id: widget.props.id,
      inputs: () => codeInputsOf(PanelInputs(widget.props).inputs).inputs,
      setInputs: _write,
      readOnly: widget.props.readOnly,
      defaultConfig: host.nodesDefaultConfigs['code'],
      allLanguageDefault: host.codeLanguageDefaults.isEmpty ? null : host.codeLanguageDefaults,
      isVarUsedInNodes: (s) => isVarUsedInNodes(c, s),
      removeUsedVarInNodes: (s) => removeUsedVarInNodes(c, s),
      handleOutVarRenameChange: (_, o, n) => handleOutVarRenameChange(c, o, n),
      onStateChange: _onState,
    )..outputKeyOrders = codeInputsOf(widget.props.data).orders;
  }();

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.props.readOnly) _config.init();
    });
  }

  @override
  void didUpdateWidget(_CodePanel old) {
    super.didUpdateWidget(old);
    // Others edit the outputs too: the order is the document's.
    _config.outputKeyOrders = codeInputsOf(widget.props.data).orders;
  }

  void _write(Map<String, Object?> next) {
    final orders = _config.outputKeyOrders;
    writeCoreInputs(
      widget.props,
      next.containsKey('outputs') ? {...next, 'outputs': codeOutputsListOf(next['outputs'], orders)} : next,
      textKey: 'code',
      base: _base.call,
    );
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final c = _config;
    if (c.isShowRemoveVarConfirm && !_confirming) {
      _confirming = true;
      showRemoveEffectVarConfirm(
        context,
        onConfirm: c.onRemoveVarConfirm,
        onCancel: c.hideRemoveVarConfirm,
      ).whenComplete(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.props, c = _config, readOnly = props.readOnly;
    final host = CorePanelHost.of(context);
    final inputs = c.inputs();
    final variables = inputs['variables'];
    final language = jsStr(inputs['code_language']) ?? 'python3';
    final outputs = {for (final e in jsEntries(inputs['outputs'])) e.key: jsStr(jsGet(e.value, 'type')) ?? ''};
    final inputsTitle = tw('nodes.code.inputVars'), outputsTitle = tw('nodes.code.outputVars');
    final sync = tw('nodes.code.syncFunctionSignature');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              Field(
                title: inputsTitle,
                operations: readOnly
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          DifyTooltip(
                            content: Text(sync),
                            child: _IconOperation(
                              label: sync,
                              icon: 'refresh-line',
                              onPressed: c.handleSyncFunctionSignature,
                            ),
                          ),
                          FieldAddButton(
                            label: '${tc('operation.add')} $inputsTitle',
                            onPressed: c.handleAddVariable,
                            alone: false,
                          ),
                        ],
                      ),
                child: VarList(
                  readonly: readOnly,
                  list: varListItemsOf(variables),
                  scope: NodeVars.of(props).scope,
                  filterVar: (v, _) => CodeConfig.filterVar(v.type),
                  isSupportFileVar: false,
                  onChange: (rows) => c.handleVarListChange(varListDataOf(rows, variables)),
                  onError: host.toastError,
                ),
              ),
              const PanelSplit(),
              DifyCodeEditor(
                isInNode: true,
                readOnly: readOnly,
                titleWidget: TypeSelector<String>(
                  triggerUppercase: true,
                  options: codeLanguageOptions,
                  value: language,
                  onChanged: c.handleCodeLanguageChange,
                ),
                language: CodeLanguage.parse(language),
                value: jsStr(inputs['code']) ?? '',
                onChange: c.handleCodeChange,
                codeGenerator:
                    host.codeGenerator?.call(context, props.id, language, c.handleGeneratedCode) ??
                    const GeneratorButton(),
              ),
            ],
          ),
        ),
        const PanelSplit(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Field(
            title: outputsTitle,
            required: true,
            operations: FieldAddButton(
              label: '${tc('operation.add')} $outputsTitle',
              onPressed: c.handleAddOutputVariable,
            ),
            child: OutputVarList(
              readonly: readOnly,
              outputs: outputs,
              outputKeyOrders: c.outputKeyOrders,
              onError: host.toastError,
              onChange: (types, [index, newKey]) {
                final old = {for (final e in jsEntries(inputs['outputs'])) e.key: e.value};
                c.handleVarsChange(
                  {
                    for (final e in types.entries)
                      e.key: {...?(old[e.key] as Map?)?.cast<String, Object?>(), ...outputVarOf(e.value)},
                  },
                  index,
                  newKey,
                );
              },
              onRemove: c.handleRemoveVariable,
            ),
          ),
        ),
      ],
    );
  }
}

/// A Field operation icon button (`cursor-pointer rounded-md p-1 hover:bg-state-base-hover`, a 16 px tertiary
/// Remix icon).
class _IconOperation extends StatelessWidget {
  const _IconOperation({required this.label, required this.icon, required this.onPressed});
  final String label, icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: focused ? Border.all(color: DifyColors.componentsInputBorderActive) : null,
      ),
      child: RemixIcon(icon, size: 16, color: DifyColors.textTertiary),
    ),
  );
}
