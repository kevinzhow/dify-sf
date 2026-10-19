/// The panel body of LLM (nodes/llm/panel.tsx with components/panel-memory-section.tsx, panel-output-section.tsx,
/// structure-output.tsx, reasoning-format-config.tsx, prompt-generator-btn.tsx and use-config.ts).
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/config_prompt.dart';
import '../../../prompt_editor/prompt_editor_panel.dart';
import '../../../store/store.dart';
import '../../node_panel_bodies.dart';
import 'group_host.dart';
import 'llm_config.dart';
import 'llm_json_schema.dart';
import 'model_common.dart';
import 'model_parameter_modal.dart';
import '../../panel_edit.dart';
import 'llm_vars.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);
String _a(String key) => DifyI18n.tr('app', key);

/// The panel body of LLM (nodes/llm/panel.tsx).
Widget llmPanelBody(BuildContext context, NodePanelProps props) =>
    LlmPanel(key: ValueKey('llm-${props.id}'), props: props);

/// `memory` defaults of panel-memory-section.tsx (a snippet's query starts empty).
const _defaultMemory = memoryDefault;
const _snippetDefaultMemory = {
  'window': {'enabled': false, 'size': 50},
  'query_prompt_template': '',
};

// ---- prompt items <-> data ---------------------------------------------------------------------------------------

PromptItem _promptItem(Object? p) {
  final m = jsMap(p);
  return PromptItem(
    id: jsStr(m['id']),
    role: switch (m['role']) {
      'system' => PromptRole.system,
      'user' => PromptRole.user,
      'assistant' => PromptRole.assistant,
      _ => null,
    },
    text: jsStr(m['text']) ?? '',
    editionType: switch (m['edition_type']) {
      'jinja2' => PromptEditionType.jinja2,
      'basic' => PromptEditionType.basic,
      _ => null,
    },
    jinja2Text: jsStr(m['jinja2_text']),
  );
}

/// [p] as Dify's PromptItem JSON over [orig] (its other members kept).
Json _promptJson(PromptItem p, Object? orig) => {
  ...jsMap(orig),
  'id': ?p.id,
  'role': ?p.role?.name,
  'text': p.text,
  'edition_type': ?p.editionType?.name,
  'jinja2_text': ?p.jinja2Text,
};

/// The LLM panel. Its State keeps what Dify's hooks keep across renders: the input manager's default role prefix,
/// the structured output collapse and the model request generation.
class LlmPanel extends StatefulWidget {
  const LlmPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<LlmPanel> createState() => _LlmPanelState();
}

class _LlmPanelState extends State<LlmPanel> {
  late final _manager = LlmInputManager(
    inputs: widget.props.data,
    doSetInputs: (next) => setInputs(widget.props, next),
    isChatModel: true,
  );
  late final _structured = LlmStructuredOutputConfig(
    id: widget.props.id,
    inputsOf: () => _manager.inputs,
    setInputs: _manager.setInputs,
    deleteNodeInspectorVars: widget.props.actions.store.deleteNodeInspectVars,
  );
  bool _modelChanged = false;
  bool _adoptedDefault = false;

  /// The model request bookkeeping of panel.tsx: stale answers are ignored.
  int _generation = 0;
  String _selectionKey = '';

  NodePanelProps get props => widget.props;

