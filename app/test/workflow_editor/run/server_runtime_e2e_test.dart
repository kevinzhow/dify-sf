/// Protocol 1.15 against a real server (stack P of the dify-sf repository's e2e harness): a draft run with an iteration
/// and a loop goes to the server through [ServerRunService] (the server announces both node types in `draft_run`), and
/// the editor's own run handlers ([WorkflowRunController]) build the run state from the server's events as they do from
/// the stand-in's. Runs only when `DIFYSF_RUNTIME_URL` is set, e.g.
///
///     DIFYSF_RUNTIME_URL=http://127.0.0.1:18080 flutter test test/workflow_editor/run/server_runtime_e2e_test.dart
///
/// Needs the server's code sandbox (template nodes). Signs in as `DIFYSF_EMAIL` / `DIFYSF_PASSWORD` (default the e2e
/// harness's owner).
library;

import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _url = Platform.environment['DIFYSF_RUNTIME_URL'];
final String _email = Platform.environment['DIFYSF_EMAIL'] ?? 'e2e-owner@example.test';
final String _password = Platform.environment['DIFYSF_PASSWORD'] ?? 'E2e-throwaway-1';

const _yaml = '''
app:
  mode: workflow
  name: client-e2e-containers
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: it, targetHandle: target}
    - {id: e2, source: itstart, sourceHandle: source, target: tpl, targetHandle: target, data: {isInIteration: true, iteration_id: it}}
    - {id: e3, source: it, sourceHandle: source, target: lp, targetHandle: target}
    - {id: e4, source: lpstart, sourceHandle: source, target: inc, targetHandle: target, data: {isInLoop: true, loop_id: lp}}
    - {id: e5, source: lp, sourceHandle: source, target: end, targetHandle: target}
    nodes:
    - id: start
      data:
        title: Start
        type: start
        variables:
        - {label: payload, required: true, type: json_object, variable: payload}
    - id: it
      data: {title: Each, type: iteration, start_node_id: itstart, iterator_selector: [start, payload, items],
             output_selector: [tpl, output], is_parallel: true, parallel_nums: 2}
    - id: itstart
      type: custom-iteration-start
      parentId: it
      data: {title: '', type: iteration-start, isInIteration: true}
    - id: tpl
      parentId: it
      data:
        title: Shout
        type: template-transform
        isInIteration: true
        iteration_id: it
        template: '{{ i }}:{{ x | upper }}'
        variables:
        - {variable: x, value_selector: [it, item]}
        - {variable: i, value_selector: [it, index]}
    - id: lp
      data: {title: Count, type: loop, start_node_id: lpstart, loop_count: 3, break_conditions: [], logical_operator: and,
             loop_variables: [{label: n, var_type: number, value_type: constant, value: '0'}]}
    - id: lpstart
      type: custom-loop-start
      parentId: lp
      data: {title: '', type: loop-start, isInLoop: true}
    - id: inc
      parentId: lp
      data:
        title: Add
        type: assigner
        version: '2'
        isInLoop: true
        loop_id: lp
        items:
        - {input_type: constant, operation: +=, value: 1, variable_selector: [lp, n], write_mode: over-write}
    - id: end
      data:
        title: End
        type: end
        outputs:
        - {variable: shouted, value_selector: [it, output]}
        - {variable: n, value_selector: [lp, n]}
''';

const _graph = StaticRunGraph(
  nodes: [
    RunGraphNode(id: 'start', type: 'start', title: 'Start', data: {'type': 'start', 'title': 'Start'}),
    RunGraphNode(id: 'it', type: 'iteration', title: 'Each', x: 300, data: {'type': 'iteration', 'title': 'Each'}),
    RunGraphNode(id: 'itstart', type: 'iteration-start', parentId: 'it', data: {'type': 'iteration-start'}),
    RunGraphNode(
      id: 'tpl',
      type: 'template-transform',
      title: 'Shout',
      parentId: 'it',
      data: {'type': 'template-transform'},
    ),
    RunGraphNode(id: 'lp', type: 'loop', title: 'Count', x: 600, data: {'type': 'loop', 'title': 'Count'}),
    RunGraphNode(id: 'lpstart', type: 'loop-start', parentId: 'lp', data: {'type': 'loop-start'}),
    RunGraphNode(id: 'inc', type: 'assigner', title: 'Add', parentId: 'lp', data: {'type': 'assigner'}),
    RunGraphNode(id: 'end', type: 'end', title: 'End', x: 900, data: {'type': 'end', 'title': 'End'}),
  ],
  edges: [
    RunGraphEdge(id: 'e1', source: 'start', target: 'it'),
    RunGraphEdge(id: 'e2', source: 'itstart', target: 'tpl'),
    RunGraphEdge(id: 'e3', source: 'it', target: 'lp'),
    RunGraphEdge(id: 'e4', source: 'lpstart', target: 'inc'),
    RunGraphEdge(id: 'e5', source: 'lp', target: 'end'),
  ],
);

