/// The editor's run/debug wiring: [WorkflowRunHost] makes one editor's [WorkflowRunController] (over the injected
/// [WorkflowRunService], the mock by default), keeps the single-run controllers per node, shows the run status on
/// the canvas cards, and hands all of it down in a [WorkflowRunScope].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/run_view.dart';
import '../../canvas/workflow_canvas.dart' show CanvasDefaults;
import '../../editor/editor_controller.dart';
import '../context_menu/workflow_actions.dart' show cancelNodesSelectedOn;
import '../phone/phone_editor_controller.dart' show PhoneEditorScope;
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'debug_chat.dart';
import 'mock_run_service.dart';
import 'run_graph.dart';
import 'run_service.dart';
import 'run_types.dart';
import 'single_run.dart';
import 'workflow_run.dart';

/// The canvas status a node's run fields show (Dify's node.tsx borders and header icon read `_runningStatus`).
String canvasStatusOf(DifyJson runData, {bool hasVarValue = false}) =>
    NodeRunView.fromRunData(runData, hasVarValue: hasVarValue).status;

/// Keeps [CanvasController.nodeRun] / [CanvasController.edgeRun] in step with [WorkflowStore.nodeRunData],
/// [WorkflowStore.edgeRunData] and the nodes with inspect variables (`hasNodeInspectVars`: the success border
/// without a running status). Only changed entries are replaced, so the canvas touches only the nodes that changed.
class RunCanvasBinding {
  RunCanvasBinding(this.store, this.canvas) {
    store.nodeRunData.addListener(_syncNodes);
    store.nodesWithInspectVars.addListener(_syncNodes);
    store.edgeRunData.addListener(_syncEdges);
    store.workflowRunningData.addListener(_runChanged);
    store.isListening.addListener(_runChanged);
    store.isRestoring.addListener(_runChanged);
    store.showDebugAndPreviewPanel.addListener(_runChanged);
    _syncNodes();
    _syncEdges();
  }

  final WorkflowStore store;
  final CanvasController canvas;

  /// dify-sf phones: the canvas and the Steps view show the current run's statuses only. Dify marks a node with
  /// inspect values as succeeded (`hasVarValue`; after a run it clears the succeeded statuses and leaves the marks to
  /// that): on a phone that mark shows only while a run is kept (its panel open, or its data not closed) and not on a
  /// step the run still waits for, so it goes with the closed run and does not show the last run's success during
  /// the next. No status shows while a version is browsed (its graph is not the run's), and no node is left running
  /// or waiting once the run has ended (a stop leaves the running node's status as it was).
  bool get runOnly => _runOnly;
  bool _runOnly = false;
  set runOnly(bool value) {
    if (value == _runOnly) return;
    _runOnly = value;
    _views = {};
    _syncNodes();
    _syncEdges();
  }

  /// The run's state as [runOnly] reads it: going (or listening) or not, a version browsed, and a run kept.
  (bool, bool, bool) _run = (false, false, false);

  (bool, bool, bool) get _runNow => (
    resultOf(store.workflowRunningData.value)['status'] == NodeRunningStatus.running || store.isListening.value,
    store.isRestoring.value,
    store.showDebugAndPreviewPanel.value || store.workflowRunningData.value != null,
  );

  void _runChanged() {
    final now = _runNow;
    if (now == _run) return;
    _run = now;
    if (!_runOnly) return;
    _syncNodes();
    _syncEdges();
  }

  /// The view made from each node's run fields (the store replaces only the entries a run event changes, so the
  /// others are reused as they are), with whether it had inspect values and whether the run had ended.
  var _views = <String, (DifyJson, bool, bool, NodeRunView)>{};

  static bool _stillGoing(DifyJson data) =>
      data['_runningStatus'] == NodeRunningStatus.running ||
      data['_runningStatus'] == NodeRunningStatus.waiting ||
      data['_waitingRun'] == true;