  LlmGroupServices _services = LlmGroupServices.empty;
  List<Object?> _env = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _services = LlmGroupScope.of(context);
  }

  void _toast(LlmToastType type, String message) => _services.toast?.call(type, message);

  LlmModelConfig get _modelConfig => LlmModelConfig(
    manager: _manager,
    environmentVariables: _env,
    onModelChanged: () => _modelChanged = true,
  );

  /// The effects of use-config and the input manager, after the frame (they write the document).
  void _effects(Json inputs, Json model, bool isEnv) {
    if (props.readOnly) return;
    final s = _services;
    if (!isEnv && !_adoptedDefault && (jsStr(model['provider']) ?? '').isEmpty) {
      final d = s.defaultModels[ModelTypeEnum.textGeneration];
      final (:currentProvider, :currentModel) = getCurrentProviderAndModel(
        s.models.textGenerationModelList,
        d == null ? null : (provider: d.provider, model: d.model),
      );
      if (currentProvider != null && currentModel != null) {
        _adoptedDefault = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _modelConfig.handleModelChanged((
            provider: currentProvider.provider,
            modelId: currentModel.model,
            mode: jsStr(currentModel.modelProperties['mode']),
          ));
        });
      }
    }
    final config = _manager.defaultConfig;
    if (config != null && config.isNotEmpty && inputs['prompt_template'] == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _manager.hydrate();
      });
    }
    if (_modelChanged) {
      _modelChanged = false;
      final m = modelOf(effectiveLlmModel(_manager.inputs, _env));
      final next = visionAfterModelChange(
        jsMap(_manager.inputs['vision']),
        isVisionModel: isVisionModel(s, m.provider, m.name),
        isChatMode: props.chatMode,
      );
      if (next != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _manager.setInputs({...jsonClone(_manager.inputs), 'vision': next});
        });
      }
    }
  }

  /// panel.tsx handleModelChange: the new model's parameter rules filter the current parameters (a warning toast
  /// names the removed ones) before the model is applied; an answer for an older selection is dropped.
  Future<void> _handleModelChange(ModelChoice m) async {
    final key = _selectionKey;
    final gen = ++_generation;
    final params = jsMap(jsGet(_manager.inputs['model'], 'completion_params'));
    final filtered = await _filterParams(m.provider, m.modelId, params, gen, key);
    if (filtered == null) return;
    _modelConfig.handleModelChanged((provider: m.provider, modelId: m.modelId, mode: m.mode), filtered);
  }

  /// fetchAndMergeValidCompletionParams with the stale-answer checks; null when dropped or failed.
  Future<Json?> _filterParams(String provider, String model, Json params, int gen, String key) async {
    final loader = _services.parameterRules;
    if (loader == null) return params;
    try {
      final rules = [for (final r in await loader(provider, model)) ModelParameterRule.fromJson(r)];
      if (!mounted || _generation != gen || _selectionKey != key) return null;
      final (params: next, :removedDetails) = mergeValidCompletionParams(params, rules, isAdvancedMode: true);
      if (removedDetails.isNotEmpty) {
        _toast(
          LlmToastType.warning,
          '${_c('modelProvider.parametersInvalidRemoved')}: '
          '${removedDetails.entries.map((e) => '${e.key} (${e.value})').join(', ')}',
        );
      }
      return next;
    } on Object {
      if (!mounted || _generation != gen || _selectionKey != key) return null;
      _toast(LlmToastType.error, _c('error'));
      return null;
    }
  }

  /// panel.tsx handleEnvironmentModelChange.
  Future<void> _handleEnvironmentModelChange(String name) async {
    final key = _selectionKey;
    final gen = ++_generation;
    final selector = ['env', name];
    final selected = getLLMEnvironmentModel(selector, _env);
    if (selected == null) return _modelConfig.handleModelSelectorChange(selector);
    if (selected['completion_params'] != null) {
      return _modelConfig.handleModelSelectorChange(selector, jsMap(selected['completion_params']));
    }
    final params = jsMap(jsGet(_manager.inputs['model'], 'completion_params'));
    final filtered = await _filterParams('${selected['provider']}', '${selected['name']}', params, gen, key);
    if (filtered == null) return;
    _modelConfig.handleModelSelectorChange(selector, filtered);
  }

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.environmentVariables,
      builder: (context, env, _) => _build(context, env),
    );
  }

  Widget _build(BuildContext context, List<Json> env) {
    final s = _services;
    final readOnly = props.readOnly, isChatMode = props.chatMode;
    // A List<Object?> (node_validators' resolveLLMNodeModel calls firstWhere(orElse: () => null) on it).
    _env = List<Object?>.of(env);
    final inputs = props.data;
    final isEnv = isEnvironmentModelSource(inputs['model_selector']);
    final model = effectiveLlmModel(inputs, _env);
    final (:provider, :name, :mode) = modelOf(model);
    final isChatModel = mode == 'chat';
    _manager
      ..inputs = inputs
      ..defaultConfig = s.nodesDefaultConfigs['llm']
      ..isChatModel = isChatModel;
    final selectedEnvName = isEnv && jsList(inputs['model_selector']).length > 1
        ? jsKey(jsList(inputs['model_selector'])[1])
        : null;
    _selectionKey =
        '${isEnv ? 'env' : 'direct'}:${selectedEnvName ?? ''}:$provider:$name:${jsonEncode(model['completion_params'])}';
    _effects(inputs, model, isEnv);

    final prompt = LlmPromptConfig(
      inputsOf: () => _manager.inputs,
      setInputs: _manager.setInputs,
      isChatMode: isChatMode,
      isChatModel: isChatModel,
    );
    final vars = NodeVars.of(props);
    final installed = s.models.providers.any((p) => extractPluginIdOf(p.provider) == extractPluginIdOf(provider));
    final hasModelWarning =
        getLLMModelIssue(
          modelProvider: provider,
          isModelProviderInstalled: provider.isEmpty || installed,
        ) !=
        null;
    final llmEnv = [
      for (final v in env)
        if (v['value_type'] == 'llm' && v['name'] is String) v['name']! as String,
    ];
    final promptFilter = prompt.isShowVars ? filterJinja2InputVar : filterInputVar;
    final promptEnv = promptEditorEnvOf(context, props, vars, promptFilter, s);
    final blockStatus = prompt.hasSetBlockStatus;
    final status = (context: blockStatus.context, history: blockStatus.history, query: blockStatus.query);

    final children = <Widget>[
      Field(
        title: _w('nodes.llm.model'),
        required: true,
        warningDot: hasModelWarning,
        operations: s.isSnippetFlow && !isEnv
            ? null
            : FormInputTypeSwitch(
                value: isEnv ? VarKindType.variable : VarKindType.constant,
                readonly: readOnly,
                onChanged: (v) {
                  final useEnv = v == VarKindType.variable;
                  if (useEnv == isEnv) return;
                  _generation++;
                  _modelConfig.handleModelSourceChange(useEnv);
                },
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            if (isEnv)
              DifySelect<String>(
                value: selectedEnvName,
                placeholder: selectedEnvName ?? _w('nodes.common.typeSwitch.variable'),
                disabled: readOnly,
                options: [for (final n in llmEnv) (value: n, label: n)],
                onChanged: _handleEnvironmentModelChange,
              ),
            ModelParameterModal(
              provider: provider,
              modelId: name,
              completionParams: jsMap(model['completion_params']),
              onModelChange: _handleModelChange,
              onCompletionParamsChange: _modelConfig.handleCompletionParamsChange,
              readonly: readOnly || isEnv,
              modelSelectorReadonly: isEnv,
              nodesOutputVars: promptEnv.nodesOutputVars,
              availableNodes: promptEnv.availableNodes,
            ),
          ],
        ),
      ),
      Field(
        title: _w('nodes.llm.context'),
        tooltip: _w('nodes.llm.contextTooltip'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VarReferencePicker(
              value: jsSelector(jsGet(inputs['context'], 'variable_selector')),
              scope: vars.scope,
              readonly: readOnly,
              isShowNodeName: true,
              filterVar: filterMemoryPromptVar,
              onChange: (sel, _) => prompt.handleContextVarChange(sel),
            ),
            if (prompt.shouldShowContextTip)
              Text(
                _w('nodes.llm.notSetContextInPromptTip'),
                style: const TextStyle(fontSize: 12, height: 18 / 12, color: Color(0xFFDC6803)),
              ),
          ],
        ),
      ),
      if (name.isNotEmpty)
        ConfigPrompt(
          nodeId: props.id,
          readOnly: readOnly,
          isChatModel: isChatModel,
          isChatApp: isChatMode,
          isShowContext: true,
          hasSetBlockStatus: status,
          payload: isChatModel && inputs['prompt_template'] is List
              ? [for (final p in jsList(inputs['prompt_template'])) _promptItem(p)]
              : _promptItem(inputs['prompt_template']),
          onChange: (next) => prompt.handlePromptChange(_promptPayloadJson(next, inputs['prompt_template'])),
          env: PromptEditorEnv(
            nodesOutputVars: promptEnv.nodesOutputVars,
            availableNodes: promptEnv.availableNodes,
            getVarType: promptEnv.getVarType,
            onOpenUrl: promptEnv.onOpenUrl,
            headerExtra: (id) => _generatorButton(id, prompt),
          ),
        ),
      if (prompt.isShowVars)
        Field(
          title: _w('nodes.templateTransform.inputVars'),
          operations: readOnly
              ? null
              : _AddIconButton(
                  label: '${_c('operation.add')} ${_w('nodes.templateTransform.inputVars')}',
                  onPressed: prompt.handleAddEmptyVariable,
                ),
          child: VarList(
            readonly: readOnly,
            scope: vars.scope,
            filterVar: filterJinja2InputVar,
            isSupportFileVar: false,
            list: [
              for (final v in jsList(jsGet(inputs['prompt_config'], 'jinja2_variables')))
                VarListItem(
                  variable: jsStr(jsGet(v, 'variable')) ?? '',
                  valueSelector: jsSelector(jsGet(v, 'value_selector')),
                ),
            ],
            onChange: (list) => prompt.handleVarListChange([
              for (final v in list) {'variable': v.variable, 'value_selector': v.valueSelector},
            ]),
            onVarNameChange: prompt.handleVarNameChange,
            onError: (m) => _toast(LlmToastType.error, m),
          ),
        ),
      if (isChatMode) ...[
        const PanelSplit(),
        PanelMemorySection(
          readOnly: readOnly,
          isChatModel: isChatModel,
          isCompletionModel: !isChatModel,
          isSnippetFlow: s.isSnippetFlow,
          memory: inputs['memory'] is Map ? jsMap(inputs['memory']) : null,
          hasSetBlockStatus: status,
          promptEnv: promptEnv,
          onQueryChange: prompt.handleSyeQueryChange,
          onMemoryChange: prompt.handleMemoryChange,
        ),
      ],
      ConfigVision(
        isVisionModel: isVisionModel(s, provider, name),
        enabled: jsGet(inputs['vision'], 'enabled') == true,
        readOnly: readOnly,
        scope: vars.scope,
        config: jsGet(inputs['vision'], 'configs') is Map ? jsMap(jsGet(inputs['vision'], 'configs')) : null,
        onEnabledChange: (on) => _manager.setInputs({
          ...jsonClone(_manager.inputs),
          'vision': visionEnabledChange(jsMap(_manager.inputs['vision']), on, isChatMode: isChatMode),
        }),
        onConfigChange: (c) => _manager.setInputs({
          ...jsonClone(_manager.inputs),
          'vision': {...jsMap(_manager.inputs['vision']), 'configs': c},
        }),
      ),
      ReasoningFormatConfig(
        value: jsStr(inputs['reasoning_format']) ?? 'tagged',
        readonly: readOnly,
        onChange: _structured.handleReasoningFormatChange,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 16, children: children),
          ),
          PanelOutputSection(
            readOnly: readOnly,
            structuredOutputEnabled: inputs['structured_output_enabled'] == true,
            structuredOutput: inputs['structured_output'] is Map ? jsMap(inputs['structured_output']) : null,
            isModelSupportStructuredOutput:
                isModelSupportStructuredOutput(s.models.textGenerationModelList, provider, name) == true,
            collapsed: _structured.structuredOutputCollapsed,
            onCollapse: (v) => setState(() => _structured.structuredOutputCollapsed = v),
            onEnableChange: (on) => setState(() => _structured.handleStructureOutputEnableChange(on)),
            onChange: _structured.handleStructureOutputChange,
          ),
        ],
      ),
    );
  }

  /// ConfigPrompt's value back as `prompt_template` (items keep their other members).
  Object? _promptPayloadJson(Object next, Object? orig) {
    if (next is List<PromptItem>) {
      final byId = {
        for (final o in jsList(orig)) ?jsStr(jsGet(o, 'id')): o,
      };
      final origList = jsList(orig);
      return [
        for (final (i, p) in next.indexed)
          _promptJson(
            p,
            (p.id != null ? byId[p.id] : null) ?? (p.id == null && i < origList.length ? origList[i] : null),
          ),
      ];
    }
    return _promptJson(next as PromptItem, orig);
  }

  /// PromptGeneratorBtn (every prompt item has one, as in Dify): the generated prompt replaces the item's ([id]; the
  /// completion prompt for null).
  Widget _generatorButton(String? id, LlmPromptConfig prompt) {
    final generate = _services.generatePrompt;
    return GeneratorButton(
      onPressed: generate == null
          ? null
          : () async {
              final current = _manager.inputs['prompt_template'];
              final item = id == null ? current : jsList(current).where((p) => jsGet(p, 'id') == id).firstOrNull;
              final res = await generate(props.id, jsStr(jsGet(item, 'text')) ?? '');
              if (res == null || !mounted) return;
              final latest = _manager.inputs['prompt_template'];
              prompt.handlePromptChange(
                id == null
                    ? {...jsMap(latest), 'text': res}
                    : [
                        for (final p in jsList(latest))
                          if (jsGet(p, 'id') == id) {...jsMap(p), 'text': res} else p,
                      ],
              );
            },
    );
  }
}

