/// The node panel's single run (nodes/_base/components/workflow-panel/last-run/use-last-run.ts handleSingleRun /
/// handleRunWithParams, the BeforeRunForm overlay) and its Last Run tab (last-run/index.tsx with no-data.tsx), over
/// the editor's [SingleRunController]s.
///
/// The single-run forms are built from the variables the node's config references (Dify builds them per node type
/// with `getInputVars`; Start uses its variables, PE/QC have query and optional vision forms). Values
/// held as inspect variables count as set, so a node whose references all have values runs at once.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../../workflow/dify_json.dart' show difyDataOf, jsList;
import '../../node_panel/bodies/data/human_input/human_input_kit.dart';
import '../../node_panel/bodies/data/human_input/human_input_model.dart' show processedHumanInputFormInputs;
import '../../node_panel/bodies/data/human_input/single_run.dart' show HumanInputRunForm;
import '../../node_panel/last_run.dart' as no_data;
import '../../node_panel/bodies/llm/group_host.dart';
import '../../node_panel/bodies/llm/model_common.dart' as models;
import '../forms/query_vision_single_run.dart';
import '../../store/workflow_store.dart';
import '../../store/workflow_store_scope.dart';
import '../run_scope.dart';
import '../run_types.dart';
import '../single_run.dart';
import 'before_run_form.dart';
import 'log_widgets.dart';
import 'result_panel.dart';
import 'run_logs.dart';

/// A variable a node reads: its selector and the label the form shows.
typedef _NodeVar = ({List<String> selector, DifyJson label});

/// The selectors in [v] (live and broken references, `sys` / `env` / `conversation` selector lists).
void _collectSelectors(Value? v, List<List<String>> out) {
  switch (v) {
    case VRef(:final ref) || VBroken(:final ref):
      out.add([ref.node, ref.output]);
    case VList(:final items):
      final strings = [
        for (final i in items)
          if (i is VString) i.value,
      ];
      if (strings.length == items.length &&
          strings.length >= 2 &&
          const {'sys', 'env', 'conversation'}.contains(strings.first)) {
        out.add(strings);
      } else {
        for (final i in items) {
          _collectSelectors(i, out);
        }
      }
    case VItems(:final items):
      for (final i in items) {
        _collectSelectors(i.value, out);
      }
    case VMap(:final entries):
      for (final e in entries.values) {
        _collectSelectors(e, out);
      }
    default:
  }
}

List<_NodeVar> _nodeVars(Node node, Document doc) {
  final selectors = <List<String>>[];
  for (final e in node.config.entries) {
    if (e.key.startsWith('_')) continue;
    _collectSelectors(e.value, selectors);
  }
  final seen = <String>{};
  final start = doc.nodes.values.where((n) => n.type == 'start').firstOrNull;
  return [
    for (final s in selectors)
      if (seen.add(s.join('.')))
        (
          selector: s,
          label: switch (s.first) {
            'conversation' => {
              'nodeType': 'start',
              'nodeName': '',
              'variable': s.sublist(1).join('.'),
              'isChatVar': true,
            },
            'sys' || 'env' => {
              'nodeType': 'start',
              'nodeName': s.first == 'sys' ? (start?.title ?? 'Start') : 'ENV',
              'variable': s.join('.'),
            },
            _ => {
              'nodeType': doc.nodes[s.first]?.type ?? 'start',
              'nodeName': doc.nodes[s.first]?.title ?? s.first,
              'variable': s.sublist(1).join('.'),
            },
          },
        ),
  ];
}