void main() {
  if (_url == null) {
    test('server runtime e2e (set DIFYSF_RUNTIME_URL to run)', () {}, skip: 'DIFYSF_RUNTIME_URL is not set');
    return;
  }
  final base = Uri.parse(_url!);
  setUp(() => runStreamToast = (_) {});

  test('1.15: a draft run with an iteration and a loop runs on the server; the editor builds its run state', () async {
    final owner = AuthSession(api: HttpAuthApi(base));
    if (await owner.api.setupStatus() == SetupStatus.notStarted) {
      await owner.setup(email: _email, name: 'Client E2E', password: _password);
    } else {
      await owner.login(email: _email, password: _password);
    }
    final features = (await owner.api.systemFeatures()).workflowRuntime;
    expect(features?.protocolVersion, '1.15');
    expect(features?.draftRun, containsAll(['iteration', 'iteration-start', 'loop', 'loop-start', 'assigner']));
    final apps = HttpAppsApi(base, auth: owner);
    final app = (await apps.importDsl(_yaml)).appId!;
    addTearDown(() => apps.delete(app));

    final store = WorkflowStore();
    final fallback = MockWorkflowRunService(graph: () => _graph);
    final service = ServerRunService(
      runtime: ServerWorkflowRuntime(
        api: HttpWorkflowRunApi(base, auth: owner),
        singleNodeRun: features!.singleNodeRun,
        draftRun: features.draftRun,
      ),
      appId: app,
      fallback: fallback,
      nodeTypeOf: (id) => _graph.nodes.where((n) => n.id == id).firstOrNull?.type,
      graphNodeTypes: () => _graph.nodes.map((n) => n.type),
    );
    expect(service.draftRunsOnServer, isTrue);
    final run = WorkflowRunController(
      store: store,
      service: service,
      graph: _graph,
      toast: (_, m) => fail('toast: $m'),
    );
    final seen = <String>[];
    await run.handleRun(
      {
        'inputs': {
          'payload': {
            'items': ['a', 'b', 'c'],
          },
        },
      },
      callback: RunCallbacks(
        onIterationStart: (e) => seen.add('iteration_started ${e.data['node_id']}'),
        onIterationNext: (e) => seen.add('iteration_next ${e.data['index']}'),
        onIterationFinish: (e) => seen.add('iteration_completed ${e.data['status']}'),
        onLoopStart: (e) => seen.add('loop_started ${e.data['node_id']}'),
        onLoopNext: (e) => seen.add('loop_next ${e.data['index']}'),
        onLoopFinish: (e) => seen.add('loop_completed ${e.data['status']}'),
      ),
    );
    for (
      var i = 0;
      i < 600 && resultOf(store.workflowRunningData.value ?? const {})['status'] == NodeRunningStatus.running;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final data = store.workflowRunningData.value!;
    final result = resultOf(data);
    expect(result['status'], 'succeeded', reason: '$result');
    expect(result['outputs'], {
      'shouted': ['0:A', '1:B', '2:C'],
      'n': 3,
    });
    expect(seen, [
      'iteration_started it',
      'iteration_next 0',
      'iteration_next 1',
      'iteration_next 2',
      'iteration_completed succeeded',
      'loop_started lp',
      'loop_next 1',
      'loop_next 2',
      'loop_completed succeeded',
    ]);
    final tracing = tracingOf(data);
    final it = tracing.firstWhere((t) => t['node_id'] == 'it');
    expect(it['status'], 'succeeded');
    expect((it['execution_metadata'] as Map)['iteration_duration_map'], hasLength(3));
    // Dify's web keeps one tracing entry per node (a node started again replaces its entry): the last round's.
    expect(tracing.where((t) => t['node_id'] == 'tpl').map((t) => t['iteration_id']), ['it']);
    expect(tracing.where((t) => t['node_id'] == 'inc').map((t) => t['loop_id']), ['lp']);
    expect(store.nodeRunDataOf('it')['_runningStatus'], 'succeeded');
    expect(store.nodeRunDataOf('lp')['_loopLength'], 3);
    // Dify's web reads `metadata.iterator_length`, the backend sends `iteration_length` (Dify 1.17.1 as is).
    expect(store.nodeRunDataOf('it')['_iterationLength'], isNull);

    // The run is in the server's history with its node executions (the tracing panel's list).
    final history = await service.fetchWorkflowRunHistory();
    final runId = result['id'] as String;
    expect(history.map((h) => h['id']), contains(runId));
    final executions = await service.fetchTracingList(runId);
    expect(executions.map((e) => e['node_id']).where((n) => n == 'tpl'), hasLength(3));
    stdout.writeln(
      'server runtime e2e (client): ${result['outputs']} in ${result['elapsed_time']} s, ${tracing.length} traces',
    );
  });

  test('1.15: editor container single runs use the real server, with server history and failures', () async {
    final owner = AuthSession(api: HttpAuthApi(base));
    await owner.login(email: _email, password: _password);
    final features = (await owner.api.systemFeatures()).workflowRuntime!;
    expect(features.singleNodeRun, containsAll(['iteration', 'loop']));
    final apps = HttpAppsApi(base, auth: owner);
    // Dify's single-run mapper writes two-element selectors (nested object paths are rejected by Dify too).
    // Keep a two-element iterator selector here to exercise a successful dedicated container endpoint.
    final app = (await apps.importDsl(
      _yaml.replaceFirst('iterator_selector: [start, payload, items]', 'iterator_selector: [start, items]'),
    )).appId!;
    addTearDown(() => apps.delete(app));
    final service = ServerRunService(
      runtime: ServerWorkflowRuntime(
        api: HttpWorkflowRunApi(base, auth: owner),
        singleNodeRun: features.singleNodeRun,
        draftRun: features.draftRun,
      ),
      appId: app,
      fallback: MockWorkflowRunService(graph: () => _graph),
      nodeTypeOf: (id) => _graph.nodes.where((n) => n.id == id).firstOrNull?.type,
      graphNodeTypes: () => _graph.nodes.map((n) => n.type),
    );
    final iteration = await service.iterationSingleNodeRun('it', {
      'inputs': {
        'it.input_selector': ['x', 'y'],
      },
    }).toList();
    expect(iteration.whereType<IterationStartedEvent>(), hasLength(1));
    final iterFinish = iteration.whereType<WorkflowFinishedEvent>().single;
    expect(iterFinish.status, 'succeeded');
    // As in Dify, the container result belongs to iteration_completed / loop_completed; the filtered single-run
    // graph has no End/Answer node, so its workflow_finished outputs are empty.
    expect(iterFinish.data['outputs'], isEmpty);
    expect(iteration.whereType<IterationCompletedEvent>().single.data['outputs'], {
      'output': ['0:X', '1:Y'],
    });
    final loop = await service.loopSingleNodeRun('lp', {'inputs': <String, Object?>{}}).toList();
    expect(loop.whereType<LoopStartedEvent>(), hasLength(1));
    final loopFinish = loop.whereType<WorkflowFinishedEvent>().single;
    expect(loopFinish.status, 'succeeded');
    expect(loopFinish.data['outputs'], isEmpty);
    expect(loop.whereType<LoopCompletedEvent>().single.data['outputs'], {'n': 3, 'loop_round': 3});
    // These UUID runs and records must exist in the real server, not just the local stand-in's history.
    final ids = (await service.fetchWorkflowRunHistory()).map((r) => r['id']).toSet();
    for (final events in [iteration, loop]) {
      final runId = events.first.workflowRunId!;
      expect(ids, contains(runId));
      expect((await service.fetchRunDetail(runId))['status'], 'succeeded');
      expect(await service.fetchTracingList(runId), isNotEmpty);
    }
    await expectLater(
      service.iterationSingleNodeRun('it', {'inputs': <String, Object?>{}}).toList(),
      throwsA(isA<RunServiceException>().having((e) => e.code, 'code', 'invalid_param')),
    );
  });
}
