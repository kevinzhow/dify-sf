/// The editor's run/debug wiring: [WorkflowRunHost] makes one editor's [WorkflowRunController] (over the injected
/// [WorkflowRunService], the mock by default), keeps the single-run controllers per node, shows the run status on
/// the canvas cards, and hands all of it down in a [WorkflowRunScope].
library;

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../editor/editor_controller.dart';
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
String canvasStatusOf(DifyJson runData) => switch (runData['_runningStatus']) {
  NodeRunningStatus.running ||
  NodeRunningStatus.succeeded ||
  NodeRunningStatus.failed ||
  NodeRunningStatus.exception ||
  NodeRunningStatus.paused => runData['_runningStatus'] as String,
  _ => 'idle',
};

/// Keeps [CanvasController.nodeRunStatus] in step with [WorkflowStore.nodeRunData].
class RunCanvasBinding {
  RunCanvasBinding(this.store, this.canvas) {
    store.nodeRunData.addListener(_sync);
    _sync();
  }

  final WorkflowStore store;
  final CanvasController canvas;

  void _sync() {
    final next = <String, String>{};
    store.nodeRunData.value.forEach((id, data) {
      final s = canvasStatusOf(data);
      if (s != 'idle') next[id] = s;
    });
    final old = canvas.nodeRunStatus.value;
    if (old.length == next.length && next.entries.every((e) => old[e.key] == e.value)) return;
    canvas.nodeRunStatus.value = next;
  }

  void dispose() => store.nodeRunData.removeListener(_sync);
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
    onCancelSelection: () => widget.controller.selectNode(null),
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
    fetchInspectVars: widget.fetchInspectVars,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    binding;
  }

  @override
  void dispose() {
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