  void _syncNodes() {
    _run = _runNow;
    final (going, restoring, kept) = _run;
    if (_runOnly && restoring) {
      _views = {};
      if (canvas.nodeRun.value.isNotEmpty) canvas.nodeRun.value = const {};
      return;
    }
    final withVars = _runOnly && !kept
        ? const <Object?>{}
        : {for (final n in store.nodesWithInspectVars.value) n['nodeId']};
    final ended = _runOnly && !going;
    final next = <String, NodeRunView>{};
    final views = <String, (DifyJson, bool, bool, NodeRunView)>{};
    store.nodeRunData.value.forEach((id, data) {
      final hasVar = withVars.contains(id) && !(_runOnly && _stillGoing(data));
      final old = _views[id];
      final v = old != null && identical(old.$1, data) && old.$2 == hasVar && old.$3 == ended
          ? old.$4
          : NodeRunView.fromRunData(
              ended && _stillGoing(data) ? {...data, '_runningStatus': null, '_waitingRun': false} : data,
              hasVarValue: hasVar,
            );
      views[id] = (data, hasVar, ended, v);
      if (v != NodeRunView.idle) next[id] = v;
    });
    _views = views;
    for (final id in withVars) {
      if (id is String && !next.containsKey(id) && !views.containsKey(id)) {
        next[id] = const NodeRunView(hasVarValue: true);
      }
    }
    if (!mapEquals(canvas.nodeRun.value, next)) canvas.nodeRun.value = next;
  }

  void _syncEdges() {
    final next = <String, EdgeRunView>{};
    if (_runOnly && store.isRestoring.value) {
      if (canvas.edgeRun.value.isNotEmpty) canvas.edgeRun.value = const {};
      return;
    }
    store.edgeRunData.value.forEach((id, data) {
      final v = EdgeRunView.fromRunData(data);
      if (v != EdgeRunView.idle) next[id] = v;
    });
    if (!mapEquals(canvas.edgeRun.value, next)) canvas.edgeRun.value = next;
  }

  void dispose() {
    store.nodeRunData.removeListener(_syncNodes);
    store.nodesWithInspectVars.removeListener(_syncNodes);
    store.edgeRunData.removeListener(_syncEdges);
    store.workflowRunningData.removeListener(_runChanged);
    store.isListening.removeListener(_runChanged);
    store.isRestoring.removeListener(_runChanged);
    store.showDebugAndPreviewPanel.removeListener(_runChanged);
  }
}

/// One editor's run/debug objects (see run_service.dart's API notes).
class WorkflowRunScope extends InheritedWidget {
  const WorkflowRunScope({
    super.key,
    required this.run,
    required this.service,
    required this.singleRunOf,
    required this.createChat,
    required super.child,
  });

  final WorkflowRunController run;
  final WorkflowRunService service;

  /// The node's single-run controller (one per node for the editor's lifetime).
  final SingleRunController Function(String nodeId) singleRunOf;

  /// A chatflow preview conversation (the Debug & Preview panel makes one while it is open; dispose it after).
  final DebugChatController Function({DifyJson? config, ChatFormSettings? formSettings}) createChat;

  static WorkflowRunScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<WorkflowRunScope>();

  /// Throws when there is no scope above [context].
  static WorkflowRunScope of(BuildContext context) =>
      maybeOf(context) ?? (throw StateError('Missing WorkflowRunScope in the tree'));

  @override
  bool updateShouldNotify(WorkflowRunScope old) => run != old.run || service != old.service;
}

/// Makes the run objects for the editor of [controller] (inside its WorkflowStoreScope) and puts them in a
/// [WorkflowRunScope] over [child].
class WorkflowRunHost extends StatefulWidget {
  const WorkflowRunHost({
    super.key,
    required this.controller,
    required this.canvas,
    this.service,
    this.isChatMode,
    this.fetchInspectVars,
    required this.child,
  });

  final EditorController controller;
  final CanvasController canvas;

  /// The backend; null: a [MockWorkflowRunService] over the editor's graph.
  final WorkflowRunService? service;

