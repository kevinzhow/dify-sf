import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A human input form definition (protocol 1.16: Dify's FormDefinition plus `expiration_time`).
const _formJSON = {
  'form_id': 'n1',
  'form_content': 'Approve?',
  'inputs': <Object?>[],
  'actions': <Object?>[],
  'rendered_content': 'Approve?',
  'default_values': <String, Object?>{},
  'node_title': 'Human Input',
  'display_in_ui': true,
  'expiration_time': 1760000000,
};

/// Protocol 1.13: the workflow runtime's single node run and last run, and its discovery in `system-features`.
void main() {
  test('1.15 container single runs stream dedicated encoded paths and preserve inputs/refusals', () async {
    final paths = <String>[];
    final bodies = <Map<String, Object?>>[];
    final api = HttpWorkflowRunApi(
      Uri.parse('http://h:1/'),
      client: MockClient.streaming((req, body) async {
        paths.add(req.url.toString());
        bodies.add(jsonDecode(await utf8.decoder.bind(body).join()) as Map<String, Object?>);
        if (req.url.path.contains('/refused/')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"error":{"code":"invalid_param","message":"missing list"}}')),
            400,
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode('event: ping\n\ndata: {"event":"workflow_started","task_id":"r","data":{"id":"r"}}\n\n'),
            utf8.encode('data: {"event":"workflow_finished","data":{"status":"succeeded"}}\n\n'),
          ]),
          200,
        );
      }),
    );
    final body = <String, Object?>{
      'inputs': {
        'it.input_selector': ['hé'],
      },
    };
    expect((await api.iterationSingleRun('app x', 'node/x', body).toList()).map((e) => e['event']), [
      'workflow_started',
      'workflow_finished',
    ]);
    expect((await api.loopSingleRun('app x', 'node/x', body).toList()).last['event'], 'workflow_finished');
    expect(paths, [
      'http://h:1/v1/apps/app%20x/workflows/draft/iteration/nodes/node%2Fx/run',
      'http://h:1/v1/apps/app%20x/workflows/draft/loop/nodes/node%2Fx/run',
    ]);
    expect(bodies, [body, body]);
    await expectLater(
      api.loopSingleRun('refused', 'node', body).toList(),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'invalid_param')),
    );
  });
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
      final execution = {
        'id': 'e1',
        'status': 'succeeded',
        'outputs': {'text': 'hi'},
      };
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
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'not_found', 'message': 'last run not found'},
        }),
        404,
      );
      expect(await api.nodeLastRun('a', 'llm'), isNull);
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'app_not_found', 'message': 'wrong mode'},
        }),
        404,
      );
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
      answer = (_) =>
          http.Response(jsonEncode({'id': 'e2', 'status': 'failed', 'error': 'slow down', 'outputs': null}), 200);
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

  group('Protocol 1.14: draft runs and draft variables', () {
    test('workflow_runtime.draft_run is parsed', () {
      final f = SystemFeatures.fromJson({
        'is_email_setup': false,
        'workflow_runtime': {
          'protocol_version': '1.14',
          'single_node_run': ['llm', 'code'],
          'draft_run': ['start', 'end', 'llm'],
        },
      });
      expect(f.workflowRuntime!.draftRun, {'start', 'end', 'llm'});
      expect(WorkflowRuntimeFeatures.fromJson({'protocol_version': '1.13'})!.draftRun, isEmpty);
    });

    test('the draft run stream yields Dify\'s payloads and drops pings; refusals throw', () async {
      final sent = <http.BaseRequest>[];
      final api = HttpWorkflowRunApi(
        Uri.parse('http://h:1/'),
        client: MockClient.streaming((req, body) async {
          sent.add(req);
          if (req.url.path.endsWith('/nope/workflows/draft/run')) {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'error': {'code': 'unsupported_node_type', 'message': 'tool'},
                  }),
                ),
              ),
              400,
            );
          }
          final frames = [
            'data: {"event":"workflow_started","workflow_run_id":"r","task_id":"r","data":{"id":"r"}}\n\n',
            'event: ping\n\n',
            'data: {"event":"text_chunk","workflow_run_id":"r","task_id":"r","data":{"text":"h\u00e9"',
            ',"from_variable_selector":["llm","text"]}}\n\n',
            'data: {"event":"workflow_finished","workflow_run_id":"r","task_id":"r","data":{"status":"succeeded"}}\n\n',
          ];
          return http.StreamedResponse(Stream.fromIterable(frames.map(utf8.encode)), 200);
        }),
      );
      final events = await api.draftRun('a', {
        'inputs': {'q': 'x'},
        'files': <Object?>[],
      }).toList();
      expect(events.map((e) => e['event']), ['workflow_started', 'text_chunk', 'workflow_finished']);
      expect((events[1]['data']! as Map)['text'], 'hé');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/v1/apps/a/workflows/draft/run');
      await expectLater(
        api.draftRun('nope', {'inputs': <String, Object?>{}}).toList(),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'unsupported_node_type')),
      );
    });

    test('history, records, stop and draft variables use Dify\'s paths', () async {
      final sent = <http.Request>[];
      final api = HttpWorkflowRunApi(
        Uri.parse('http://h:1/'),
        client: MockClient((req) async {
          sent.add(req);
          final p = req.url.path;
          if (p.endsWith('/node-executions')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'e'},
                ],
              }),
              200,
            );
          }
          if (p.endsWith('/reset')) return http.Response('', 204);
          if (req.method == 'DELETE') return http.Response('', 204);
          if (p.endsWith('/variables') && p.contains('/nodes/')) {
            return http.Response(
              jsonEncode({
                'items': [
                  {'id': 'v'},
                ],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'ok': true, 'items': <Object?>[]}), 200);
        }),
      );
      await api.runHistory('a', lastId: 'r1', limit: 5);
      expect(sent.last.url.toString(), 'http://h:1/v1/apps/a/workflow-runs?limit=5&last_id=r1');
      await api.runDetail('a', 'r1');
      expect(sent.last.url.path, '/v1/apps/a/workflow-runs/r1');
      expect(await api.runNodeExecutions('a', 'r1'), [
        {'id': 'e'},
      ]);
      await api.stopRun('a', 't 1');
      expect(sent.last.url.path, '/v1/apps/a/workflow-runs/tasks/t%201/stop');
      expect(sent.last.method, 'POST');
      await api.draftVariables('a', page: 2, limit: 10);
      expect(sent.last.url.toString(), 'http://h:1/v1/apps/a/workflows/draft/variables?page=2&limit=10');
      expect(await api.nodeVariables('a', 'llm'), [
        {'id': 'v'},
      ]);
      expect(sent.last.url.path, '/v1/apps/a/workflows/draft/nodes/llm/variables');
      await api.draftVariablesOfKind('a', 'system');
      expect(sent.last.url.path, '/v1/apps/a/workflows/draft/system-variables');
      await api.updateDraftVariable('a', 'v1', {'value': 3});
      expect(sent.last.method, 'PATCH');
      expect(jsonDecode(sent.last.body), {'value': 3});
      expect(await api.resetDraftVariable('a', 'v1'), isNull);
      expect(sent.last.url.path, '/v1/apps/a/workflows/draft/variables/v1/reset');
      await api.deleteDraftVariables('a', nodeId: 'llm');
      expect(sent.last.url.path, '/v1/apps/a/workflows/draft/nodes/llm/variables');
      await api.deleteDraftVariables('a');
      expect(sent.last.url.path, '/v1/apps/a/workflows/draft/variables');
    });

    test('the fake records runs in its history', () async {
      final fake = FakeWorkflowRunApi();
      final events = await fake.draftRun('a', {
        'inputs': {'q': 1},
      }).toList();
      expect(events.last['event'], 'workflow_finished');
      final history = await fake.runHistory('a');
      expect((history['data']! as List).single, containsPair('status', 'succeeded'));
    });
  });

  group('Protocol 1.16: human input', () {
    test('workflow_runtime.human_input is parsed, false when the server does not say', () {
      final yes = WorkflowRuntimeFeatures.fromJson({'protocol_version': '1.16', 'human_input': true})!;
      expect(yes.humanInput, isTrue);
      expect(yes.humanInputEmail, isFalse, reason: 'web support never enables outbound mail implicitly');
      expect(WorkflowRuntimeFeatures.fromJson({'human_input_email': true})!.humanInputEmail, isTrue);
      expect(WorkflowRuntimeFeatures.fromJson({'protocol_version': '1.15'})!.humanInput, isFalse);
      expect(WorkflowRuntimeFeatures.fromJson({'protocol_version': '1.16', 'human_input': 'yes'})!.humanInput, isFalse);
    });

    test('the form, its submission, the reconnect and the node form use Dify\'s paths', () async {
      final sent = <http.Request>[];
      final api = HttpWorkflowRunApi(
        Uri.parse('http://h:1/'),
        client: MockClient.streaming((req, body) async {
          sent.add(req as http.Request);
          if (req.method == 'GET' && req.url.path.contains('/workflow/')) {
            return http.StreamedResponse(
              Stream.fromIterable([
                utf8.encode('data: {"event":"workflow_paused","workflow_run_id":"r","data":{"reasons":[]}}\n\n'),
                utf8.encode('data: {"event":"workflow_finished","data":{"status":"succeeded"}}\n\n'),
              ]),
              200,
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(req.url.path.contains('/form/human_input/') ? _formJSON : {}))),
            200,
          );
        }),
      );
      final form = await api.humanInputForm('t 1');
      expect(sent.last.method, 'GET');
      expect(sent.last.url.toString(), 'http://h:1/v1/form/human_input/t%201');
      expect(form['form_id'], 'n1');
      await api.submitHumanInputForm('t 1', {
        'inputs': {'note': 'ok'},
        'action': 'approve',
      });
      expect(sent.last.method, 'POST');
      expect(sent.last.url.path, '/v1/form/human_input/t%201');
      expect(jsonDecode(sent.last.body), {
        'inputs': {'note': 'ok'},
        'action': 'approve',
      });
      final events = await api.workflowEvents('run 1').toList();
      expect(sent.last.method, 'GET');
      expect(
        sent.last.url.toString(),
        'http://h:1/v1/workflow/run%201/events?include_state_snapshot=true&continue_on_pause=true',
      );
      expect(events.map((e) => e['event']), ['workflow_paused', 'workflow_finished']);
      await api.workflowEvents('r', includeStateSnapshot: false, continueOnPause: false).toList();
      expect(
        sent.last.url.toString(),
        'http://h:1/v1/workflow/r/events?include_state_snapshot=false&continue_on_pause=false',
      );
      const url = '/apps/a/workflows/draft/human-input/nodes/n1/form';
      await api.humanInputFormPreview(url, {
        'inputs': {'#start.q#': 'hi'},
      });
      expect(sent.last.method, 'POST');
      expect(sent.last.url.path, '/v1$url/preview');
      await api.humanInputFormRun(url, {
        'inputs': {'#start.q#': 'hi'},
        'form_inputs': {'note': 'ok'},
        'action': 'approve',
      });
      expect(sent.last.url.path, '/v1$url/run');
      await api.humanInputDeliveryTest('a', 'n 1', {'delivery_method_id': 'd1'});
      expect(sent.last.url.path, '/v1/apps/a/workflows/draft/human-input/nodes/n%201/delivery-test');
    });

    test('a submitted or expired form is 412 with Dify\'s code', () async {
      final api = HttpWorkflowRunApi(
        Uri.parse('http://h:1/'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 'human_input_form_submitted', 'message': 'this form has been submitted'},
            }),
            412,
          ),
        ),
      );
      await expectLater(
        api.humanInputForm('t'),
        throwsA(
          isA<TransportException>()
              .having((e) => e.code, 'code', 'human_input_form_submitted')
              .having((e) => e.statusCode, 'status', 412),
        ),
      );
      await expectLater(
        api.submitHumanInputForm('t', {'inputs': {}, 'action': 'approve'}),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'human_input_form_submitted')),
      );
    });

    test('the fake answers its forms and records answers and reconnects', () async {
      final fake = FakeWorkflowRunApi();
      fake.humanInputForms['t1'] = {'form_id': 'n1', 'form_content': 'Approve?'};
      expect((await fake.humanInputForm('t1'))['form_id'], 'n1');
      await fake.submitHumanInputForm('t1', {
        'inputs': {'note': 'ok'},
        'action': 'approve',
      });
      expect(fake.humanInputAnswers['t1'], containsPair('action', 'approve'));
      fake.humanInputEvents['r1'] = [
        {'event': 'workflow_finished', 'data': {'status': 'succeeded'}},
      ];
      expect((await fake.workflowEvents('r1').toList()).single['event'], 'workflow_finished');
      expect(fake.reconnects.single.continueOnPause, isTrue);
      await expectLater(fake.humanInputForm('nope'), throwsA(isA<TransportException>()));
    });
  });
}