/// The single-run forms of [node] (the before-run form's `forms`), their values in [values].
List<RunFormProps> singleRunFormsOf(
  Node node,
  Document doc, {
  required Map<String, Object?> values,
  required ValueChanged<Map<String, Object?>> onChange,
  bool isChatMode = false,
  List<DifyJson> Function(List<DifyJson> variables)? toVarInputs,
  List<DifyJson> Function(List<String>)? getInputVars,
  DifyJson? Function(List<String>)? resolveVisionInput,
  bool isVisionModel = false,
  DifyJson Function()? currentValues,
}) {
  if (const {'parameter-extractor', 'question-classifier'}.contains(node.type)) {
    return QueryVisionSingleRunParams(
      nodeType: node.type,
      payload: difyDataOf(node),
      values: values,
      onChange: onChange,
      getInputVars: getInputVars ?? (_) => const [],
      isVisionModel: isVisionModel,
      resolveVisionInput: resolveVisionInput ?? (_) => null,
      currentValues: currentValues,
    ).forms;
  }
  // code / template-transform use-single-run-form-params: one form (no label) over the input variables, each named
  // and labelled by its own name (toVarInputs).
  if (toVarInputs != null && const {'code', 'template-transform'}.contains(node.type)) {
    final variables = [
      for (final v in (difyDataOf(node)['variables'] as List? ?? const []))
        if (v is Map) v.cast<String, Object?>(),
    ];
    if (variables.isEmpty) return const [];
    return [RunFormProps(inputs: toVarInputs(variables), values: values, onChange: onChange)];
  }
  if (node.type == 'start') {
    final data = difyDataOf(node);
    final vars = [for (final v in (data['variables'] as List? ?? const [])) (v as Map).cast<String, Object?>()];
    return [
      RunFormProps(
        inputs: [
          ...vars,
          if (isChatMode)
            {'type': InputVarType.textInput, 'variable': '#sys.query#', 'label': 'sys.query', 'required': true},
          {'type': InputVarType.multiFiles, 'variable': '#sys.files#', 'label': 'sys.files', 'required': false},
        ],
        values: values,
        onChange: onChange,
      ),
    ];
  }
  final vars = _nodeVars(node, doc);
  if (vars.isEmpty) return const [];
  return [
    RunFormProps(
      label: DifyI18n.tr('workflow', 'nodes.llm.singleRun.variable'),
      inputs: [
        for (final v in vars)
          {
            'type': node.type == 'iteration' && v.selector.join('.') == _iteratorSelector(node)?.join('.')
                ? InputVarType.iterator
                : InputVarType.textInput,
            'variable': '#${v.selector.join('.')}#',
            'label': v.label,
            'required': true,
            'value_selector': v.selector,
          },
      ],
      values: values,
      onChange: onChange,
    ),
  ];
}

List<String>? _iteratorSelector(Node node) {
  final out = <List<String>>[];
  _collectSelectors(node.config['iterator_selector'], out);
  return out.firstOrNull;
}

/// `hasSetInspectVar`: the variable has an inspect value (a node's last output, a system or conversation variable).
bool hasSetInspectVar(WorkflowStore store, String nodeId, String varName) {
  if (nodeId == 'conversation') return store.conversationVars.value.any((v) => v['name'] == varName);
  for (final n in store.nodesWithInspectVars.value) {
    if (n['nodeId'] != nodeId) continue;
    return (n['vars'] as List? ?? const []).any((v) => v is Map && v['name'] == varName);
  }
  return false;
}

/// `getExistVarValuesInForms`: per form, the inputs that already have inspect values (the node's own inner
/// variables count as set).
List<Map<String, Object?>> existVarValuesInForms(List<RunFormProps> forms, WorkflowStore store, Node node) => [
  for (final form in forms)
    {
      for (final input in form.inputs)
        // getDependentVar: an input named by its variable (code, template-transform) stands for its selector.
        if (_dependentVar(node, '${input['variable']}') case final s?)
          if ((node.type != 'start' && s.first == node.id) ||
              hasSetInspectVar(store, s.first, s.length > 1 ? s[1] : ''))
            '${input['variable']}': true,
      for (final input in form.inputs)
        if ('${input['variable']}'.startsWith('#') && '${input['variable']}'.contains('.'))
          if ('${input['variable']}'.substring(1, '${input['variable']}'.length - 1).split('.') case final s
              when (node.type != 'start' && s.first == node.id) ||
                  hasSetInspectVar(store, s.first, s.length > 1 ? s[1] : ''))
            '${input['variable']}': true,
    },
];

