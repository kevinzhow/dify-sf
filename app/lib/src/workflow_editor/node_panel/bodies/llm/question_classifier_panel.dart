/// The panel body of Question Classifier (nodes/question-classifier/panel.tsx, use-config.ts,
/// components/advanced-setting.tsx).
library;

import 'package:flutter/widgets.dart';

import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/config_prompt.dart' show PromptEditorEnv;
import '../../node_panel_bodies.dart';
import 'llm_panel.dart' show promptEditorEnvOf;
import 'model_common.dart';
import '../../panel_edit.dart';
import 'llm_vars.dart';
import 'qc_class_list.dart';
import 'qc_pe_kit.dart';

const _p = 'nodes.questionClassifiers';
String _w(String key) => DifyI18n.tr('workflow', key);

/// The panel body of Question Classifier (nodes/question-classifier/panel.tsx).
Widget questionClassifierPanelBody(BuildContext context, NodePanelProps props) =>
    QuestionClassifierPanel(key: ValueKey('qc-${props.id}'), props: props);

/// QuestionClassifierPanel: Model, Input Variables, vision, the classes, Advanced Setting (instruction, memory in a
/// chatflow) and the outputs.
class QuestionClassifierPanel extends StatefulWidget {
  const QuestionClassifierPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<QuestionClassifierPanel> createState() => _QuestionClassifierPanelState();
}

class _QuestionClassifierPanelState extends State<QuestionClassifierPanel> with ModelNodeConfig {
  @override
  NodePanelProps get props => widget.props;

  NodeVars? _vars;
  bool _initDone = false;

  /// The init effect (use-config.ts): with the backend's defaults loaded, missing model / classes / vision come
  /// from them; in a chatflow (not a snippet) an empty query defaults to the upstream Start node's `sys.query`.
  @override
  void moreEffects() {
    if (_initDone) return;
    final defaults = services.nodesDefaultConfigs['question-classifier'];
    if (defaults == null || defaults.isEmpty) return;
    _initDone = true;
    final current = inputs;
    var update = false;
    final next = {...current};
    for (final key in const ['model', 'classes', 'vision']) {
      if (current[key] == null && defaults[key] != null) {
        next[key] = defaults[key];
        update = true;
      }
    }
    final startId = _vars?.beforeNodes.where((n) => n.type == 'start').firstOrNull?.id;
    if (!services.isSnippetFlow &&
        jsList(current['query_variable_selector']).isEmpty &&
        props.chatMode &&
        startId != null) {
      next['query_variable_selector'] = [startId, 'sys.query'];
      update = true;
    }
    if (update) afterFrame(() => setNodeInputs({...inputs, ...next}));
  }

  List<Json> get _classes => [for (final c in jsList(inputs['classes'])) jsMap(c)];

  void _topicsChange(List<Json> classes) => produceInputs((d) => d['classes'] = classes);

  void _sortTopic(List<Json> classes) => produceInputs(
    (d) => d['classes'] = [
      for (final c in classes) {'id': c['id'], 'name': c['name'], 'label': c['label']},
    ],
  );

  void _removeClass(int index) {
    final classes = _classes;
    if (index >= classes.length) return;
    props.actions.deleteBranch(props.id, jsKey(classes[index]['id']));
    _topicsChange([
      for (final (i, c) in classes.indexed)
        if (i != index) c,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    inputs = props.data;
    final readOnly = props.readOnly, chatMode = props.chatMode;
    final vars = _vars = NodeVars.of(props);
    runEffects();
    final env = promptEditorEnvOf(context, props, vars, filterNumberStringVar, services);
    final classEnv = promptEditorEnvOf(context, props, vars, filterStringVar, services);
    final vision = jsMap(inputs['vision']);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                ModelField(
                  title: _w('$_p.model'),
                  model: model,
                  readOnly: readOnly,
                  env: env,
                  onModelChange: handleModelChanged,
                  onCompletionParamsChange: handleCompletionParamsChange,
                ),
                Field(
                  title: _w('$_p.inputVars'),
                  required: true,
                  child: VarReferencePicker(
                    value: jsSelector(inputs['query_variable_selector']),
                    scope: vars.scope,
                    readonly: readOnly,
                    isShowNodeName: true,
                    filterVar: filterStringVar,
                    onChange: (sel, _) => produceInputs((d) => d['query_variable_selector'] = sel),
                  ),
                ),
                const PanelSplit(),
                ConfigVision(
                  isVisionModel: isVisionModel(services, provider, modelName),
                  enabled: vision['enabled'] == true,
                  readOnly: readOnly,
                  scope: vars.scope,
                  config: vision['configs'] is Map ? jsMap(vision['configs']) : null,
                  onEnabledChange: handleVisionEnabledChange,
                  onConfigChange: handleVisionConfigChange,
                ),
                ClassList(
                  list: _classes,
                  readonly: readOnly,
                  env: classEnv,
                  onChange: _topicsChange,
                  onRemove: _removeClass,
                  onSort: _sortTopic,
                ),
                const PanelSplit(),
              ],
            ),
          ),
          FieldCollapse(
            title: _w('$_p.advancedSetting'),
            child: QcAdvancedSetting(
              instruction: jsStr(inputs['instruction']) ?? '',
              onInstructionChange: (v) => produceInputs((d) => d['instruction'] = v),
              hideMemorySetting: !chatMode,
              memory: inputs['memory'] is Map ? jsMap(inputs['memory']) : null,
              onMemoryChange: (m) => produceInputs((d) => d['memory'] = m),
              readonly: readOnly,
              isChatModel: isChatModel,
              isChatApp: chatMode,
              hasSetBlockStatus: instructionBlockStatus,
              env: env,
            ),
          ),
          const PanelSplit(),
          OutputVars(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VarItem(name: 'class_name', type: 'string', description: _w('$_p.outputVars.className')),
                VarItem(name: 'class_label', type: 'string', description: _w('$_p.outputVars.classLabel')),
                VarItem(name: 'usage', type: 'object', description: _w('$_p.outputVars.usage')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// AdvancedSetting: the Instruction editor, then (unless [hideMemorySetting]) MemoryConfig without role names;
/// like Dify the memory stays editable in read-only mode.
class QcAdvancedSetting extends StatelessWidget {
  const QcAdvancedSetting({
    super.key,
    required this.instruction,
    required this.onInstructionChange,
    required this.hideMemorySetting,
    required this.onMemoryChange,
    required this.isChatModel,
    required this.isChatApp,
    required this.env,
    this.memory,
    this.readonly = false,
    this.hasSetBlockStatus = (context: false, history: false, query: false),
  });

  final String instruction;
  final ValueChanged<String> onInstructionChange;
  final bool hideMemorySetting, readonly, isChatModel, isChatApp;
  final Json? memory;
  final ValueChanged<Json?> onMemoryChange;
  final ({bool context, bool history, bool query}) hasSetBlockStatus;
  final PromptEditorEnv env;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InstructionEditor(
        i18nPrefix: _p,
        value: instruction,
        onChange: onInstructionChange,
        readOnly: readonly,
        isChatModel: isChatModel,
        isChatApp: isChatApp,
        hasSetBlockStatus: hasSetBlockStatus,
        env: env,
      ),
      if (!hideMemorySetting)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: MemoryConfig(memory: memory, onChange: onMemoryChange),
        ),
    ],
  );
}