/// `extractPluginId` of a provider name (`org/name/provider` -> `org/name`).
String extractPluginIdOf(String provider) {
  final parts = provider.split('/');
  return parts.length >= 2 ? '${parts[0]}/${parts[1]}' : provider;
}

/// The prompt editors' environment for a node: the variables [filter] accepts, the nodes map, the variable types,
/// links.
PromptEditorEnv promptEditorEnvOf(
  BuildContext context,
  NodePanelProps props,
  NodeVars vars,
  VarFilter? filter,
  LlmGroupServices services,
) {
  final scope = filter == null ? vars.scope : vars.filtered(filter);
  return PromptEditorEnv(
    nodesOutputVars: scope.vars,
    availableNodes: vars.nodesMap,
    getVarType: (_, sel) => vars.scope.typeOf?.call(sel),
    onOpenUrl: props.actions.options.openUrl,
  );
}

/// The `p-1 hover:bg-state-base-hover` add button with `i-ri-add-line` (Field operations).
class _AddIconButton extends StatelessWidget {
  const _AddIconButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: label,
    size: DifyIconButtonSize.md,
    icon: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
    onPressed: onPressed,
  );
}

// ---- components/panel-memory-section.tsx -------------------------------------------------------------------------

/// PanelMemorySection: for a chat model with memory on, the "MEMORIES" bar (Built-in) and the USER editor of
/// `query_prompt_template` (with the sys.query warning outside snippets); then MemoryConfig (role names for
/// completion models).
class PanelMemorySection extends StatelessWidget {
  const PanelMemorySection({
    super.key,
    required this.readOnly,
    required this.isChatModel,
    required this.isCompletionModel,
    required this.memory,
    required this.hasSetBlockStatus,
    required this.promptEnv,
    required this.onQueryChange,
    required this.onMemoryChange,
    this.isChatMode = true,
    this.isSnippetFlow = false,
  });

