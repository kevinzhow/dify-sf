import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/detail_pages.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart' show VariableInspectServices;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';

/// Protocol 1.13: with a server runtime, single runs (and last runs) of the node types it runs go to the server; the
/// mock runtime keeps everything else. Without one, the mock alone (as before). Protocol 1.14: whole draft runs of
/// graphs the server runs, their stop, history and records, and the variable inspect panel's draft variables.

const _graph = StaticRunGraph(
  nodes: [
    RunGraphNode(id: 'start', type: 'start'),
    RunGraphNode(id: 'llm', type: 'llm'),
    RunGraphNode(id: 'code', type: 'code'),
  ],
);

class _Token implements TokenProvider {
  @override
  String? get accessToken => 't';
  @override
  Future<bool> refresh({String? failedToken}) async => false;
}

class _Backend extends DemoBackend {
  _Backend({super.server}) : super(withBo: false);
  @override
  Future<DocMeta> docMeta(String docId) async => const DocMeta(appMode: 'workflow', appName: 'App');
}

// A remote product session with an in-memory transport, without the explicit demo marker.
class _RemoteBackend implements Backend {
  _RemoteBackend(this.inner);
  final _Backend inner;
  @override
  String get label => 'remote fixture';
  @override
  bool get supportsDifyDsl => inner.supportsDifyDsl;
  @override
  Future<String> prepare(String id, {required bool create}) => inner.prepare(id, create: create);
  @override
  Future<String> createDocument() => inner.createDocument();
  @override
  Future<String> importDifyDsl(String yaml) => inner.importDifyDsl(yaml);
  @override
  Future<String> exportDifyDsl(String id, {bool includeSecret = false}) =>
      inner.exportDifyDsl(id, includeSecret: includeSecret);
  @override
  Future<DocMeta> docMeta(String id) => inner.docMeta(id);
  @override
  Future<ReplaceResult> replaceDifyDsl(String id, String yaml, CollabSession session, {bool confirm = false}) =>
      inner.replaceDifyDsl(id, yaml, session, confirm: confirm);
  @override
  Future<OpenedSession> openSession(String id, {String? clientId, required bool journaled, String? displayName}) =>
      inner.openSession(id, clientId: clientId, journaled: journaled, displayName: displayName);
}

class _ContainerFallback extends MockWorkflowRunService {
  _ContainerFallback() : super(graph: () => _graph);
  final containers = <String>[];
  @override
  Stream<RunEvent> iterationSingleNodeRun(String nodeId, Map<String, Object?> body) {
    containers.add('iteration:$nodeId');
    return const Stream.empty();
  }

  @override
  Stream<RunEvent> loopSingleNodeRun(String nodeId, Map<String, Object?> body) {
    containers.add('loop:$nodeId');
    return const Stream.empty();
  }
}

