/// The panel body of Agent v2 (nodes/agent-v2/panel.tsx with components/agent-task-field.tsx and the binding
/// hooks of hooks.ts): the agent binding, the agent task and the declared output variables.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor.dart';
import '../../node_panel_bodies.dart';
import 'agent_v2_logic.dart';
import 'agent_v2_outputs.dart';
import 'agent_v2_roster.dart';
import 'group_host.dart';
import 'llm_config.dart' show jsonClone;
import '../../panel_edit.dart';
import 'llm_vars.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _a(String key) => DifyI18n.tr('agent-v-2', key);

/// The panel body of Agent v2 (nodes/agent-v2/panel.tsx).
Widget agentV2PanelBody(BuildContext context, NodePanelProps props) =>
    AgentV2Panel(key: ValueKey('agent-v2-${props.id}'), props: props);

/// The binding as Dify's `agent_binding`, the copy / create responses' `binding` or the binding itself.
Json? _bindingOf(Json? response) {
  if (response == null) return null;
  final b = response['binding'];
  return b is Map ? jsMap(b) : response;
}

/// AgentV2Panel. Its State holds what Dify's panel keeps in hooks and refs: the roster agent and inline composer
/// queries, the drawer's open state, the pending creation / copy, and the output names the task last had.
class AgentV2Panel extends StatefulWidget {
  const AgentV2Panel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<AgentV2Panel> createState() => _AgentV2PanelState();
}

class _AgentV2PanelState extends State<AgentV2Panel> {
  final _outputsKey = GlobalKey<AgentOutputVariablesState>();
  late Set<String> _promptOutputNames = extractAgentOutputNames(jsStr(_inputs['agent_task']) ?? '');
  String? _lastTask;
  bool _rosterPanelOpen = false, _openedFromTrigger = false, _creating = false, _copying = false;
  bool _outputsCollapsed = true;

  // useAgentRosterDetail
  String? _rosterId;
  Json? _roster;

  // useWorkflowInlineAgentDetail
  ({String node, String agent, String? snapshot})? _inlineKey;
  InlineAgentQuery? _inline;

  LlmGroupServices _services = LlmGroupServices.empty;

  NodePanelProps get props => widget.props;

  /// The node's data now (Dify's inputsRef: the document applies our writes at once).
  Json get _inputs {
    final node = props.controller.doc.nodes[props.id] ?? props.node;
    return NodePanelProps(node: node, controller: props.controller, actions: props.actions).data;
  }