  final bool readOnly, isChatMode, isChatModel, isCompletionModel, isSnippetFlow;
  final Json? memory;
  final BlockStatus hasSetBlockStatus;
  final PromptEditorEnv promptEnv;
  final ValueChanged<String> onQueryChange;
  final ValueChanged<Json?> onMemoryChange;

  @override
  Widget build(BuildContext context) {
    if (!isChatMode) return const SizedBox.shrink();
    final defaultMemory = isSnippetFlow ? _snippetDefaultMemory : _defaultMemory;
    final m = memory;
    final query = jsStr(m?['query_prompt_template']) ?? '';
    final tip = _w('nodes.common.memories.tip');
    final userTip = _w('nodes.llm.roleDescription.user');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isChatModel && m != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 32,
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsInputBgNormal,
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                  ),
                  child: Row(
                    children: [
                      Flexible(
                        child: DifyText(
                          _w('nodes.common.memories.title').toUpperCase(),
                          DifyType.systemXsSemibold,
                          color: DifyColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Infotip(label: tip, content: Text(tip)),
                      const Spacer(),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 120),
                        height: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: DifyColors.componentsBadgeBgDimm,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: DifyColors.dividerDeep),
                        ),
                        child: DifyText(
                          _w('nodes.common.memories.builtIn').toUpperCase(),
                          DifyType.systemXsSemibold,
                          color: DifyColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                DifyPromptEditorPanel(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      DifyText('USER', DifyType.systemXsSemibold, color: DifyColors.textSecondary),
                      Infotip(label: userTip, width: 180, content: Text(userTip)),
                    ],
                  ),
                  value: query.isNotEmpty ? query : '${defaultMemory['query_prompt_template']}',
                  onChange: onQueryChange,
                  readOnly: readOnly,
                  isChatApp: true,
                  isChatModel: true,
                  hasSetBlockStatus: hasSetBlockStatus,
                  nodesOutputVars: promptEnv.nodesOutputVars,
                  availableNodes: promptEnv.availableNodes,
                  getVarType: promptEnv.getVarType,
                  onOpenUrl: promptEnv.onOpenUrl,
                  isSupportFileVar: true,
                ),
                if (!isSnippetFlow && query.isNotEmpty && !query.contains('{{#sys.query#}}'))
                  Text(
                    _w('nodes.llm.sysQueryInUser'),
                    style: const TextStyle(fontSize: 12, height: 18 / 12, color: Color(0xFFDC6803)),
                  ),
              ],
            ),
          ),
        MemoryConfig(
          memory: m,
          readonly: readOnly,
          canSetRoleName: isCompletionModel,
          defaultMemory: defaultMemory,
          onChange: onMemoryChange,
        ),
      ],
    );
  }
}

