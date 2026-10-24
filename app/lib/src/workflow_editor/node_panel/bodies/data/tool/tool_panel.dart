/// The tool node's panel (nodes/tool/panel.tsx with hooks/use-config.ts): the "Input Variables" form (llm-form
/// parameters, `tool_parameters`), the collapsible "Settings" form (the others, `tool_configurations`), both hidden
/// while the provider needs authorization, then the output variables (TOOL_OUTPUT_STRUCT and the tool's
/// `output_schema`). The tools come from the store (or [ToolPanelHost.tools]); once the node's tool is known, empty
/// parameters / settings get their schema defaults.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../../../../workflow/workspace_tools.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/output_vars.dart' show VarType;
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import 'tool_form.dart';
import 'tool_host.dart';
import 'tool_model.dart';
import 'tool_schema_view.dart';
import '../../../panel_edit.dart';

export 'tool_host.dart';
export 'tool_model.dart';

/// The tool panel body.
Widget toolPanelBody(BuildContext context, NodePanelProps props) => ToolPanel(props: props);

class ToolPanel extends StatefulWidget {
  const ToolPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<ToolPanel> createState() => _ToolPanelState();
}

class _ToolPanelState extends State<ToolPanel> {
  bool _notSetDefaultValue = false;
  bool _syncScheduled = false;
  JsonMap? _runtimeTool;
  String? _runtimeKey;
  Object? _runtimeError;
  int _runtimeGeneration = 0;
  Map<String, Object?>? _optionsParams;
  String? _optionsKey;
  Map<String, Object?> get _dynamicOptionsParams {
    final revision = WorkflowToolsScope.of(context)?.revision ?? 0;
    final key = '${props.data['credential_id']}|$revision';
    if (_optionsKey != key || _optionsParams == null) {
      _optionsKey = key;
      _optionsParams = Map.unmodifiable({
        'credential_id': props.data['credential_id'],
        'authorization_revision': revision,
      });
    }
    return _optionsParams!;
  }

  String get _parameterKey =>
      '${props.data['provider_id']}|${props.data['tool_name']}|${props.data['credential_id']}|${WorkflowToolsScope.of(context)?.revision ?? 0}';

  void _loadRuntimeParameters(ToolConfig config) {
    final api = WorkflowToolsScope.of(context)?.api;
    if (api == null || config.currTool?['has_runtime_parameters'] != true || _runtimeKey == _parameterKey) return;
    _runtimeKey = _parameterKey;
    _runtimeTool = null;
    final generation = ++_runtimeGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _runtimeGeneration) return;
      unawaited(() async {
        try {
          final parameters = await api.runtimeParameters(
            '${props.data['provider_id']}',
            '${props.data['tool_name']}',
            credentialId: props.data['credential_id'] as String?,
          );
          if (mounted && generation == _runtimeGeneration) {
            setState(() {
              _runtimeTool = {...?config.currTool, 'parameters': parameters};
              _runtimeError = null;
            });
          }
        } on Object catch (error) {
          if (mounted && generation == _runtimeGeneration) setState(() => _runtimeError = error);
        }
      }());
    });
  }

  NodePanelProps get props => widget.props;

  ToolCollections _tools(BuildContext context) {
    final host = ToolPanelHost.of(context).tools;
    final s = props.actions.store;
    final builtIn = host?.builtIn ?? s.buildInTools.value;
    final runtime = _runtimeKey == _parameterKey ? _runtimeTool : null;
    return ToolCollections(
      builtIn: runtime == null
          ? builtIn
          : [
              for (final provider in builtIn ?? const <JsonMap>[])
                if (provider['id'] == props.data['provider_id'])
                  {
                    ...provider,
                    'tools': [
                      for (final tool in (provider['tools'] as List?) ?? const [])
                        if (tool is Map && tool['name'] == runtime['name']) runtime else tool,
                    ],
                  }
                else
                  provider,
            ],
      custom: host?.custom ?? s.customTools.value,
      workflow: host?.workflow ?? s.workflowTools.value,
      mcp: host?.mcp ?? s.mcpTools.value,
    );
  }

  /// useConfig's effect: once the tool resolves, fill empty parameters / settings with defaults (once: afterwards
  /// they are not empty) and re-key the prompt editors.
  void _syncDefaults(ToolConfig config) {
    if (_syncScheduled || props.readOnly || config.formattingParameters() == null) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      final fresh = ToolConfig.of(props.data, _tools(context));
      final next = fresh.formattingParameters();
      if (next == null) return;
      _write(fresh.coerce(next));
      props.actions.store.setControlPromptEditorRerenderKey(DateTime.now().millisecondsSinceEpoch);
    });
  }

  /// `setInputs`: each changed parameter / setting entry is its own op (`tool_parameters.<name>`), so edits of
  /// different fields merge; other keys as [setInputs] writes them.
  void _write(JsonMap next, [int? base]) {
    final node = props.node, doc = props.controller.doc;
    final rest = <String, Object?>{...props.data};
    for (final key in const ['tool_parameters', 'tool_configurations']) {
      final orig = node.config[key];
      final want = next[key];
      rest[key] = plainOf(orig);
      if (want is! Map || jsonEquals(plainOf(orig), want)) continue;
      if (orig is VMap && orig.entries.keys.every(want.containsKey)) {
        for (final MapEntry(key: k, value: v) in want.entries) {
          final o = orig.entries['$k'];
          if (jsonEquals(plainOf(o), v)) continue;
          props.controller.setConfig(props.id, [key, '$k'], mergeValue(o, v, doc), base: base);
        }
      } else {
        props.setData(key, mergeValue(orig, want, doc), base: base);
      }
    }
    setInputs(props, {
      ...rest,
      for (final e in next.entries)
        if (e.key != 'tool_parameters' && e.key != 'tool_configurations') e.key: e.value,
    }, base: base);
  }

  @override
  Widget build(BuildContext context) {
    final store = props.actions.store;
    return ListenableBuilder(
      listenable: Listenable.merge([store.buildInTools, store.customTools, store.workflowTools, store.mcpTools]),
      builder: (context, _) {
        final config = ToolConfig.of(props.data, _tools(context));
        _loadRuntimeParameters(config);
        _syncDefaults(config);
        final host = ToolPanelHost.of(context);
        final scope = NodeVars.of(props).scope;
        final env = ToolFormEnv(
          scope: scope,
          mixedVars: scope.filtered(typeIn({VarType.string, VarType.number, VarType.secret})).vars,
          nodesMap: NodeVars.of(props).nodesMap,
          version: versionOf(props),
          currentTool: config.currTool,
          currentProvider: config.currCollection,
          extraParams: _dynamicOptionsParams,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (props.data['provider_type'] == 'builtin')
              ToolCredentialControl(
                provider: config.currCollection,
                providerId: '${props.data['provider_id'] ?? ''}',
                selectedId: props.data['credential_id'] as String?,
                readOnly: props.readOnly,
                onSelected: (value) => _write({...props.data, 'credential_id': value}),
              ),
            if (_runtimeError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    DifyTextLine('$_runtimeError'),
                    DifyButton(
                      onPressed: () => setState(() => _runtimeKey = null),
                      child: DifyTextLine(DifyI18n.tr('common', 'operation.retry')),
                    ),
                  ],
                ),
              ),
            ToolPanelView(
              config: config,
              readOnly: props.readOnly,
              env: env,
              toolSettingValue: config.toolSettingValue(notSetDefaultValue: _notSetDefaultValue),
              onInputVarChange: (value, [base]) =>
                  _write(config.coerce({...props.data, 'tool_parameters': value}), base),
              onSettingChange: (value, [base]) {
                if (!_notSetDefaultValue) setState(() => _notSetDefaultValue = true);
                _write(config.coerce({...props.data, 'tool_configurations': value}), base);
              },
              onManageInputField: host.onManageInputField,
              matchSchemaType: (s) => getMatchedSchemaType(s, host.schemaTypeDefinitions),
            ),
          ],
        );
      },
    );
  }
}