  /// Chatflow (advanced-chat).
  final bool Function()? isChatMode;

  /// Reloads the variable inspect panel after runs.
  final VoidCallback? fetchInspectVars;
  final Widget child;

  @override
  State<WorkflowRunHost> createState() => WorkflowRunHostState();
}

class WorkflowRunHostState extends State<WorkflowRunHost> {
  late final WorkflowStore store = WorkflowStoreScope.of(context);
  late final graph = EditorRunGraph(widget.controller, widget.canvas);
  late final WorkflowRunService service =
      widget.service ??
      MockWorkflowRunService(graph: () => graph, conversationVariables: () => store.conversationVariables.value);
  late final run = WorkflowRunController(
    store: store,
    service: service,
    graph: graph,
    viewport: _viewport,
    isChatMode: () => widget.isChatMode?.call() ?? false,
    fetchInspectVars: () => widget.fetchInspectVars?.call(),
    onCancelSelection: () => cancelNodesSelectedOn(widget.canvas, widget.controller),
    onValidationFailed: (issue) {
      final id = issue['id'];
      if (id is! String || !widget.controller.doc.nodes.containsKey(id)) return;
      widget.controller.selectNode(id);
      if (issue['openInlineAgentPanel'] == true) store.setOpenInlineAgentPanelNodeId(id);
    },
  );
  late final binding = RunCanvasBinding(store, widget.canvas);
  late final _viewport = CanvasRunViewport(widget.canvas);
  final _singleRuns = <String, SingleRunController>{};

  SingleRunController _singleRunOf(String nodeId) => _singleRuns[nodeId] ??= SingleRunController(
    nodeId: nodeId,
    store: store,
    service: service,
    graph: graph,
    run: run,
    isChatMode: () => widget.isChatMode?.call() ?? false,
  );

  /// `EVENT_WORKFLOW_STOP` (the variable inspect panel's Stop): the header's run mode stops the run, every node's
  /// single run stops.
  void emitWorkflowStop() {
    run.handleStopRun('${store.workflowRunningData.value?['task_id'] ?? ''}');
    for (final s in _singleRuns.values) {
      s.handleStop();
    }
  }

  DebugChatController _createChat({DifyJson? config, ChatFormSettings? formSettings}) => DebugChatController(
    run: run,
    service: service,
    store: store,
    config: config,
    formSettings: formSettings,
    graph: graph,
    stopChat: (taskId) => service.stopChatMessageResponding(taskId),
    resumeStream: run.followRun,
    fetchInspectVars: widget.fetchInspectVars,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // dify-sf: on a phone the cards show the current run's statuses only ([RunCanvasBinding.runOnly]).
    final phone = PhoneEditorScope.maybeOf(context);
    binding.runOnly = phone != null;
    // A running node is revealed on a phone, not centred beside the desktop's run panel.
    _viewport.phoneCover = phone == null ? null : () => phone.canvasCover?.call() ?? 0;
    if (CanvasDefaults.reportRect && !_reporting) {
      _reporting = true;
      store.workflowRunningData.addListener(_reportRun);
    }
  }

  /// Visual tests: says when a run comes to an end (`VISUAL_RUN <status>`), so the comparison waits for it however
  /// slow the browser draws.
  bool _reporting = false;
  String? _reported;
  void _reportRun() {
    final status = resultOf(store.workflowRunningData.value)['status'] as String?;
    if (status == _reported) return;
    _reported = status;
    if (status != null && status != WorkflowRunningStatus.running) debugPrint('VISUAL_RUN $status');
  }

  @override
  void dispose() {
    if (_reporting) store.workflowRunningData.removeListener(_reportRun);
    binding.dispose();
    for (final s in _singleRuns.values) {
      s.dispose();
    }
    run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkflowRunScope(
    run: run,
    service: service,
    singleRunOf: _singleRunOf,
    createChat: _createChat,
    child: widget.child,
  );
}