// ---- components/reasoning-format-config.tsx ----------------------------------------------------------------------

/// ReasoningFormatConfig: "Enable reasoning tag separation" with its switch (on: `separated`, off: `tagged`).
class ReasoningFormatConfig extends StatelessWidget {
  const ReasoningFormatConfig({super.key, required this.value, required this.onChange, this.readonly = false});
  final String value;
  final ValueChanged<String> onChange;
  final bool readonly;

  @override
  Widget build(BuildContext context) => Field(
    title: _w('nodes.llm.reasoningFormat.title'),
    tooltip: _w('nodes.llm.reasoningFormat.tooltip'),
    operations: DifySwitch(
      checked: value == 'separated',
      disabled: readonly,
      semanticLabel: _w('nodes.llm.reasoningFormat.title'),
      onCheckedChange: (on) => onChange(on ? 'separated' : 'tagged'),
    ),
    child: const SizedBox.shrink(),
  );
}

// ---- components/panel-output-section.tsx, structure-output.tsx --------------------------------------------------

/// PanelOutputSection: a Split, then "Output Variables" (collapsed by default) with the STRUCTURED switch, the
/// not-supported warning, text / reasoning_content / usage and, when on, the structured output.
class PanelOutputSection extends StatelessWidget {
  const PanelOutputSection({
    super.key,
    required this.readOnly,
    required this.structuredOutputEnabled,
    required this.structuredOutput,
    required this.isModelSupportStructuredOutput,
    required this.collapsed,
    required this.onCollapse,
    required this.onEnableChange,
    required this.onChange,
  });