FakeServer _server() => FakeServer(
  initial: Document(
    nodes: [
      const Node(id: 'start', type: 'start', title: 'Start', x: 80, y: 120),
      Node(
        id: 'llm',
        type: 'llm',
        title: 'Ask',
        x: 380,
        y: 120,
        config: {
          'model': const VMap({'provider': VString('openai'), 'name': VString('gpt-4o')}),
        },
      ),
      const Node(
        id: 'code',
        type: 'code',
        title: 'Code',
        x: 680,
        y: 120,
        config: {'language': VString('python3'), 'code': VString('def main():\n    return {}')},
      ),
    ],
    edges: const [
      Edge(id: 'e1', source: 'start', target: 'llm'),
      Edge(id: 'e2', source: 'llm', target: 'code'),
    ],
  ),
);

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  for (var i = 0; i < d.inMilliseconds ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('ServerRunService, protocol 1.15 container single runs', () {
    late FakeWorkflowRunApi api;
    late _ContainerFallback fallback;
    ServerRunService make(Set<String> supported) => ServerRunService(
      runtime: ServerWorkflowRuntime(api: api, singleNodeRun: supported),
      appId: 'app',
      fallback: fallback,
      nodeTypeOf: (id) => id,
    );
    setUp(() {
      api = FakeWorkflowRunApi();
      fallback = _ContainerFallback();
    });
    test('advertised containers go to their server endpoints and stop stays on the server', () async {
      final service = make({'iteration', 'loop'});
      final body = <String, Object?>{
        'inputs': {
          'iteration.input_selector': [1, 2],
        },
      };
      final iteration = await service.iterationSingleNodeRun('iteration', body).toList();
      final loop = await service.loopSingleNodeRun('loop', {'inputs': <String, Object?>{}}).toList();
      expect(iteration.first, isA<WorkflowStartedEvent>());
      expect(loop.last, isA<WorkflowFinishedEvent>());
      expect(api.calls.map((c) => (c.op, c.nodeId)), [('iteration-run', 'iteration'), ('loop-run', 'loop')]);
      expect(api.calls.first.body, body);
      await service.stopWorkflowRun(iteration.first.taskId!);
      await service.stopWorkflowRun(loop.first.taskId!);
      expect(api.stopped, [iteration.first.taskId, loop.first.taskId]);
      expect(fallback.containers, isEmpty);
    });
    test('older capability lists keep both container operations on the stand-in', () async {
      final service = make({'llm'});
      await service.iterationSingleNodeRun('iteration', {'inputs': <String, Object?>{}}).drain<void>();
      await service.loopSingleNodeRun('loop', {'inputs': <String, Object?>{}}).drain<void>();
      expect(api.calls, isEmpty);
      expect(fallback.containers, ['iteration:iteration', 'loop:loop']);
    });
    test('container refusals retain the server message instead of falling back', () async {
      api.draftRunEvents = (_, _, _) => FakeWorkflowRunApi.refuse('invalid_param', 'missing list');
      await expectLater(
        make({'iteration'}).iterationSingleNodeRun('iteration', {'inputs': <String, Object?>{}}).toList(),
        throwsA(
          isA<RunServiceException>()
              .having((e) => e.code, 'code', 'invalid_param')
              .having((e) => e.message, 'message', 'missing list'),
        ),
      );
      expect(fallback.containers, isEmpty);
    });
  });
  group('ServerRunService, protocol 1.16 human input', () {
    late FakeWorkflowRunApi api;
    late MockWorkflowRunService mock;
    ServerRunService make({required bool humanInput}) => ServerRunService(
      runtime: ServerWorkflowRuntime(api: api, singleNodeRun: const {'llm'}, humanInput: humanInput),
      appId: 'app-1',
      fallback: mock,
      nodeTypeOf: (id) => id,
    );
    setUp(() {
      api = FakeWorkflowRunApi();
      api.humanInputForms['t1'] = {'form_id': 'h1'};
      api.humanInputEvents['r1'] = [
        {
          'event': 'human_input_form_filled',
          'workflow_run_id': 'r1',
          'data': {'node_id': 'h1', 'node_title': 'Approve'},
        },
        {
          'event': 'workflow_finished',
          'workflow_run_id': 'r1',
          'data': {'status': 'succeeded'},
        },
      ];
      mock = MockWorkflowRunService(
        graph: () => _graph,
        scenario: const MockRunScenario(stepDelay: Duration.zero),
      );
    });

    test('with the capability the answer goes to the server and the reconnect streams its frames', () async {
      final service = make(humanInput: true);
      await service.submitHumanInputForm('t1', {
        'inputs': {'note': 'ok'},
        'action': 'approve',
      });
      expect(api.humanInputAnswers['t1'], {
        'inputs': {'note': 'ok'},
        'action': 'approve',
      });
      final events = await service.workflowEvents('r1').toList();
      expect(events.map((e) => e.runtimeType), [HumanInputFormFilledEvent, WorkflowFinishedEvent]);
      // Dify's `handleResume` URL: a snapshot of the paused run, kept open across the resume.
      expect(api.reconnects.single, (runId: 'r1', includeStateSnapshot: true, continueOnPause: true));
    });

    test('without it both stay on the stand-in', () async {
      final service = make(humanInput: false);
      // The stand-in's answer to an unknown token: it never went to the server.
      await expectLater(
        service.submitHumanInputForm('t1', {'inputs': const {}, 'action': 'approve'}),
        throwsA(isA<RunServiceException>()),
      );
      expect(api.humanInputAnswers, isEmpty);
      expect(api.reconnects, isEmpty);
      expect(await service.workflowEvents('r1').toList(), isEmpty);
    });

    test('a refusal keeps the server\'s message and does not fall back', () async {
      final service = make(humanInput: true);
      await expectLater(
        service.submitHumanInputForm('nope', {'inputs': const {}, 'action': 'approve'}),
        throwsA(isA<RunServiceException>().having((e) => e.code, 'code', 'not_found')),
      );
      expect(api.humanInputAnswers, isEmpty);
    });
  });

  group('ServerRunService', () {
    late FakeWorkflowRunApi api;
    late MockWorkflowRunService mock;
    late ServerRunService service;
    setUp(() {
      api = FakeWorkflowRunApi();
      mock = MockWorkflowRunService(
        graph: () => _graph,
        scenario: const MockRunScenario(stepDelay: Duration.zero),
      );
      service = ServerRunService(
        runtime: ServerWorkflowRuntime(api: api, singleNodeRun: const {'llm'}),
        appId: 'app-1',
        fallback: mock,
        nodeTypeOf: (id) => _graph.nodes.where((n) => n.id == id).firstOrNull?.type,
      );
    });

    test('llm single runs and last runs go to the server, other nodes to the mock', () async {
      final r = await service.singleNodeRun('llm', {
        'inputs': {'#start.query#': 'hi'},
      });
      expect(r['outputs'], {'text': 'fake run of llm'});
      expect(api.calls.single.appId, 'app-1');
      expect(api.calls.single.body, {
        'inputs': {'#start.query#': 'hi'},
      });
      expect(await service.fetchNodeLastRun('llm'), r);

      final code = await service.singleNodeRun('code', {'inputs': <String, Object?>{}});
      expect(code['node_id'], 'code');
      expect(await service.fetchNodeLastRun('code'), isNotNull);
      expect(await service.fetchNodeLastRun('unknown'), isNull);
      expect(api.calls.map((c) => (c.op, c.nodeId)), [('run', 'llm'), ('last-run', 'llm')]);
    });

    test('the server\'s refusals are run errors with its message', () async {
      api.run = (_, _, _) =>
          FakeWorkflowRunApi.refuse('invalid_param', 'Variable key llm.#start.q# not found in user inputs.');
      await expectLater(
        service.singleNodeRun('llm', {'inputs': <String, Object?>{}}),
        throwsA(
          isA<RunServiceException>()
              .having((e) => e.message, 'message', 'Variable key llm.#start.q# not found in user inputs.')
              .having((e) => e.code, 'code', 'invalid_param'),
        ),
      );
    });
  });

  group('ServerRunService, protocol 1.14', () {
    late FakeWorkflowRunApi api;
    late MockWorkflowRunService mock;
    var types = <String>['start', 'llm', 'code'];
    ServerRunService make({Set<String> draftRun = const {'start', 'llm', 'code', 'end'}}) => ServerRunService(
      runtime: ServerWorkflowRuntime(api: api, singleNodeRun: const {'llm', 'code'}, draftRun: draftRun),
      appId: 'app-1',
      fallback: mock,
      nodeTypeOf: (id) => _graph.nodes.where((n) => n.id == id).firstOrNull?.type,
      graphNodeTypes: () => types,
    );
    setUp(() {
      api = FakeWorkflowRunApi();
      mock = MockWorkflowRunService(
        graph: () => _graph,
        scenario: const MockRunScenario(stepDelay: Duration.zero),
      );
      types = ['start', 'llm', 'code'];
    });

    test('a graph the server runs is run there: Dify\'s events, stop, history and records', () async {
      final service = make();
      expect(service.draftRunsOnServer, isTrue);
      final events = await service
          .runWorkflowDraft(
            const WorkflowDraftRunRequest(
              body: {
                'inputs': {'query': 'hi'},
                'files': <Object?>[],
              },
            ),
          )
          .toList();
      expect(events.first, isA<WorkflowStartedEvent>());
      expect(events.last, isA<WorkflowFinishedEvent>());
      expect((events.last as WorkflowFinishedEvent).status, 'succeeded');
      expect(api.calls.single.op, 'draft-run');
      expect(api.calls.single.body, {
        'inputs': {'query': 'hi'},
        'files': <Object?>[],
      });
      final runId = events.first.workflowRunId!;
      await service.stopWorkflowRun(runId);
      expect(api.stopped, [runId]);
      final history = await service.fetchWorkflowRunHistory();
      expect(history.first['id'], runId);
      expect((await service.fetchRunDetail(runId))['status'], 'succeeded');
    });

    test('a graph with a node type the server does not run stays on the stand-in', () async {
      types = ['start', 'iteration', 'code'];
      final service = make();
      expect(service.draftRunsOnServer, isFalse);
      final events = await service
          .runWorkflowDraft(const WorkflowDraftRunRequest(body: {'inputs': <String, Object?>{}}))
          .toList();
      expect(events.whereType<WorkflowFinishedEvent>(), isNotEmpty);
      expect(api.calls, isEmpty);
      // A 1.13 server runs no drafts.
      types = ['start', 'llm'];
      expect(make(draftRun: const {}).draftRunsOnServer, isFalse);
    });

    test('the server\'s refusal of a draft run is a run error', () async {
      api.draftRunEvents = (_, _, _) =>
          FakeWorkflowRunApi.refuse('unsupported_node_type', 'Node type tool is not supported');
      await expectLater(
        make().runWorkflowDraft(const WorkflowDraftRunRequest(body: {'inputs': <String, Object?>{}})).toList(),
        throwsA(isA<RunServiceException>().having((e) => e.code, 'code', 'unsupported_node_type')),
      );
    });

    test('the variable inspect panel reads and edits the server\'s draft variables', () async {
      api.variables['v1'] = {
        'id': 'v1',
        'type': 'node',
        'name': 'text',
        'selector': ['llm', 'text'],
        'node_id': 'llm',
        'value_type': 'string',
        'value': 'hello',
        'edited': false,
      };
      api.variables['s1'] = {
        'id': 's1',
        'type': 'sys',
        'name': 'query',
        'selector': ['sys', 'query'],
        'value': 'q',
      };
      final VariableInspectServices inspect = ServerInspectServices(api: api, appId: 'app-1');
      expect((await inspect.fetchAllInspectVars()).map((v) => v['id']), ['v1']);
      expect((await inspect.fetchNodeInspectVars('llm'))!.single['value'], 'hello');
      expect((await inspect.fetchSystemVars()).single['name'], 'query');
      await inspect.editInspectVar('v1', 'changed');
      expect(api.variables['v1']!['value'], 'changed');
      expect(api.variables['v1']!['edited'], isTrue);
      expect((await inspect.resetToLastRunValue('v1'))!['edited'], isFalse);
      await inspect.deleteNodeInspectVars('llm');
      expect(api.variables.containsKey('v1'), isFalse);
      await inspect.deleteAllInspectVars();
      expect(api.variables, isEmpty);
    });
  });

  test('the app detail services offer the runtime only when the server announces one', () {
    final server = Uri.parse('http://localhost:8080');
    final auth = _Token();
    expect(httpAppDetailServices(server, auth).containsKey(ServerWorkflowRuntime), isFalse);
    final features = SystemFeatures.fromJson({
      'workflow_runtime': {
        'protocol_version': '1.14',
        'single_node_run': ['llm'],
        'draft_run': ['start', 'llm', 'end'],
      },
    });
    final runtime =
        httpAppDetailServices(server, auth, features: features)[ServerWorkflowRuntime]! as ServerWorkflowRuntime;
    expect(runtime.singleNodeRun, {'llm'});
    expect(runtime.runsDrafts, isTrue);
    expect(runtime.draftRun, {'start', 'llm', 'end'});
    expect(runtime.api, isA<HttpWorkflowRunApi>());
  });

  Future<(_Backend, WorkflowRunScope)> open(
    WidgetTester t, {
    ServerWorkflowRuntime? runtime,
    bool remote = false,
  }) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final backend = _Backend(server: _server());
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(
          backend: remote ? _RemoteBackend(backend) : backend,
          docId: 'app-1',
          clientId: 'me-abc123',
          journaled: false,
          serverRuntime: runtime,
        ),
      ),
    );
    await _settle(t);
    return (backend, WorkflowRunScope.of(t.element(find.byKey(const ValueKey('node-start')))));
  }

  Future<void> close(WidgetTester t, DemoBackend backend) async {
    await t.pumpWidget(const SizedBox());
    await backend.dispose();
    await t.pump(const Duration(seconds: 20));
  }

  testWidgets('in the editor: the LLM node runs on the server, the code node on the mock', (t) async {
    final api = FakeWorkflowRunApi();
    final (backend, scope) = await open(
      t,
      runtime: ServerWorkflowRuntime(api: api, singleNodeRun: const {'llm'}),
    );
    expect(scope.service, isA<ServerRunService>());
    ((scope.service as ServerRunService).fallback as MockWorkflowRunService).scenario = const MockRunScenario(
      stepDelay: Duration.zero,
    );
    final opsBefore = backend.server.head;

    final llm = scope.singleRunOf('llm');
    await llm.handleRun({'#start.query#': 'hello'});
    await _settle(t, const Duration(milliseconds: 500));
    expect(api.calls.first.op, 'run');
    expect(api.calls.first.appId, 'app-1');
    expect(api.calls.first.body, {
      'inputs': {'#start.query#': 'hello'},
    });
    // As in Dify, the result shows as the node's last run (read from the server).
    await llm.fetchLastRun();
    expect(llm.lastRun?['outputs'], {'text': 'fake run of llm'});

    final calls = api.calls.length;
    final code = scope.singleRunOf('code');
    unawaited(code.handleRun(const {}));
    await _settle(t, const Duration(seconds: 1));
    await code.fetchLastRun();
    expect(api.calls.length, calls);
    expect(code.lastRun?['node_id'], 'code');
    // Runs are not edits.
    expect(backend.server.head, opsBefore);
    await close(t, backend);
  });

  testWidgets('without a server runtime the mock runs everything', (t) async {
    final (backend, scope) = await open(t);
    expect(scope.service, isA<MockWorkflowRunService>());
    await close(t, backend);
  });
  testWidgets('remote sessions without runtime capability refuse execution instead of simulating success', (t) async {
    final (backend, scope) = await open(t, remote: true);
    try {
      expect(scope.service, isNot(isA<MockWorkflowRunService>()));
      await expectLater(
        scope.service.singleNodeRun('llm', {'inputs': <String, Object?>{}}),
        throwsA(isA<RunServiceException>()),
      );
      await expectLater(
        scope.service.runWorkflowDraft(const WorkflowDraftRunRequest()),
        emitsError(isA<RunServiceException>()),
      );
      expect(await scope.service.fetchWorkflowRunHistory(), isEmpty);
      expect(backend.server.head, 0);
    } finally {
      await close(t, backend);
    }
  });

  testWidgets('remote unsupported nodes, mixed graphs and chat never fall back to mock records', (t) async {
    final api = FakeWorkflowRunApi();
    final (backend, scope) = await open(
      t,
      remote: true,
      runtime: ServerWorkflowRuntime(api: api, singleNodeRun: const {'llm'}, draftRun: const {'start', 'llm', 'end'}),
    );
    try {
      final service = scope.service as ServerRunService;
      expect(service.fallback, isNot(isA<MockWorkflowRunService>()));
      await expectLater(
        service.singleNodeRun('code', {'inputs': <String, Object?>{}}),
        throwsA(isA<RunServiceException>()),
      );
      await expectLater(
        service.runWorkflowDraft(const WorkflowDraftRunRequest()),
        emitsError(isA<RunServiceException>()),
      );
      await expectLater(
        service.sendChatMessage(const ChatMessageRequest({'query': 'hello'})),
        emitsError(isA<RunServiceException>()),
      );
      expect(api.calls, isEmpty);
      expect(await service.fetchNodeLastRun('code'), isNull);
      expect(await service.fetchWorkflowRunHistory(), isEmpty);
      expect(backend.server.head, 0);
    } finally {
      await close(t, backend);
    }
  });
}
