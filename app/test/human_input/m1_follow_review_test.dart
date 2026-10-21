import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

const graph = StaticRunGraph(
  nodes: [
    RunGraphNode(id: 'start', type: 'start', title: 'Start', data: {'type': 'start'}),
    RunGraphNode(id: 'human', type: 'human-input', title: 'Human', data: {'type': 'human-input'}),
  ],
  edges: [RunGraphEdge(id: 'e', source: 'start', target: 'human')],
);

class DroppedFollowApi extends FakeWorkflowRunApi {
  DroppedFollowApi({required this.error})
    : super(
        draftRunEvents: (app, run, body) => [
          {
            'event': 'workflow_started',
            'workflow_run_id': run,
            'task_id': run,
            'data': {'id': run, 'workflow_id': app, 'inputs': body['inputs'], 'created_at': 0},
          },
          {
            'event': 'workflow_paused',
            'workflow_run_id': run,
            'task_id': run,
            'data': {
              'workflow_run_id': run,
              'status': 'paused',
              'outputs': {},
              'paused_nodes': ['human'],
              'reasons': [],
            },
          },
        ],
      );

  final bool error;
  int attempts = 0;

  @override
  Stream<Map<String, Object?>> workflowEvents(
    String runId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  }) async* {
    attempts++;
    if (attempts == 1) {
      if (error) throw const TransportException('GET /v1/workflow/run/events ended: connection reset');
      return;
    }
    yield {
      'event': 'workflow_finished',
      'workflow_run_id': runId,
      'task_id': runId,
      'data': {
        'id': runId,
        'workflow_id': 'app',
        'status': 'succeeded',
        'outputs': {'reply': 'done'},
        'elapsed_time': 0.1,
        'total_tokens': 0,
        'total_steps': 1,
        'created_at': 0,
        'finished_at': 1,
      },
    };
  }
}

void main() {
  for (final error in [false, true]) {
    test('a follow reconnects after ${error ? "an interrupted socket" : "a clean EOF"}', () async {
      final api = DroppedFollowApi(error: error);
      final store = WorkflowStore();
      final service = ServerRunService(
        runtime: ServerWorkflowRuntime(
          api: api,
          singleNodeRun: const {},
          draftRun: const {'start', 'human-input'},
          humanInput: true,
        ),
        appId: 'app',
        fallback: MockWorkflowRunService(graph: () => graph),
        nodeTypeOf: (id) => graph.nodes.where((n) => n.id == id).firstOrNull?.type,
        graphNodeTypes: () => graph.nodes.map((n) => n.type),
      );
      final run = WorkflowRunController(store: store, service: service, graph: graph, toast: (_, _) {});
      addTearDown(run.dispose);
      await run.handleRun({'inputs': <String, Object?>{}}, callback: RunCallbacks(onNotifyError: (_, [_]) {}));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(
        api.attempts,
        greaterThanOrEqualTo(2),
        reason: 'the same persisted run must be followed after the network returns',
      );
      expect(resultOf(store.workflowRunningData.value ?? const {})['status'], 'succeeded');
    });
  }

  test('disposing the editor cancels a pending follow retry', () async {
    final api = DroppedFollowApi(error: false);
    final store = WorkflowStore();
    final service = ServerRunService(
      runtime: ServerWorkflowRuntime(
        api: api,
        singleNodeRun: const {},
        draftRun: const {'start', 'human-input'},
        humanInput: true,
      ),
      appId: 'app',
      fallback: MockWorkflowRunService(graph: () => graph),
      nodeTypeOf: (id) => graph.nodes.where((n) => n.id == id).firstOrNull?.type,
      graphNodeTypes: () => graph.nodes.map((n) => n.type),
    );
    final run = WorkflowRunController(store: store, service: service, graph: graph, toast: (_, _) {});
    await run.handleRun({'inputs': <String, Object?>{}}, callback: RunCallbacks(onNotifyError: (_, [_]) {}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.attempts, 1);
    run.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(api.attempts, 1, reason: 'a disposed page must not create a new network request');
  });
}