/// What panel.tsx renders from useConfig's result.
class ToolPanelView extends StatefulWidget {
  const ToolPanelView({
    super.key,
    required this.config,
    required this.onInputVarChange,
    required this.onSettingChange,
    this.toolSettingValue = const {},
    this.readOnly = false,
    this.env = const ToolFormEnv(),
    this.onManageInputField,
    this.matchSchemaType,
  });

  final ToolConfig config;
  final bool readOnly;
  final ToolFormEnv env;
  final JsonMap toolSettingValue;
  final ToolFormChange onInputVarChange, onSettingChange;

  /// The RAG pipeline's input field panel (the input form's "Manage input field").
  final VoidCallback? onManageInputField;
  final SchemaTypeMatcher? matchSchemaType;

  @override
  State<ToolPanelView> createState() => _ToolPanelViewState();
}

class _ToolPanelViewState extends State<ToolPanelView> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final w = widget, c = w.config;
    if (c.isLoading) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'Loading',
        child: SizedBox(
          height: 200,
          child: Center(child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textTertiary)),
        ),
      );
    }
    final inputs = c.toolInputVarSchema, settings = c.toolSettingSchema;
    final indent = c.hasObjectOutput;
    String schemaTypeOf(Object? v) => w.matchSchemaType?.call(v) ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!c.isShowAuthBtn) ...[
            if (inputs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Field(
                  title: wf('nodes.tool.inputVars'),
                  child: ToolForm(
                    readOnly: w.readOnly,
                    schema: inputs,
                    value: c.toolParameters,
                    onChange: w.onInputVarChange,
                    env: w.env,
                    showManageInputField: w.onManageInputField != null,
                    onManageInputField: w.onManageInputField,
                  ),
                ),
              ),
            if (inputs.isNotEmpty && settings.isNotEmpty) const PanelSplit(margin: EdgeInsets.only(top: 4)),
            if (settings.isNotEmpty) ...[
              OutputVars(
                title: wf('nodes.tool.settings'),
                collapsed: _collapsed,
                onCollapse: (v) => setState(() => _collapsed = v),
                child: ToolForm(
                  readOnly: w.readOnly,
                  schema: settings,
                  value: w.toolSettingValue,
                  onChange: w.onSettingChange,
                  env: w.env,
                ),
              ),
              const PanelSplit(),
            ],
          ],
          OutputVars(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VarItem(
                  name: 'text',
                  type: 'string',
                  description: wf('nodes.tool.outputVars.text'),
                  isIndent: indent,
                ),
                VarItem(
                  name: 'files',
                  type: 'array[file]',
                  description: wf('nodes.tool.outputVars.files.title'),
                  isIndent: indent,
                ),
                VarItem(
                  name: 'json',
                  type: 'array[object]',
                  description: wf('nodes.tool.outputVars.json'),
                  isIndent: indent,
                ),
                for (final o in c.outputSchema)
                  if (jsGet(o.value, 'type') == 'object')
                    StructureOutputShow(
                      payload: wrapStructuredVarItem(o, schemaTypeOf(o.value)),
                      rootStyle: DifyType.codeSmSemibold,
                    )
                  else
                    () {
                      final st = schemaTypeOf(o.value);
                      return VarItem(
                        name: o.name,
                        type: '${(o.type ?? '').toLowerCase()}${st.isNotEmpty ? ' ($st)' : ''}',
                        description: o.description ?? '',
                        isIndent: indent,
                      );
                    }(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
