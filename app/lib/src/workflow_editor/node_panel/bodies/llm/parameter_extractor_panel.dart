/// The panel body of Parameter Extractor (nodes/parameter-extractor/panel.tsx, use-config.ts).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import 'llm_panel.dart' show promptEditorEnvOf;
import 'model_common.dart';
import 'model_parameter_modal.dart' show ModelChoice;
import '../../panel_edit.dart';
import 'llm_vars.dart';
import 'pe_params.dart';
import 'qc_pe_kit.dart';

const _p = 'nodes.parameterExtractor';
String _w(String key) => DifyI18n.tr('workflow', key);

/// The panel body of Parameter Extractor (nodes/parameter-extractor/panel.tsx).
Widget parameterExtractorPanelBody(BuildContext context, NodePanelProps props) =>
    ParameterExtractorPanel(key: ValueKey('pe-${props.id}'), props: props);

/// ParameterExtractorPanel: Model, Input Variable, vision, Extract Parameters (import, add, the list), Instruction,
/// Advanced Setting (memory in a chatflow, the reasoning mode for function-calling models) and, with parameters,
/// the outputs.
class ParameterExtractorPanel extends StatefulWidget {
  const ParameterExtractorPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<ParameterExtractorPanel> createState() => _ParameterExtractorPanelState();
}

class _ParameterExtractorPanelState extends State<ParameterExtractorPanel> with ModelNodeConfig {
  @override
  NodePanelProps get props => widget.props;

  @override
  bool get injectRolePrefix => true;

  /// appendDefaultPromptConfig: a completion model (judged by the model before the change, as in Dify) takes the
  /// backend's completion role prefixes.
  @override
  void beforeModelChange(Json draft, ModelChoice m) {
    final defaults = services.nodesDefaultConfigs['parameter-extractor'];
    final isModeChange = m.mode != jsGet(inputs['model'], 'mode');
    if (!isModeChange || defaults == null || defaults.isEmpty || isChatModel) return;
    final role = jsGet(jsGet(jsGet(defaults, 'prompt_templates'), 'completion_model'), 'conversation_histories_role');
    defaultRolePrefix = {'user': jsGet(role, 'user_prefix'), 'assistant': jsGet(role, 'assistant_prefix')};
  }

  void _deleteInspectVars() => props.actions.store.deleteNodeInspectVars(props.id);

  /// handleOutVarRenameChange + renameInspectVarName: other nodes' uses of `[id, before]` now name `[id, after]`.
  void _renameOutVar(String before, String after) {
    final c = props.controller;
    for (final n in c.doc.nodes.values) {
      if (n.id == props.id) continue;
      Node updated;
      try {
        updated = updateNodeVars(n, [props.id, before], [props.id, after]);
      } on StateError {
        continue;
      }
      for (final e in updated.config.entries) {
        if (n.config[e.key] != e.value) c.setConfig(n.id, [e.key], e.value, base: c.seenVersion);
      }
    }
    final store = props.actions.store;
    final node = store.nodesWithInspectVars.value.where((n) => n['nodeId'] == props.id).firstOrNull;
    final v = jsList(node?['vars']).where((v) => jsGet(v, 'name') == before).firstOrNull;
    final varId = jsStr(jsGet(v, 'id'));
    if (varId != null) store.renameInspectVarName(props.id, varId, [props.id, after]);
  }

  void _paramsChange(List<Json> params, ParamRename? rename) {
    produceInputs((d) => d['parameters'] = params);
    if (rename != null) {
      _renameOutVar(rename.beforeKey, rename.afterKey);
    } else {
      _deleteInspectVars();
    }
  }

  void _addParam(Json param, ParamRename? _) {
    produceInputs((d) => d['parameters'] = [...jsList(d['parameters']), param]);
    _deleteInspectVars();
  }

  @override
  Widget build(BuildContext context) {
    inputs = props.data;
    final readOnly = props.readOnly, chatMode = props.chatMode;
    final vars = NodeVars.of(props);
    runEffects();
    final env = promptEditorEnvOf(context, props, vars, filterNumberStringVar, services);
    final vision = jsMap(inputs['vision']);
    final params = paramsOf(inputs);
    final supportsFunctionCall = supportFunctionCall(currentTextModel(services, provider, modelName)?.features);
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
                  title: _w('common.model'),
                  model: model,
                  readOnly: readOnly,
                  env: env,
                  onModelChange: handleModelChanged,
                  onCompletionParamsChange: handleCompletionParamsChange,
                ),
                Field(
                  title: _w('$_p.inputVar'),
                  required: true,
                  child: VarReferencePicker(
                    value: jsSelector(inputs['query']),
                    scope: vars.scope,
                    readonly: readOnly,
                    isShowNodeName: true,
                    filterVar: filterStringVar,
                    onChange: (sel, _) => produceInputs((d) => d['query'] = sel),
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
                Field(
                  title: _w('$_p.extractParameters'),
                  required: true,
                  operations: readOnly
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 4,
                          children: [
                            ImportFromTool(
                              language: services.models.language,
                              onImport: (list) => produceInputs((d) => d['parameters'] = list),
                            ),
                            Container(width: 1, height: 12, color: const Color(0x14101828)),
                            AddExtractParameterButton(onSave: _addParam),
                          ],
                        ),
                  child: ExtractParamList(list: params, readonly: readOnly, onChange: _paramsChange),
                ),
                InstructionEditor(
                  i18nPrefix: _p,
                  value: jsStr(inputs['instruction']) ?? '',
                  onChange: (v) => produceInputs((d) => d['instruction'] = v),
                  readOnly: readOnly,
                  isChatModel: isChatModel,
                  isChatApp: chatMode,
                  hasSetBlockStatus: instructionBlockStatus,
                  env: env,
                ),
              ],
            ),
          ),
          FieldCollapse(
            title: _w('$_p.advancedSetting'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (chatMode)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: MemoryConfig(
                      memory: inputs['memory'] is Map ? jsMap(inputs['memory']) : null,
                      readonly: readOnly,
                      canSetRoleName: !isChatModel,
                      onChange: (m) => produceInputs((d) => d['memory'] = m),
                    ),
                  ),
                if (supportsFunctionCall)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ReasoningModePicker(
                      type: jsStr(inputs['reasoning_mode']),
                      onChange: (v) => produceInputs((d) => d['reasoning_mode'] = v),
                    ),
                  ),
              ],
            ),
          ),
          if (params.isNotEmpty) ...[
            const PanelSplit(),
            OutputVars(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in params)
                    VarItem(
                      name: '${p['name'] ?? ''}',
                      type: '${p['type'] ?? ''}',
                      description: '${p['description'] ?? ''}',
                    ),
                  VarItem(name: '__is_success', type: VarType.number, description: _w('$_p.outputVars.isSuccess')),
                  VarItem(name: '__reason', type: VarType.string, description: _w('$_p.outputVars.errorReason')),
                  VarItem(name: '__usage', type: 'object', description: _w('$_p.outputVars.usage')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