/// The selector a code / template-transform input variable is set from (`getDependentVar`), if any.
List<String>? _dependentVar(Node node, String variable) {
  if (const {'parameter-extractor', 'question-classifier'}.contains(node.type)) {
    final selector = queryVisionDependentVar(node.type, difyDataOf(node), variable);
    return selector == null || selector.isEmpty ? null : selector;
  }
  if (!const {'code', 'template-transform'}.contains(node.type) || variable.startsWith('#')) return null;
  for (final v in (difyDataOf(node)['variables'] as List? ?? const [])) {
    if (v is Map && v['variable'] == variable && v['value_selector'] is List) {
      return [for (final s in v['value_selector'] as List) '$s'];
    }
  }
  return null;
}

/// `getFilteredExistVarForms`: the forms without the inputs that have values, empty forms dropped.
List<RunFormProps> filteredExistVarForms(List<RunFormProps> forms, List<Map<String, Object?>> exist) => [
  for (final (i, f) in forms.indexed)
    if ([
          for (final input in f.inputs)
            if (!(i < exist.length && exist[i].containsKey('${input['variable']}'))) input,
        ]
        case final inputs when inputs.isNotEmpty)
      RunFormProps(label: f.label, inputs: inputs, values: f.values, onChange: f.onChange),
];

bool _visionModel(BuildContext context, Node node) {
  final model = models.modelOf(difyDataOf(node)['model']);
  return models.isVisionModel(LlmGroupScope.of(context), model.provider, model.name);
}

DifyJson? _visionInput(SingleRunController controller, List<String> selector) {
  final input = controller.varSelectorsToVarInputs([selector]).firstOrNull;
  return input != null && const {InputVarType.singleFile, InputVarType.multiFiles}.contains(input['type'])
      ? input
      : null;
}

/// Custom run forms (workflow-panel/helpers.tsx). Data sources need a pipeline host; all other nodes use the
/// generic before-run form. A host may provide the data-source form without coupling the editor to a pipeline.
Widget? getCustomRunForm({required String nodeType, Widget Function()? dataSourceForm}) =>
    nodeType == 'datasource' ? dataSourceForm?.call() : null;

/// handleSingleRun: runs [node] at once when nothing needs filling (switching the panel to Last Run), else opens the
/// before-run form. False without a run scope (no runtime).
bool handleNodeSingleRun(BuildContext context, Node node, Document doc) {
  final scope = WorkflowRunScope.maybeOf(context);
  if (scope == null) return false;
  final store = WorkflowStoreScope.of(context);
  final c = scope.singleRunOf(node.id);
  if (!c.validate().isValid) return true;
  if (const {'trigger-webhook', 'trigger-plugin', 'trigger-schedule'}.contains(node.type)) {
    store.setShowVariableInspectPanel(true);
  }
  final forms = singleRunFormsOf(
    node,
    doc,
    values: const {},
    onChange: (_) {},
    isChatMode: scope.run.isChatMode(),
    toVarInputs: c.toVarInputs,
    getInputVars: c.getFormInputVars,
    isVisionModel: _visionModel(context, node),
    resolveVisionInput: (selector) => _visionInput(c, selector),
  );
  final missing = filteredExistVarForms(forms, existVarValuesInForms(forms, store, node));
  if (missing.isEmpty) {
    c
      ..isRunAfterSingleRun = true
      ..setNodeRunning();
    store.setInitShowLastRunTab(true);
    c.handleRun(const {});
  } else {
    c.showSingleRun();
  }
  return true;
}

/// The single-run form over the node panel (BasePanel's `shouldRenderSingleRunPanel`): shown while the node's
/// `_isSingleRun` is on; Start Run runs with the values (handleRunWithParams) and switches to Last Run.
class NodeSingleRunOverlay extends StatefulWidget {
  const NodeSingleRunOverlay({super.key, required this.node, required this.doc, this.dataSourceForm});
  final Node node;
  final Document doc;
  final Widget Function()? dataSourceForm;

