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
    _syncNodes();
    _syncEdges();
  }

  final WorkflowStore store;
  final CanvasController canvas;

  /// The view made from each node's run fields (the store replaces only the entries a run event changes, so the
  /// others are reused as they are).
  var _views = <String, (DifyJson, bool, NodeRunView)>{};

  void _syncNodes() {
    final withVars = {for (final n in store.nodesWithInspectVars.value) n['nodeId']};
    final next = <String, NodeRunView>{};
    final views = <String, (DifyJson, bool, NodeRunView)>{};
    store.nodeRunData.value.forEach((id, data) {
      final hasVar = withVars.contains(id);
      final old = _views[id];
      final v = old != null && identical(old.$1, data) && old.$2 == hasVar
          ? old.$3
          : NodeRunView.fromRunData(data, hasVarValue: hasVar);
      views[id] = (data, hasVar, v);
      if (v != NodeRunView.idle) next[id] = v;
    });
    _views = views;
    for (final id in withVars) {
      if (id is String && !next.containsKey(id)) next[id] = const NodeRunView(hasVarValue: true);
    }
    if (!mapEquals(canvas.nodeRun.value, next)) canvas.nodeRun.value = next;
  }

  void _syncEdges() {
    final next = <String, EdgeRunView>{};
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
    viewport: CanvasRunViewport(widget.canvas),
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
    binding;
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
