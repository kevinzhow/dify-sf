import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Protocol 1.13: the workflow runtime's single node run and last run, and its discovery in `system-features`.
void main() {
  group('SystemFeatures.workflowRuntime', () {
    test('parsed when present, null when absent', () {
      final f = SystemFeatures.fromJson({
        'is_email_setup': false,
        'workflow_runtime': {
          'protocol_version': '1.13',
          'single_node_run': ['llm', 7],
        },
      });
      expect(f.workflowRuntime!.protocolVersion, '1.13');
      expect(f.workflowRuntime!.singleNodeRun, {'llm'});
      expect(SystemFeatures.fromJson({'is_email_setup': true}).workflowRuntime, isNull);
      expect(SystemFeatures.none.workflowRuntime, isNull);
    });
  });

  group('HttpWorkflowRunApi', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) answer;
    late HttpWorkflowRunApi api;
    setUp(() {
      sent = [];
      answer = (_) => http.Response('{}', 200);
      api = HttpWorkflowRunApi(
        Uri.parse('http://h:1/base/'),
        client: MockClient((req) async {
          sent.add(req);
          return answer(req);
        }),
      );
    });

    test('paths, methods and bodies are Dify\'s', () async {
      final execution = {'id': 'e1', 'status': 'succeeded', 'outputs': {'text': 'hi'}};
      answer = (_) => http.Response(jsonEncode(execution), 200);
      final run = await api.singleNodeRun('app 1', 'llm/x', {
        'inputs': {'#start.q#': 'ping'},
      });
      expect(run, execution);
      expect(sent.single.method, 'POST');
      expect(sent.single.url.toString(), 'http://h:1/base/v1/apps/app%201/workflows/draft/nodes/llm%2Fx/run');
      expect(jsonDecode(sent.single.body), {
        'inputs': {'#start.q#': 'ping'},
      });
      expect(sent.single.headers['Content-Type'], startsWith('application/json'));
      expect(await api.nodeLastRun('a', 'llm'), execution);
      expect(sent.last.method, 'GET');
      expect(sent.last.url.path, '/base/v1/apps/a/workflows/draft/nodes/llm/last-run');
    });

    test('a node without a run is null; errors carry the server\'s code', () async {
      answer = (_) => http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'last run not found'}}), 404);
      expect(await api.nodeLastRun('a', 'llm'), isNull);
      answer = (_) => http.Response(jsonEncode({'error': {'code': 'app_not_found', 'message': 'wrong mode'}}), 404);
      await expectLater(
        api.nodeLastRun('a', 'llm'),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'app_not_found')),
      );
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'invalid_param', 'message': 'Variable key llm.#start.q# not found in user inputs.'},
        }),
        400,
      );
      await expectLater(
        api.singleNodeRun('a', 'llm', {'inputs': <String, Object?>{}}),
        throwsA(
          isA<TransportException>()
              .having((e) => e.code, 'code', 'invalid_param')
              .having((e) => e.message, 'message', 'Variable key llm.#start.q# not found in user inputs.')
              .having((e) => e.statusCode, 'status', 400),
        ),
      );
    });

    test('a failed node is an answer, not an error', () async {
      answer = (_) => http.Response(jsonEncode({'id': 'e2', 'status': 'failed', 'error': 'slow down', 'outputs': null}), 200);
      final r = await api.singleNodeRun('a', 'llm', {'inputs': <String, Object?>{}});
      expect(r['status'], 'failed');
      expect(r['error'], 'slow down');
    });
  });

  test('FakeWorkflowRunApi keeps last runs per node', () async {
    final api = FakeWorkflowRunApi();
    expect(await api.nodeLastRun('a', 'llm'), isNull);
    final r = await api.singleNodeRun('a', 'llm', {
      'inputs': {'x': 1},
    });
    expect(r['status'], 'succeeded');
    expect(await api.nodeLastRun('a', 'llm'), r);
    expect(api.calls.map((c) => c.op), ['last-run', 'run', 'last-run']);
  });
}