  @override
  State<NodeSingleRunOverlay> createState() => _NodeSingleRunOverlayState();
}

class _NodeSingleRunOverlayState extends State<NodeSingleRunOverlay> {
  Map<String, Object?> _values = {};

  /// A human input node's generated form (`use-single-run-form-params`): null until "Run this step" asks for it.
  Map<String, Object?>? _generatedForm;

  /// The values the form was generated with (its `inputs`, sent back with the answers).
  Map<String, Object?> _generatedWith = const {};

  /// `handleShowGeneratedForm`: the server renders the node's form with the values its variables need.
  Future<void> _showGeneratedForm(SingleRunController c, Map<String, Object?> inputs) async {
    final fetch = HumanInputHost.of(context).fetchGeneratedForm;
    if (fetch == null) return;
    final data = await fetch(widget.node.id, inputs);
    if (!mounted) return;
    setState(() {
      _generatedForm = data;
      _generatedWith = inputs;
    });
  }

  /// `handleHumanInputFormSubmit` then `handleAfterHumanInputStepRun`: the answers are saved as the node's variables
  /// (no run happens), the form closes and the Last Run tab shows them.
  Future<void> _submitGeneratedForm(SingleRunController c, Map<String, Object?> inputs, String action) async {
    final submit = HumanInputHost.of(context).submitGeneratedForm;
    final form = _generatedForm;
    if (submit == null || form == null) return;
    final fromServer = jsList(form['inputs']);
    await submit(widget.node.id, {
      'inputs': _generatedWith,
      'form_inputs': processedHumanInputFormInputs(
        fromServer.isNotEmpty ? fromServer : jsList(difyDataOf(widget.node)['inputs']),
        inputs,
      ),
      'action': action,
    });
    if (!mounted) return;
    setState(() => _generatedForm = null);
    unawaited(c.fetchLastRun());
  }

  @override
  Widget build(BuildContext context) {
    final scope = WorkflowRunScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final store = WorkflowStoreScope.of(context);
    final c = scope.singleRunOf(widget.node.id);
    return ValueListenableBuilder(
      valueListenable: store.nodeRunData,
      builder: (context, _, _) {
        if (!c.isShowSingleRun) return const SizedBox.shrink();
        final custom = getCustomRunForm(nodeType: widget.node.type, dataSourceForm: widget.dataSourceForm);
        if (custom != null) return Positioned.fill(child: custom);
        if (_generatedForm case final form?) {
          return Positioned.fill(
            child: RunPanelWrap(
              nodeName: widget.node.title,
              onHide: c.hideSingleRun,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: HumanInputRunForm(
                  nodeName: widget.node.title,
                  showBackButton: true,
                  data: form,
                  onBack: () => setState(() => _generatedForm = null),
                  onSubmit: (inputs, action) => _submitGeneratedForm(c, inputs, action),
                ),
              ),
            ),
          );
        }
        final forms = singleRunFormsOf(
          widget.node,
          widget.doc,
          values: _values,
          onChange: (v) => setState(() => _values = v),
          isChatMode: scope.run.isChatMode(),
          toVarInputs: c.toVarInputs,
          getInputVars: c.getFormInputVars,
          isVisionModel: _visionModel(context, widget.node),
          resolveVisionInput: (selector) => _visionInput(c, selector),
          currentValues: () => _values,
        );
        if (forms.isEmpty) return const SizedBox.shrink();
        final exist = existVarValuesInForms(forms, store, widget.node);
        return Positioned.fill(
          child: BeforeRunForm(
            nodeName: widget.node.title,
            nodeType: widget.node.type,
            onHide: c.hideSingleRun,
            forms: forms,
            existVarValuesInForms: exist,
            filteredExistVarForms: filteredExistVarForms(forms, exist),
            onRun: (data) {
              if (!c.validate().isValid) return;
              c
                ..setNodeRunning()
                ..isRunAfterSingleRun = true;
              store.setInitShowLastRunTab(true);
              c.handleRun(data);
              c.hideSingleRun();
            },
            handleShowGeneratedForm: (inputs) => _showGeneratedForm(c, inputs),
          ),
        );
      },
    );
  }
}