  void _write(Json next) => setInputs(props, next..remove('agent_roster'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _services = LlmGroupScope.of(context);
  }

  @override
  void dispose() {
    _inline?.dispose();
    super.dispose();
  }

  void _setOpenInlineAgentPanelNodeId([String? id]) => props.actions.store.setOpenInlineAgentPanelNodeId(id);

  // ----- queries -----

  void _syncQueries(Json data) {
    final binding = jsMap(data['agent_binding']);
    final rosterId = binding['binding_type'] == 'roster_agent' ? jsStr(binding['agent_id']) : null;
    if (rosterId != _rosterId) {
      _rosterId = rosterId;
      _roster = null;
      final fetch = _services.fetchRosterAgent;
      if (rosterId != null && rosterId.isNotEmpty && fetch != null) {
        fetch(rosterId).then((v) {
          if (mounted && _rosterId == rosterId) setState(() => _roster = v);
        }, onError: (_) {});
      }
    }
    final inlineId = binding['binding_type'] == 'inline_agent' ? jsStr(binding['agent_id']) : null;
    final key = inlineId == null || inlineId.isEmpty ? null : (node: props.id, agent: inlineId, snapshot: jsStr(binding['current_snapshot_id']));
    if (key != _inlineKey) {
      _inlineKey = key;
      _inline?.dispose();
      _inline = null;
      final fetch = _services.fetchInlineAgent;
      if (key != null && fetch != null) {
        final q = _inline = InlineAgentQuery(
          fetch: () => fetch(key.node, key.agent),
          onChange: () {
            if (mounted) setState(() {});
          },
        )..pollUntilReady = hasValidInlineAgentBinding(data);
        scheduleMicrotask(q.refetch);
      }
    }
    _inline?.pollUntilReady = hasValidInlineAgentBinding(data);
  }

  // ----- binding handlers -----

  void _handleRosterChange(Json agent) {
    _setOpenInlineAgentPanelNodeId();
    _write({
      ...jsonClone(_inputs),
      'agent_binding': {'binding_type': 'roster_agent', 'agent_id': agent['id']},
    });
  }

  void _setInlineBinding(Json binding, {bool open = false}) {
    if (!_services.composerCommitsBinding) _write({
      ...jsonClone(_inputs),
      'agent_binding': {
        'binding_type': 'inline_agent',
        'agent_id': binding['agent_id'],
        'current_snapshot_id': binding['current_snapshot_id'],
      },
    });
    if (open) _setOpenInlineAgentPanelNodeId(props.id);
  }

  bool _validInline(Json? b) =>
      b != null && b['binding_type'] == 'inline_agent' && jsTruthy(b['agent_id']) && jsTruthy(b['current_snapshot_id']);

  /// useCreateInlineAgentBinding: the composer PUT, then the binding (and the dialog) open.
  Future<void> _createInlineAgentBinding() async {
    final create = _services.createInlineAgent;
    if (create == null || _creating) return;
    setState(() => _creating = true);
    Json? binding;
    try {
      binding = _bindingOf(await create(props.id));
    } on Object {
      binding = null;
    }
    if (!mounted) return;
    setState(() => _creating = false);
    if (!_validInline(binding)) {
      _services.toast?.call(LlmToastType.error, _a('roster.nodeSelector.createInlineFailed'));
      return;
    }
    _setInlineBinding(binding!, open: true);
  }

  void _handleStartFromScratch() {
    setState(() {
      _rosterPanelOpen = false;
      _openedFromTrigger = false;
    });
    _setOpenInlineAgentPanelNodeId(props.id);
    if (!_services.composerCommitsBinding) _write({
      ...jsonClone(_inputs),
      'agent_binding': {'binding_type': 'inline_agent'},
    });
    _createInlineAgentBinding();
  }

  Future<void> _handleMakeRosterCopy() async {
    final copy = _services.copyFromRoster;
    final rosterId = _rosterId;
    if (copy == null || rosterId == null || _copying) return;
    setState(() => _copying = true);
    Json? binding;
    try {
      binding = _bindingOf(await copy(props.id, rosterId));
    } on Object {
      binding = null;
    }
    if (!mounted) return;
    setState(() => _copying = false);
    if (!_validInline(binding)) return;
    setState(() {
      _rosterPanelOpen = false;
      _openedFromTrigger = true;
    });
    _setInlineBinding(binding!, open: true);
  }

  void _handleInlineSaved(Json binding) {
    if (!_validInline(binding)) return;
    _setInlineBinding(binding);
  }

  void _handleInlineSavedToRoster(String agentId) {
    _setOpenInlineAgentPanelNodeId();
    setState(() {
      _openedFromTrigger = false;
      _rosterPanelOpen = true;
    });
    _write({
      ...jsonClone(_inputs),
      'agent_binding': {'binding_type': 'roster_agent', 'agent_id': agentId},
    });
  }

  void _openSaveToRoster(Json inlineAgent) {
    final save = _services.saveToRoster;
    if (save == null) return;
    showSaveInlineAgentToRosterDialog(
      context,
      initialAgent: inlineAgent,
      save: (body) => save(props.id, body),
      onSaved: _handleInlineSavedToRoster,
    );
  }

  void _handleAgentPanelOpenChange(bool open, {required bool ready, required bool pending, required bool waiting}) {
    if (open && waiting) return;
    if (ready || pending) {
      if (open) setState(() => _openedFromTrigger = true);
      _setOpenInlineAgentPanelNodeId(open ? props.id : null);
      if (open && ready) _inline?.refetch();
      if (open && pending && !_creating) _createInlineAgentBinding();
      return;
    }
    setState(() => _rosterPanelOpen = open);
  }

  // ----- task and outputs -----

  void _handleTaskChange(String value) {
    final r = agentTaskChange(_inputs, value, _promptOutputNames);
    _promptOutputNames = extractAgentOutputNames(value);
    _lastTask = value;
    _write(r.inputs);
  }

  void _handleDeclaredOutputsChange(List<Json> outputs, [String? agentTask]) {
    setState(() => _outputsCollapsed = false);
    final r = agentDeclaredOutputsChange(_inputs, outputs, agentTask: agentTask, promptOutputNames: _promptOutputNames);
    final task = jsStr(r.inputs['agent_task']);
    if (agentTask != null || task != jsStr(_inputs['agent_task'])) {
      _promptOutputNames = extractAgentOutputNames(task ?? '');
      _lastTask = task;
    }
    _write(r.inputs);
  }

  /// handleEditTaskOutput (a task output block asks to edit it): the floating output editor on that output, or on a
  /// new one of [type] when the task names an output not declared yet; the output variables expand.
  void editTaskOutput(String name, String type) {
    setState(() {
      _outputsCollapsed = false;
      _editingOutputFromTask = (name: name, type: type, requestKey: (_editingOutputFromTask?.requestKey ?? 0) + 1);
    });
    _floatingEditor.show();
  }

  /// The output the floating editor edits (`editingOutputFromTask`).
  ({String name, String type, int requestKey})? _editingOutputFromTask;
  final _floatingEditor = OverlayPortalController();
  final _panelKey = GlobalKey();

  void _closeFloatingEditor() {
    setState(() => _editingOutputFromTask = null);
    _floatingEditor.hide();
  }

  /// FloatingOutputEditor: `fixed w-100`, 24 px left of the panel and 144 px below its top (at least 16 px from the
  /// window's edges): the output's edit card. Confirming a renamed output renames its task tokens too.
  Widget _floatingOutputEditor(BuildContext context) {
    final editing = _editingOutputFromTask;
    if (editing == null) return const SizedBox.shrink();
    final outputs = getAgentV2DeclaredOutputs(_inputs);
    final index = outputs.indexWhere((o) => o['name'] == editing.name);
    if (index >= 0 && isDefaultOutput(outputs[index])) return const SizedBox.shrink();
    final output = index >= 0 ? outputs[index] : createAgentOutputConfig(editing.name, editing.type);
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    final panel = box != null && box.hasSize ? box.localToGlobal(Offset.zero) : Offset.zero;
    return Positioned(
      left: math.max(16, panel.dx - 400 - 24),
      top: math.max(16, panel.dy + 144),
      width: 400,
      child: OutputEditCard(
        key: ValueKey('${editing.requestKey}-${output['name']}'),
        editingIndex: index >= 0 ? index : null,
        existingOutputs: outputs,
        reservedNames: agentV2ReservedOutputNames,
        state: (draft: createDraft(output), outputIndex: index >= 0 ? index : null, childPath: null, parentPath: null),
        onCancel: _closeFloatingEditor,
        onConfirm: (next, _) {
          final task = jsStr(_inputs['agent_task']) ?? '';
          final nextTask = next['name'] != editing.name && extractAgentOutputNames(task).contains(editing.name)
              ? replaceAgentOutputName(task, editing.name, jsKey(next['name']))
              : null;
          _handleDeclaredOutputsChange(
            index >= 0
                ? [for (final (i, o) in outputs.indexed) i == index ? next : o]
                : [...outputs.where((o) => o['name'] != editing.name), next],
            nextTask,
          );
          _closeFloatingEditor();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = props.actions.store;
    return ValueListenableBuilder(
      valueListenable: store.openInlineAgentPanelNodeId,
      builder: (context, openId, _) => _build(context, openId),
    );
  }

  Widget _build(BuildContext context, String? openInlineId) {
    final data = props.data;
    final task = jsStr(data['agent_task']) ?? '';
    if (task != _lastTask) {
      _lastTask = task;
      _promptOutputNames = extractAgentOutputNames(task);
    }
    _syncQueries(data);
    final id = props.id;
    final binding = jsMap(data['agent_binding']);
    final rosterAgentId = binding['binding_type'] == 'roster_agent' ? jsStr(binding['agent_id']) : null;
    final sourceInlineAgentId = binding['binding_type'] == 'inline_agent' ? jsStr(binding['agent_id']) : null;
    final ready = hasValidInlineAgentBinding(data);
    final pending = binding['binding_type'] == 'inline_agent' && !ready;
    final query = _inline;
    final inlineAgent = jsGet(query?.data, 'agent') is Map ? jsMap(jsGet(query?.data, 'agent')) : null;
    final inlineBinding = jsMap(jsGet(query?.data, 'binding'));
    final inlineAgentId = inlineBinding['binding_type'] == 'inline_agent' && jsTruthy(inlineBinding['agent_id'])
        ? jsStr(inlineBinding['agent_id'])
        : sourceInlineAgentId;
    final created = ready && inlineAgent != null;
    final loadError = ready && (query?.isError ?? false);
    final waiting = ready && !created && !loadError;
    final inlinePanelOpen = (created || pending) && openInlineId == id;
    final panelOpen = created || pending ? inlinePanelOpen : _rosterPanelOpen;
    final bindingPending = pending || waiting || _creating;
    final canSaveInlineToRoster =
        ready && inlineAgent != null && _services.saveToRoster != null && _services.canCreateAgents;
    final displayedAgent =
        _roster ??
        (pending || ready
            ? {
                'id': inlineAgentId ?? id,
                'name': jsTruthy(inlineAgent?['name'])
                    ? inlineAgent!['name']
                    : _w('nodes.agent.roster.inlineSetup.name'),
                'description': inlineAgent?['description'],
                'role': _w('nodes.agent.roster.inlineSetup.type'),
              }
            : null);
    final outputs = getAgentV2DeclaredOutputs(data);
    final vars = NodeVars.of(props);
    final readOnly = props.readOnly;

    final workspace = _services.inlineAgentWorkspaceBuilder;
    WidgetBuilder? panelBody;
    if (panelOpen && displayedAgent != null) {
      if (ready || pending) {
        if (workspace != null) {
          panelBody = (context) => workspace(context, (
            nodeId: id,
            agentId: inlineAgentId,
            composerState: query?.data,
            onClose: () => _handleAgentPanelOpenChange(false, ready: ready, pending: pending, waiting: waiting),
            onSaved: _handleInlineSaved,
            onSaveInlineToRoster: canSaveInlineToRoster ? () => _openSaveToRoster(inlineAgent) : null,
          ));
        }
      }
    }

    final pendingSections = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
          ),
          child: AgentTaskField(
            value: task,
            readOnly: readOnly,
            vars: vars,
            outputs: outputs,
            onOutputsChange: _handleDeclaredOutputsChange,
            onEditOutput: editTaskOutput,
            onChange: _handleTaskChange,
            onOpenUrl: props.actions.options.openUrl,
            docLink: _docLink(),
          ),
        ),
        AgentOutputVariables(
          key: _outputsKey,
          outputs: outputs,
          readOnly: readOnly,
          collapsed: _outputsCollapsed,
          onCollapse: (v) => setState(() => _outputsCollapsed = v),
          onChange: _handleDeclaredOutputsChange,
        ),
      ],
    );

    return Padding(
      key: _panelKey,
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OverlayPortal(
            controller: _floatingEditor,
            overlayLocation: OverlayChildLocation.rootOverlay,
            overlayChildBuilder: _floatingOutputEditor,
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: AgentRosterField(
              agent: waiting || loadError ? null : displayedAgent,
              agentId: rosterAgentId ?? inlineAgentId ?? (pending ? id : null),
              canOpenPanel: !waiting,
              errorMessage: loadError ? _a('roster.nodeSelector.createInlineFailed') : null,
              isInlineSetup: ready || pending,
              isLoading: pending || waiting,
              isPanelCopyPending: _copying,
              isPanelOpen: panelOpen,
              isPending: bindingPending,
              isRetrying: loadError && (query?.isFetching ?? false),
              panelBody: panelBody,
              panelMode: pending || (ready && !_openedFromTrigger)
                  ? AgentRosterDrawerMode.setup
                  : AgentRosterDrawerMode.detail,
              showPanelDetailActions: !ready && !pending,
              drawerWidth: props.actions.store.nodePanelWidth.value,
              onOpenUrl: props.actions.options.openUrl,
              onChange: _handleRosterChange,
              onMakeCopy: rosterAgentId != null && _services.copyFromRoster != null ? _handleMakeRosterCopy : null,
              onPanelOpenChange: (open) =>
                  _handleAgentPanelOpenChange(open, ready: ready, pending: pending, waiting: waiting),
              onRetry: loadError ? () => query?.refetch() : null,
              onSaveInlineToRoster: canSaveInlineToRoster ? () => _openSaveToRoster(inlineAgent) : null,
              onStartFromScratch: binding['binding_type'] != 'inline_agent' ? _handleStartFromScratch : null,
            ),
          ),
          // `inert` while the inline binding is being created.
          Semantics(
            enabled: !pending,
            child: ExcludeFocus(
              excluding: pending,
              child: IgnorePointer(key: const ValueKey('agent-v2-inert'), ignoring: pending, child: pendingSections),
            ),
          ),
        ],
      ),
    );
  }

  String _docLink() {
    final language = switch (DifyI18n.current) {
      DifyI18n(:final language) => language,
      _ => DifyI18n.fallbackLanguage,
    };
    final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[language] ?? 'en';
    return 'https://docs.dify.ai/$docLanguage/${props.actions.options.docsProduct}/use-dify/nodes/agent#give-it-a-task';
  }
}

