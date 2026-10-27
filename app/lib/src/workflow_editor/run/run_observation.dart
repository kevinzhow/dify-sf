import '../store/workflow_store.dart';
import 'run_graph.dart';
import 'run_service.dart';
import 'run_stream.dart';
import 'unavailable_run_service.dart';
import 'workflow_run.dart';

/// Observes an accepted run through GET only. Closing this view never stops or
/// starts the server's execution. Reuse the normal snapshot and reconnect path.
class WorkflowRunObservation {
  WorkflowRunObservation({required this.store, required WorkflowRunService service, RunGraph? graph}) {
    controller = WorkflowRunController(
      store: store,
      service: ReadOnlyRunService(service.observationEvents),
      graph: graph ?? _TraceGraph(store),
    );
  }
  final WorkflowStore store;
  late final WorkflowRunController controller;

  void follow(String runId) {
    final context = WorkflowRunCallbackContext(
      container: () => (clientWidth: 0, clientHeight: 0),
      isInWorkflowDebug: false,
      fetchInspectVars: () {},
      invalidAllLastRun: () {},
      invalidateRunHistory: () {},
      clearAbortController: () {},
      clearListeningState: () {},
      handlers: controller.events,
      resume: (_, _) {}, // The read stream stays open across human-input pauses.
    );
    final base = createBaseWorkflowRunCallbacks(context);
    controller.followRun(
      runId,
      base.merge(
        RunCallbacks(
          onWorkflowStarted: (event) {
            // A reconnect sends the complete snapshot, not a second execution.
            store.workflowRunningData.value = {
              'result': {'id': runId},
              'tracing': <DifyJson>[],
            };
            store.nodeRunData.value = {};
            base.onWorkflowStarted?.call(event);
          },
          // A refused read is not evidence that the execution itself failed.
          onError: (_, [_]) {},
        ),
      ),
    );
  }

  void dispose() => controller.dispose();
}

/// A log view has no editable graph. Its snapshot supplies the nodes before
/// their progress events, so the same run handlers can project their state.
class _TraceGraph implements RunGraph {
  _TraceGraph(this.store);
  final WorkflowStore store;
  @override
  List<RunGraphNode> get nodes => [
    for (final row in store.workflowRunningData.value?['tracing'] as List? ?? const [])
      if (row is Map && row['node_id'] is String)
        RunGraphNode(id: row['node_id'] as String, type: '${row['node_type'] ?? ''}', title: '${row['title'] ?? ''}'),
  ];
  @override
  List<RunGraphEdge> get edges => const [];
}

/// Only the event reader is supplied: every execution-changing operation keeps
/// the existing unavailable implementation.
class ReadOnlyRunService extends UnavailableWorkflowRunService {
  const ReadOnlyRunService(this.events);
  final Stream<RunEvent> Function(String runId) events;
  @override
  Stream<RunEvent> workflowEvents(
    String workflowRunId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  }) => events(workflowRunId);
}