/// LastRun (last-run/index.tsx): the node's last run as a ResultPanel (or, right after a single run, that run while it
/// goes on and its result), the spinner while it loads, the no-data state (with "Run this node") when there is none.
/// A run that finished while the app was in the background is restored when the app comes back and the node lost its
/// status ([updateNodeRunningStatus]; Dify listens to the page's visibility).
class LastRunView extends StatefulWidget {
  const LastRunView({
    super.key,
    required this.nodeId,
    required this.canSingleRun,
    required this.isRunAfterSingleRun,
    required this.onSingleRunClicked,
    this.updateNodeRunningStatus,
    this.runningStatus,
    this.lastRun,
    this.isFetching = false,
    this.noLastRun = false,
    this.singleRunResult,
    this.isPaused = false,
    this.onFetchLastRun,
    this.logs,
  });

  final String nodeId;
  final bool canSingleRun;
  final bool isRunAfterSingleRun;
  final VoidCallback onSingleRunClicked;
  final ValueChanged<String>? updateNodeRunningStatus;

  /// The one-step run's status (`_singleRunningStatus`).
  final String? runningStatus;

  /// `useLastRun`'s data, its loading state and its 404.
  final DifyJson? lastRun;
  final bool isFetching;
  final bool noLastRun;
  final DifyJson? singleRunResult;
  final bool isPaused;

  /// Asks for the last run when it may be fetched (`useLastRun`'s `enabled`).
  final VoidCallback? onFetchLastRun;
  final RunLogs? logs;

  @override
  State<LastRunView> createState() => _LastRunViewState();
}

class _LastRunViewState extends State<LastRunView> with WidgetsBindingObserver {
  String? _hiddenFinishedStatus;
  bool _pageHasHide = false, _pageShowed = false;
  bool _fetchRequested = false;

  bool _finished(String? s) => s == NodeRunningStatus.succeeded || s == NodeRunningStatus.failed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_finished(widget.runningStatus)) _hiddenFinishedStatus = widget.runningStatus;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reset() {
    _pageHasHide = false;
    _pageShowed = false;
    _hiddenFinishedStatus = null;
  }

  @override
  void didUpdateWidget(LastRunView old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) {
      _reset();
      _fetchRequested = false;
    }
    if (old.runningStatus != widget.runningStatus && _finished(widget.runningStatus)) {
      _hiddenFinishedStatus = widget.runningStatus;
    }
    _restore();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      if (state == AppLifecycleState.resumed) {
        _pageShowed = true;
      } else if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
        _pageHasHide = true;
      }
    });
    // After the frame: the node's status may change in the same frame (frames stop while the app is hidden).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _restore();
    });
  }

  void _restore() {
    final finished = _hiddenFinishedStatus;
    if (!_pageShowed || finished == null) return;
    final s = widget.runningStatus;
    if (s == null || s == NodeRunningStatus.notStart) {
      widget.updateNodeRunningStatus?.call(finished);
      return;
    }
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, status = w.runningStatus;
    final canRunLastRun =
        !w.isRunAfterSingleRun || _finished(status) || (_pageHasHide && _finished(_hiddenFinishedStatus));
    if (canRunLastRun && !_fetchRequested && w.onFetchLastRun != null) {
      _fetchRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) w.onFetchLastRun!();
      });
    }
    if (!canRunLastRun) _fetchRequested = false;
    final lastRun = w.lastRun;
    final hasAuthoritative = canRunLastRun && lastRun != null;
    final isRunning =
        !w.isPaused &&
        (w.isRunAfterSingleRun
            ? !hasAuthoritative && (status == NodeRunningStatus.running || status == NodeRunningStatus.notStart)
            : w.isFetching);
    final runResult = (canRunLastRun ? lastRun : w.singleRunResult) ?? lastRun;
    var resolvedStatus = '${runResult?['status'] ?? ''}';
    if (w.isPaused || status == NodeRunningStatus.stopped) {
      resolvedStatus = NodeRunningStatus.stopped;
    } else if (status == NodeRunningStatus.listening) {
      resolvedStatus = NodeRunningStatus.listening;
    }
    if (w.isFetching && !w.isRunAfterSingleRun) {
      return Center(
        child: DifySpinner(size: 16, color: DifyColors.textTertiary),
      );
    }
    if (isRunning) return const SingleChildScrollView(child: ResultPanel(status: 'running', showSteps: false));
    if (!w.isPaused && (w.noLastRun || runResult == null)) {
      return no_data.LastRun(canSingleRun: w.canSingleRun, onSingleRun: w.onSingleRunClicked);
    }
    final logs = w.logs;
    if (logs != null && logs.showSpecialResultPanel) {
      return SingleChildScrollView(child: SpecialResultPanel(logs: logs));
    }
    final r = runResult ?? const <String, Object?>{};
    final meta = r['execution_metadata'] as Map?;
    return SingleChildScrollView(
      child: ResultPanel.fromJson(
        {...r, 'total_tokens': meta?['total_tokens'] ?? r['total_tokens']},
        status: resolvedStatus,
        createdBy: switch (((r['created_by_account'] as Map?)?['created_by'], r['created_by'])) {
          (final String s, _) => s,
          (_, final String s) => s,
          (_, final Map m) => m['name'] as String?,
          _ => null,
        },
        nodeInfo: r,
        showSteps: false,
        handleShowIterationResultList: logs?.handleShowIterationResultList,
        handleShowLoopResultList: logs?.handleShowLoopResultList,
        onShowRetryDetail: logs?.handleShowRetryResultList,
        handleShowAgentOrToolLog: logs?.handleShowAgentOrToolLog,
      ),
    );
  }
}