  final bool readOnly, structuredOutputEnabled, isModelSupportStructuredOutput, collapsed;
  final Json? structuredOutput;
  final ValueChanged<bool> onCollapse, onEnableChange;
  final ValueChanged<Json> onChange;

  @override
  Widget build(BuildContext context) {
    final tip = _a('structOutput.structuredTip');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSplit(),
        OutputVars(
          collapsed: collapsed,
          onCollapse: onCollapse,
          operations: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isModelSupportStructuredOutput && structuredOutputEnabled)
                  DifyTooltip(
                    content: SizedBox(
                      width: 232 - 32,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DifyText(
                            _a('structOutput.modelNotSupported'),
                            DifyType.titleXsSemiBold,
                            color: DifyColors.textPrimary,
                            maxLines: null,
                          ),
                          const SizedBox(height: 4),
                          DifyText(
                            _a('structOutput.modelNotSupportedTip'),
                            DifyType.bodyXsRegular,
                            color: DifyColors.textSecondary,
                            maxLines: null,
                          ),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: RemixIcon('alert-fill', size: 16, color: DifyColors.textWarningSecondary),
                    ),
                  ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: DifyText(
                      _a('structOutput.structured'),
                      DifyType.systemXsMediumUppercase,
                      color: DifyColors.textTertiary,
                    ),
                  ),
                ),
                Infotip(label: tip, width: 150, content: Text(tip)),
                const SizedBox(width: 8),
                DifySwitch(
                  checked: structuredOutputEnabled,
                  disabled: readOnly,
                  semanticLabel: _a('structOutput.structured'),
                  onCheckedChange: onEnableChange,
                ),
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VarItem(name: 'text', type: 'string', description: _w('nodes.llm.outputVars.output')),
              VarItem(
                name: 'reasoning_content',
                type: 'string',
                description: _w('nodes.llm.outputVars.reasoning_content'),
              ),
              VarItem(name: 'usage', type: 'object', description: _w('nodes.llm.outputVars.usage')),
              if (structuredOutputEnabled) ...[
                const PanelSplit(margin: EdgeInsets.only(top: 12)),
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: StructureOutput(value: structuredOutput, onChange: onChange, readOnly: readOnly),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// StructureOutput: `structured_output object` with "Configure", then the schema's fields (ShowPanel) or the
/// "not configured yet" button; both open the JSON Schema dialog, whose save gives `{schema}`.
class StructureOutput extends StatelessWidget {
  const StructureOutput({super.key, required this.value, required this.onChange, this.readOnly = false});
  final Json? value;
  final ValueChanged<Json> onChange;
  final bool readOnly;

  static const _emptySchema = {
    'type': 'object',
    'properties': <String, Object?>{},
    'required': <String>[],
    'additionalProperties': false,
  };

  Future<void> _open(BuildContext context) async {
    final schema = jsGet(value, 'schema');
    await showJsonSchemaConfigModal(
      context,
      defaultSchema: schema is Map ? jsonClone(jsMap(schema)) : jsonClone(_emptySchema),
      onSave: (s) => onChange({'schema': s}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final schema = jsGet(value, 'schema');
    final hasProps = jsKeyCount(jsGet(schema, 'properties')) > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            DifyText('structured_output', DifyType.codeSmSemibold, color: DifyColors.textSecondary),
            const SizedBox(width: 8),
            DifyText('object', DifyType.systemXsRegular, color: DifyColors.textTertiary),
            const Spacer(),
            DifyButton(
              size: DifyButtonSize.small,
              leading: const RemixIcon('edit-line', size: 14),
              onPressed: () => _open(context),
              child: Text(_a('structOutput.configure')),
            ),
          ],
        ),
        if (hasProps)
          StructureOutputItem(payload: jsMap(value))
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DifyPressable(
              semanticLabel: _a('structOutput.notConfiguredTip'),
              onPressed: () => _open(context),
              builder: (context, hovered, focused) => Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DifyColors.backgroundSection,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DifyText(
                  _a('structOutput.notConfiguredTip'),
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
