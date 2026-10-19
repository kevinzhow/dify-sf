/// Protocol 1.13 against a real server with a model runtime: an LLM node's single run and its last run through
/// [HttpWorkflowRunApi], the server running the node through Dify's plugin daemon and the e2e stub LLM. Runs only when
/// `DIFYSF_RUNTIME_URL` is set (the dify-sf repository's `server/run-runtime-e2e.sh` does), e.g.
///
///     DIFYSF_RUNTIME_URL=http://127.0.0.1:18090 dart test test/runtime_e2e_test.dart
///
/// The server must reach the stub at `DIFYSF_STUB_ENDPOINT` (default `http://llmstub:8000/v1`, as its plugin daemon sees
/// it). Signs in as `DIFYSF_EMAIL` / `DIFYSF_PASSWORD` (default `owner@example.com` / `owner-pass-1`), installing that
/// account as the owner on a fresh server.
library;

import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

final String? _url = Platform.environment['DIFYSF_RUNTIME_URL'];
final String _email = Platform.environment['DIFYSF_EMAIL'] ?? 'owner@example.com';
final String _password = Platform.environment['DIFYSF_PASSWORD'] ?? 'owner-pass-1';
final String _stub = Platform.environment['DIFYSF_STUB_ENDPOINT'] ?? 'http://llmstub:8000/v1';

const _yaml = '''
app:
  mode: workflow
  name: runtime-e2e-dart
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - id: start-llm
      source: start
      sourceHandle: source
      target: llm
      targetHandle: target
    nodes:
    - id: start
      data:
        title: Start
        type: start
        variables:
        - label: q
          required: true
          type: text-input
          variable: q
    - id: llm
      data:
        title: Ask
        type: llm
        model:
          provider: langgenius/openai_api_compatible/openai_api_compatible
          name: stub-chat
          mode: chat
          completion_params:
            temperature: 0
        prompt_template:
        - role: user
          text: 'Q: {{#start.q#}}'
        context:
          enabled: false
          variable_selector: []
        vision:
          enabled: false
''';

void main() {
  if (_url == null) {
    test('runtime e2e (set DIFYSF_RUNTIME_URL to run)', () {}, skip: 'DIFYSF_RUNTIME_URL is not set');
    return;
  }
  final base = Uri.parse(_url!);

  test('1.13: an LLM node runs on the server (plugin daemon + stub LLM) and becomes its last run', () async {
    final owner = AuthSession(api: HttpAuthApi(base));
    if (await owner.api.setupStatus() == SetupStatus.notStarted) {
      await owner.setup(email: _email, name: 'Runtime E2E', password: _password);
    } else {
      await owner.login(email: _email, password: _password);
    }
    final features = await owner.api.systemFeatures();
    expect(features.workflowRuntime?.protocolVersion, '1.13');
    expect(features.workflowRuntime?.singleNodeRun, contains('llm'));

    final models = HttpModelProvidersApi(base, auth: owner);
    await models.createModelCredential(
      'langgenius/openai_api_compatible/openai_api_compatible',
      model: 'stub-chat',
      modelType: 'llm',
      name: 'dart-e2e-${DateTime.now().microsecondsSinceEpoch}',
      credentials: {
        'endpoint_url': _stub,
        'api_key': 'sk-stub-not-a-real-key',
        'mode': 'chat',
        'context_size': '4096',
        'max_tokens_to_sample': '4096',
      },
    );
    final apps = HttpAppsApi(base, auth: owner);
    final imported = await apps.importDsl(_yaml);
    final app = imported.appId!;

    final runs = HttpWorkflowRunApi(base, auth: owner);
    final run = await runs.singleNodeRun(app, 'llm', {
      'inputs': {'#start.q#': '[[stub:fixed]]'},
    });
    expect(run['status'], 'succeeded', reason: '$run');
    expect((run['outputs']! as Map)['text'], 'This is the fixed stub answer.');
    expect(run['node_type'], 'llm');
    expect((run['created_by_account']! as Map)['email'], _email);

    final last = await runs.nodeLastRun(app, 'llm');
    expect(last?['id'], run['id']);
    expect(await runs.nodeLastRun(app, 'start'), isNull);

    // A node type the server does not run yet: refused with the server's code.
    await expectLater(
      runs.singleNodeRun(app, 'start', {'inputs': <String, Object?>{}}),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'unsupported_node_type')),
    );
    stdout.writeln('runtime e2e (dart): ${(run['outputs']! as Map)['text']} in ${run['elapsed_time']} s');
  });
}
