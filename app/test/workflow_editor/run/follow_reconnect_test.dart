// The run panel's follow across a lost connection (protocol 1.16, against a real server the harness restarts): the
// controller's `resume` used to open one stream, and a server restart made `onError` mark the run failed; the follow now
// reconnects, and the panel must show the run's real end. Runs only when `DIFYSF_RUNTIME_URL` is set.
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
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

/// start → human (approve) → end.
const _graph = StaticRunGraph(
  nodes: [
    RunGraphNode(id: 'start', type: 'start', title: 'Start', data: {'type': 'start', 'title': 'Start'}),
    RunGraphNode(id: 'human', type: 'human-input', title: 'Approve', x: 300, data: {'type': 'human-input', 'title': 'Approve'}),
    RunGraphNode(id: 'end', type: 'end', title: 'End', x: 600, data: {'type': 'end', 'title': 'End'}),
  ],
  edges: [RunGraphEdge(id: 'e1', source: 'start', target: 'human'), RunGraphEdge(id: 'e2', source: 'human', target: 'end')],
);

const _yaml = '''
app:
  mode: workflow
  name: client-follow-reconnect
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
    - {id: e2, source: human, sourceHandle: approve, target: end, targetHandle: target}
    nodes:
    - id: start
      data: {title: Start, type: start, variables: []}
    - id: human
      data:
        title: Approve
        type: human-input
        form_content: 'Approve {{#\$output.reply#}}?'
        inputs:
        - {type: paragraph, output_variable_name: reply}
        user_actions:
        - {id: approve, title: Approve it, button_style: primary}
        delivery_methods:
        - {type: webapp, enabled: true}
    - id: end
      data:
        title: End
        type: end
        outputs:
        - {variable: reply, value_selector: [human, reply]}
''';

void main() {
  if (_url == null) {
    test('follow across a restart (set DIFYSF_RUNTIME_URL to run)', () {}, skip: 'DIFYSF_RUNTIME_URL is not set');
    return;
  }
  final base = Uri.parse(_url!);

  test('a run followed across a server restart ends as succeeded in the panel, not as failed', () async {
    HttpOverrides.global = null;
    final owner = AuthSession(api: HttpAuthApi(base));
    if (await owner.api.setupStatus() == SetupStatus.notStarted) {
      await owner.setup(email: _email, name: 'Follow E2E', password: _password);
    } else {
      await owner.login(email: _email, password: _password);
    }
    final features = (await owner.api.systemFeatures()).workflowRuntime!;
    expect(features.humanInput, isTrue);
    final apps = HttpAppsApi(base, auth: owner);
    final app = (await apps.importDsl(_yaml)).appId!;
    addTearDown(() => apps.delete(app));
    final store = WorkflowStore();
    final service = ServerRunService(
      runtime: ServerWorkflowRuntime(
        api: HttpWorkflowRunApi(base, auth: owner),
        singleNodeRun: features.singleNodeRun,
        draftRun: features.draftRun,
        humanInput: features.humanInput,
      ),
      appId: app,
      fallback: MockWorkflowRunService(graph: () => _graph),
      nodeTypeOf: (id) => _graph.nodes.where((n) => n.id == id).firstOrNull?.type,
      graphNodeTypes: () => _graph.nodes.map((n) => n.type),
    );
    final errors = <String>[];
    final frames = <String>[];
    RunCallbacks record(RunCallbacks c) => c.merge(RunCallbacks(
      onNotifyError: (m, [c]) => frames.add('notify $m'),
      onWorkflowStarted: (e) => frames.add('started'),
      onWorkflowPaused: (e) => frames.add('paused'),
      onHumanInputRequired: (e) {
        frames.add('required');
        c.onHumanInputRequired?.call(e);
      },
      onHumanInputFormFilled: (e) => frames.add('filled'),
      onWorkflowFinished: (e) => frames.add('finished ${e.data['status']}'),
      onError: (m, [c]) => frames.add('error $m'),
    ));
    final run = WorkflowRunController(store: store, service: service, graph: _graph,
                                      toast: (_, m) => errors.add(m));
    String token = '';
    await run.handleRun(
      {'inputs': <String, Object?>{}},
      callback: record(RunCallbacks(onHumanInputRequired: (e) => token = e.data['form_token'] as String? ?? '')),
    );
    for (var i = 0; i < 200 && token.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(token, isNotEmpty, reason: 'the run paused at the human node: $frames');
    // The frames the caller saw, in the reason of the failing expectation below (a second follow would double them).
    // The follow is open (the pause's own stream). The harness restarts the server now: see sse_restart.md.
    // (`testWidgets` in this file installs a cache of compile-time `fromEnvironment`, so the shell variable is read here.)
    final restart = Platform.environment['FOLLOW_RESTART_COMMAND'];
    if (restart == null) {
      markTestSkipped('FOLLOW_RESTART_COMMAND is not set: see sse_restart.md');
      return;
    }
    final result = await Process.run('bash', ['-lc', restart]);
    expect(result.exitCode, 0, reason: 'the restart: ${result.stderr}');
    // Answer once the server is back: the follow must reconnect and carry the run to its real end.
    await Future<void>.delayed(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(seconds: 1));
    // The server may still be starting: the answer is retried until the new process takes it.
    var answered = false;
    for (var i = 0; i < 300 && !answered; i++) {
      try {
        await service.submitHumanInputForm(token, {'inputs': {'reply': 'after restart'}, 'action': 'approve'});
        answered = true;
      } on Object {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    expect(answered, isTrue, reason: 'the form is answered once the server is back');
    for (var i = 0; i < 600 && ['running', 'paused'].contains(resultOf(store.workflowRunningData.value ?? const {})['status']); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final state = resultOf(store.workflowRunningData.value ?? const {});

    expect(state['status'], 'succeeded',
           reason: 'the panel shows the real end of the run: $state; frames: $frames; reported: $errors');
    expect(state['outputs'], {'reply': 'after restart'});
  }, timeout: const Timeout(Duration(minutes: 5)));
}