/// AgentTaskField: "Agent task" with its infotip (and the "Learn more" link), then the `h-80` prompt editor with the
/// node's variables; while focused, the gradient border and the toolbar ("Insert" types `/`, the character count).
/// Output tokens (`[§output:name:name§]`) are agent output blocks over [outputs]: "New output" in the `/` list adds
/// one ([onOutputsChange] with the prompt), a committed one asks to be edited ([onEditOutput]).
class AgentTaskField extends StatefulWidget {
  const AgentTaskField({
    super.key,
    required this.value,
    required this.onChange,
    required this.vars,
    required this.docLink,
    this.readOnly = false,
    this.onOpenUrl,
    this.outputs = const [],
    this.onOutputsChange,
    this.onEditOutput,
  });

  final String value;
  final ValueChanged<String> onChange;
  final List<Json> outputs;
  final void Function(List<Json> outputs, String? prompt)? onOutputsChange;
  final void Function(String name, String outputType)? onEditOutput;
  final NodeVars vars;
  final String docLink;
  final bool readOnly;
  final void Function(String url)? onOpenUrl;

  @override
  State<AgentTaskField> createState() => _AgentTaskFieldState();
}

class _AgentTaskFieldState extends State<AgentTaskField> {
  final _controller = PromptEditorController();
  final _focus = FocusNode(debugLabel: 'agent task');
  bool _isFocus = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // Taps on the toolbar keep the editor focused (Dify's onMouseDown preventDefault).
      if (_focus.hasFocus && !_isFocus) setState(() => _isFocus = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _insert() {
    _focus.requestFocus();
    if (!_controller.selection.isValid) {
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    }
    _controller.insertText('/');
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final tooltip = _w('nodes.agent.task.tooltip');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          SizedBox(
            height: 24,
            child: Row(
              spacing: 4,
              children: [
                Flexible(
                  child: DifyText(
                    _w('nodes.agent.task.label'),
                    DifyType.systemSmSemiboldUppercase,
                    color: DifyColors.textSecondary,
                  ),
                ),
                DifyInfotip(
                  label: tooltip,
                  content: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      DifyTextLine(tooltip),
                      DifyPressable(
                        semanticLabel: _w('nodes.agent.task.learnMore'),
                        onPressed: () => w.onOpenUrl?.call(w.docLink),
                        builder: (context, hovered, focused) => Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 2,
                          children: [
                            Flexible(
                              child: DifyTextLine(
                                _w('nodes.agent.task.learnMore'),
                                style: TextStyle(
                                  color: DifyColors.textAccent,
                                  decoration: hovered ? TextDecoration.underline : null,
                                ),
                              ),
                            ),
                            RemixIcon('external-link-line', size: 12, color: DifyColors.textAccent),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          TapRegion(
            onTapOutside: (_) {
              if (_isFocus) setState(() => _isFocus = false);
            },
            child: IgnorePointer(
              ignoring: w.readOnly,
              child: Container(
                height: 320,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  gradient: _isFocus
                      ? LinearGradient(
                          colors: [
                            DifyColors.componentsInputBorderActivePrompt1,
                            DifyColors.componentsInputBorderActivePrompt2,
                          ],
                        )
                      : null,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: _isFocus ? DifyColors.backgroundDefault : DifyColors.componentsInputBgNormal,
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: DifyPromptEditor(
                            value: w.value,
                            onChange: w.onChange,
                            controller: _controller,
                            focusNode: _focus,
                            compact: true,
                            editable: !w.readOnly,
                            height: double.infinity,
                            semanticLabel: _w('nodes.agent.task.label'),
                            placeholder: _w('nodes.agent.task.placeholder'),
                            onFocus: () => setState(() => _isFocus = true),
                            isSupportFileVar: true,
                            agentOutputBlock: AgentOutputBlockConfig(
                              show: true,
                              outputs: w.outputs,
                              onChange: w.onOutputsChange,
                              onEdit: w.onEditOutput,
                            ),
                            workflowVariableBlock: WorkflowVariableBlockConfig(
                              show: true,
                              variables: w.vars.scope.vars,
                              workflowNodesMap: w.vars.nodesMap,
                              getVarType: (_, sel) => w.vars.scope.typeOf?.call(sel),
                            ),
                          ),
                        ),
                      ),
                      if (_isFocus) _toolbar(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() => SizedBox(
    height: 32,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Flexible(
            child: DifyPressable(
              semanticLabel: _w('nodes.agent.task.insert'),
              onPressed: _insert,
              builder: (context, hovered, focused) {
                final color = hovered ? DifyColors.textSecondary : DifyColors.textTertiary;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    RemixIcon('slash-commands-2', size: 14, color: color),
                    Flexible(child: DifyText(_w('nodes.agent.task.insert'), DifyType.systemXsMedium, color: color)),
                  ],
                );
              },
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: DifyColors.backgroundDefault,
              borderRadius: BorderRadius.circular(DifyRadius.sm),
              border: Border.all(color: DifyColors.dividerRegular),
            ),
            child: DifyText('${widget.value.length}', DifyType.system2xsRegular, color: DifyColors.textTertiary),
          ),
        ],
      ),
    ),
  );
}