/// [LastRunView] over the node's [SingleRunController] (the no-data state without a run host).
class NodeLastRun extends StatefulWidget {
  const NodeLastRun({
    super.key,
    required this.nodeId,
    required this.canSingleRun,
    required this.onSingleRun,
    this.logs,
  });
  final String nodeId;
  final bool canSingleRun;
  final VoidCallback onSingleRun;
  final RunLogs? logs;

  @override
  State<NodeLastRun> createState() => _NodeLastRunState();
}

class _NodeLastRunState extends State<NodeLastRun> {
  SingleRunController? _c;
  WorkflowStore? _store;
  late final _logs = widget.logs ?? RunLogs();
  bool _fetchedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = WorkflowStoreScope.of(context);
    _c = WorkflowRunScope.maybeOf(context)?.singleRunOf(widget.nodeId);
  }

  @override
  void dispose() {
    // handleTabClicked: leaving the tab ends the "after a single run" view.
    _c?.isRunAfterSingleRun = false;
    if (widget.logs == null) _logs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return no_data.LastRun(canSingleRun: widget.canSingleRun, onSingleRun: widget.onSingleRun);
    return ListenableBuilder(
      listenable: Listenable.merge([c, _store!.nodeRunData, _logs]),
      builder: (context, _) => LastRunView(
        nodeId: widget.nodeId,
        canSingleRun: widget.canSingleRun,
        isRunAfterSingleRun: c.isRunAfterSingleRun,
        onSingleRunClicked: widget.onSingleRun,
        updateNodeRunningStatus: (s) => _store!.setNodeRunData(widget.nodeId, {'_singleRunningStatus': s}),
        runningStatus: c.runningStatus,
        lastRun: c.lastRun,
        isFetching: c.isLastRunLoading || (!_fetchedOnce && !c.isRunAfterSingleRun),
        noLastRun: _fetchedOnce && !c.isLastRunLoading && c.lastRun == null,
        singleRunResult: c.runResult,
        isPaused: c.isPaused,
        onFetchLastRun: () async {
          await c.fetchLastRun();
          if (mounted) setState(() => _fetchedOnce = true);
        },
        logs: _logs,
      ),
    );
  }
}
