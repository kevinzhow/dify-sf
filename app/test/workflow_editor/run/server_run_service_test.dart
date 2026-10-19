import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/detail_pages.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';

/// Protocol 1.13: with a server runtime, single runs (and last runs) of the node types it runs go to the server; the
/// mock runtime keeps everything else. Without one, the mock alone (as before).

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
    edges: const [Edge(id: 'e1', source: 'start', target: 'llm'), Edge(id: 'e2', source: 'llm', target: 'code')],
  ),
);

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  for (var i = 0; i < d.inMilliseconds ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('ServerRunService', () {
    late FakeWorkflowRunApi api;
    late MockWorkflowRunService mock;
    late ServerRunService service;
    setUp(() {
      api = FakeWorkflowRunApi();
      mock = MockWorkflowRunService(graph: () => _graph, scenario: const MockRunScenario(stepDelay: Duration.zero));
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
      api.run = (_, _, _) => FakeWorkflowRunApi.refuse('invalid_param', 'Variable key llm.#start.q# not found in user inputs.');
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

  test('the app detail services offer the runtime only when the server announces one', () {
    final server = Uri.parse('http://localhost:8080');
    final auth = _Token();
    expect(httpAppDetailServices(server, auth).containsKey(ServerWorkflowRuntime), isFalse);
    final features = SystemFeatures.fromJson({
      'workflow_runtime': {
        'protocol_version': '1.13',
        'single_node_run': ['llm'],
      },
    });
    final runtime = httpAppDetailServices(server, auth, features: features)[ServerWorkflowRuntime]! as ServerWorkflowRuntime;
    expect(runtime.singleNodeRun, {'llm'});
    expect(runtime.api, isA<HttpWorkflowRunApi>());
  });

  Future<(_Backend, WorkflowRunScope)> open(WidgetTester t, {ServerWorkflowRuntime? runtime}) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final backend = _Backend(server: _server());
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: backend, docId: 'app-1', clientId: 'me-abc123', journaled: false, serverRuntime: runtime),
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
    final (backend, scope) = await open(t, runtime: ServerWorkflowRuntime(api: api, singleNodeRun: const {'llm'}));
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
}
