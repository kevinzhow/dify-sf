// The `codex` harness style end to end: the service, the scripted gateway
// and the fake sandbox.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'view_image_test.dart' show png;

const terra = 'codex/gpt-6.1-terra';

Map<String, Object?> codexOp({
  bool shell = false,
  bool askHuman = true,
  bool viewImage = false,
  bool reportProgress = false,
  bool updatePlan = false,
  String model = terra,
  String? effort = 'xhigh',
  int maxTurns = 10,
  Map<String, Object?>? outputSchema,
  Map<String, Object?>? continuation,
  int outputAttempt = 0,
  int resumeSequence = 0,
}) {
  final o = operation(
    shell: shell,
    askHuman: askHuman,
    viewImage: viewImage,
    maxTurns: maxTurns,
    outputSchema: outputSchema,
    continuation: continuation,
    outputAttempt: outputAttempt,
    resumeSequence: resumeSequence,
  );
  o['harness_style'] = 'codex';
  final m = o['model'] as Map;
  m['name'] = model;
  m['parameters'] = {'reasoning_effort': ?effort};
  final tools = o['tools'] as Map;
  if (reportProgress) tools['report_progress'] = true;
  if (updatePlan) tools['update_plan'] = true;
  return o;
}

ScriptedCall calls(
  List<(String, String, Map<String, Object?>)> cs, {
  String? text,
}) => ScriptedCall(
  chunks: [
    ScriptedChunk(
      text: text,
      toolCalls: [
        for (final (i, (id, name, args)) in cs.indexed)
          toolCallDelta(
            index: i,
            id: id,
            name: name,
            arguments: jsonEncode(args),
          ),
      ],
    ),
    ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
  ],
);

List<Map> messagesOf(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['prompt_messages'] as List).cast<Map>();

List<String> toolNamesOf(Map<String, Object?> llmRequest) => [
  for (final t in ((llmRequest['target'] as Map)['tools'] as List? ?? const []))
    (t as Map)['name'] as String,
];

Future<(Harness, FakeSupervisor?)> start(
  List<ScriptedCall> script, {
  bool shell = false,
  void Function(FakeShellctl s)? configure,
}) async {
  FakeSupervisor? sup;
  if (shell) {
    sup = FakeSupervisor(key: testSupervisorKey, configure: configure);
    await sup.start();
  }
  final h = await Harness.start(calls: script, supervisorUrl: sup?.url);
  addTearDown(() async {
    await h.close();
    await sup?.close();
  });
  return (h, sup);
}

Future<(Map<String, Object?>, List<Sse>)> runToEnd(
  Harness h,
  Map<String, Object?> op,
) async {
  final run = await h.startOperation(op);
  final status = await h.waitEnded(run, timeout: const Duration(seconds: 20));
  return (status, await h.events(run));
}

Map<String, Object?> resultOf(Map<String, Object?> status) =>
    (status['result'] as Map).cast<String, Object?>();

/// A local directory standing in for `/workspace` for apply_patch's control
/// scripts (run by bash with the paths rewritten).
Future<(int, String)?> Function(String) localWorkspace(Directory dir) =>
    (script) async {
      const signatures = [
        'base64 -w0 <',
        "<<'DIFYSF_EOF' ||",
        'mkdir -p --',
        'rm -f --',
        'echo "dir \$l"',
      ];
      if (!signatures.any(script.contains)) return null;
      final p = await Process.start('bash', ['-s']);
      p.stdin.write(script.replaceAll("'/workspace", "'${dir.path}"));
      await p.stdin.close();
      final out = await p.stdout.transform(utf8.decoder).join();
      await p.stderr.drain<void>();
      return (await p.exitCode, out);
    };

final golden = File('test/golden/codex_first_request.json');

void main() {
  test('a plain answer: Codex layout, tools, run_started echo, effort '
      'record', () async {
    final (h, _) = await start([
      ScriptedCall.text('Done.', usage: defaultUsage(reasoning: null)),
    ]);
    final (status, events) = await runToEnd(h, codexOp());
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final result = resultOf(status);
    expect(result['candidate'], {'text': 'Done.'});
    expect(events.first.data['harness_style'], 'codex');

    final req = h.gateway.llmRequests.single;
    final m = messagesOf(req);
    expect(
      [for (final x in m) x['role']],
      ['system', 'system', 'user', 'user'],
    );
    expect(
      m[0]['content'],
      startsWith('You are Codex, an agent based on GPT-6.'),
    );
    expect(
      m[1]['content'],
      contains("You may call the external tool 'ask_human'"),
    );
    expect(m[1]['content'], isNot(contains('<permissions instructions>')));
    final context = (m[2]['content'] as List).cast<Map>();
    expect(
      context.first['data'],
      '# AGENTS.md instructions for /workspace\n\n<INSTRUCTIONS>\nYou are a '
      'helpful agent.\n</INSTRUCTIONS>',
    );
    expect(
      context.last['data'],
      startsWith('<environment_context>\n  <current_date>'),
    );
    expect(m[3]['content'], 'Plan a trip.');
    expect(toolNamesOf(req), ['ask_human']);
    expect((req['target'] as Map)['model_parameters'], {
      'reasoning_effort': 'xhigh',
    });
    expect((req['caller'] as Map).containsKey('attempt'), isFalse);

    final call = events.firstWhere((e) => e.event == 'model_call').data;
    expect(call['harness_style'], 'codex');
    expect(call['wire'], 'plugin');
    expect(call['reasoning'], {
      'effort_requested': 'xhigh',
      'effort_sent': 'xhigh',
      'effort_sent_by': 'plugin',
      'effort_echoed': null,
      'effort_echoed_null_reason':
          'the plugin wire returns no provider response object',
      'summary_sent': null,
      'encrypted_items_in': 0,
      'encrypted_items_out': 0,
      'reasoning_tokens': null,
      'reasoning_tokens_source': null,
      'reasoning_tokens_null_reason':
          'the plugin wire reports no reasoning token count (Dify LLMUsage has '
          'no such field)',
    });
    final snapshot = (result['snapshot'] as Map).cast<String, Object?>();
    expect(snapshot['harness_style'], 'codex');
    expect(snapshot['codex'], {
      'upstream': 'rust-v0.163.0',
      'model_family': 'gpt-6',
      'wire': 'plugin',
    });
    expect((snapshot['items'] as List).length, 5);
  });

  test('golden first request: shell, view_image, report_progress, declared '
      'outputs, fallback prompt for a non-GPT model', () async {
    final (h, _) = await start([
      ScriptedCall.text('{"text": "ok"}'),
    ], shell: true);
    final (status, _) = await runToEnd(
      h,
      codexOp(
        shell: true,
        viewImage: true,
        reportProgress: true,
        model: 'deepseek-v4',
        effort: null,
        outputSchema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
          'required': ['text'],
        },
      ),
    );
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final target = h.gateway.llmRequests.single['target'] as Map;
    final actual = const JsonEncoder.withIndent('  ')
        .convert({
          'prompt_messages': target['prompt_messages'],
          'tools': target['tools'],
        })
        .replaceAll(
          RegExp(r'\d{4}-\d{2}-\d{2}</current_date>'),
          'DATE</current_date>',
        );
    if (Platform.environment['UPDATE_GOLDEN'] == '1') {
      golden.writeAsStringSync('$actual\n');
    }
    expect(
      '$actual\n',
      golden.readAsStringSync(),
      reason: 'regenerate with UPDATE_GOLDEN=1 dart test $golden',
    );
  });

  test('several calls in one response run concurrently; outputs in call '
      'order', () async {
    final arrived = <String>[];
    final both = Completer<void>();
    final (h, sup) = await start(
      [
        calls([
          ('c1', 'exec_command', {'cmd': 'echo one'}),
          ('c2', 'exec_command', {'cmd': 'echo two'}),
        ], text: 'Checking both.'),
        ScriptedCall.text('Both ran.'),
      ],
      shell: true,
      configure: (s) {
        s.onJob = (script) => FakeJobSpec(output: 'out of $script\n');
        // Each job waits until both have started: sequential execution
        // would never get there.
        s.beforeJob = (script) async {
          arrived.add(script);
          if (arrived.length == 2) both.complete();
          await both.future.timeout(const Duration(seconds: 5));
        };
      },
    );
    final (status, events) = await runToEnd(h, codexOp(shell: true));
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    expect(arrived, hasLength(2));
    expect(arrived.first, "exec bash -lc 'echo one'");
    final commentary = events.where((e) => e.event == 'commentary').single;
    expect(commentary.data['text'], 'Checking both.');
    final second = messagesOf(h.gateway.llmRequests[1]);
    final toolMessages = [
      for (final m in second)
        if (m['role'] == 'tool') m,
    ];
    expect([for (final m in toolMessages) m['tool_call_id']], ['c1', 'c2']);
    expect(
      toolMessages.first['content'],
      contains('Process exited with code 0'),
    );
    expect(
      toolMessages.first['content'],
      contains("out of exec bash -lc 'echo one'"),
    );
    final assistant = second.firstWhere((m) => m['role'] == 'assistant');
    expect(assistant['content'], 'Checking both.');
    expect((assistant['tool_calls'] as List).length, 2);
    final job = sup!.sandboxes.values.single.runRequests.firstWhere(
      (r) => '${r['script']}'.startsWith('exec bash'),
    );
    expect((job['env'] as Map)['NO_COLOR'], '1');
    expect(job['mode'], 'stdio');
  });

  test('apply_patch runs alone between parallel commands and edits the '
      'workspace', () async {
    final dir = newDataDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/notes.txt').writeAsStringSync('alpha\nbeta\n');
    final order = <String>[];
    final (h, _) = await start(
      [
        calls([
          ('c1', 'exec_command', {'cmd': 'ls'}),
          (
            'c2',
            'apply_patch',
            {
              'input':
                  '*** Begin Patch\n*** Update File: notes.txt\n@@\n alpha\n'
                  '-beta\n+gamma\n*** Add File: new/n.txt\n+hi\n*** End Patch',
            },
          ),
          ('c3', 'exec_command', {'cmd': 'cat notes.txt'}),
        ]),
        ScriptedCall.text('Patched.'),
      ],
      shell: true,
      configure: (s) {
        final local = localWorkspace(dir);
        s.onControl = (script) async {
          final r = await local(script);
          if (r != null && !order.contains('patch')) order.add('patch');
          return r;
        };
        s.beforeJob = (script) async => order.add(script);
      },
    );
    final (status, _) = await runToEnd(h, codexOp(shell: true));
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    expect(order, [
      "exec bash -lc 'ls'",
      'patch',
      "exec bash -lc 'cat notes.txt'",
    ]);
    expect(File('${dir.path}/notes.txt').readAsStringSync(), 'alpha\ngamma\n');
    expect(File('${dir.path}/new/n.txt').readAsStringSync(), 'hi\n');
    final out = messagesOf(h.gateway.llmRequests[1])
        .firstWhere((m) => m['tool_call_id'] == 'c2');
    expect(
      out['content'],
      matches(
        RegExp(
          r'^Exit code: 0\nWall time: [\d.]+ seconds\nOutput:\nSuccess\. '
          r'Updated the following files:\nA new/n\.txt\nM notes\.txt\n$',
        ),
      ),
    );
    final tools = toolNamesOf(h.gateway.llmRequests.first);
    expect(tools, ['exec_command', 'write_stdin', 'apply_patch', 'ask_human']);
  });

  test('a running command keeps a session; write_stdin polls it', () async {
    final (h, _) = await start(
      [
        calls([
          ('c1', 'exec_command', {'cmd': 'serve', 'yield_time_ms': 300}),
        ]),
        ScriptedCall(
          chunks: [
            ScriptedChunk(
              toolCalls: [
                // The session ID is read from the first output below.
                toolCallDelta(
                  index: 0,
                  id: 'c2',
                  name: 'write_stdin',
                  arguments: '',
                ),
              ],
            ),
            ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
          ],
        ),
        ScriptedCall.text('Polled.'),
      ],
      shell: true,
      configure: (s) =>
          s.onJob = (_) => FakeJobSpec(output: 'listening\n', running: true),
    );
    final (status, events) = await runToEnd(h, codexOp(shell: true));
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final first = messagesOf(h.gateway.llmRequests[1])
        .firstWhere((m) => m['tool_call_id'] == 'c1');
    expect(first['content'], contains('Process running with session ID '));
    expect(first['content'], endsWith('Output:\nlistening\n'));
    // write_stdin without a session_id is Codex's argument error.
    final finished = events.where(
      (e) =>
          e.event == 'tool_call' &&
          e.data['id'] == 'c2' &&
          e.data['phase'] == 'finished',
    );
    expect(
      finished.single.data['error'],
      'failed to parse function arguments: missing field `session_id`',
    );
  });

  group('retries', () {
    test('HTTP 500 is retried with attempt 1 (request layer)', () async {
      final (h, _) = await start([
        ScriptedCall(httpStatus: 500),
        ScriptedCall.text('Recovered.'),
      ]);
      final (status, events) = await runToEnd(h, codexOp());
      expect(status['status'], 'succeeded', reason: jsonEncode(status));
      final reqs = h.gateway.llmRequests;
      expect(reqs, hasLength(2));
      final caller = reqs[1]['caller'] as Map;
      expect(caller['attempt'], 2);
      expect(caller['call_index'], 1);
      expect(caller['invocation_id'], '${status['run_id']}:1');
      expect((reqs[0]['caller'] as Map).containsKey('attempt'), isFalse);
      final retry = events.singleWhere((e) => e.event == 'model_retry').data;
      expect(retry['layer'], 'request');
      expect(retry['attempt'], 2);
      expect(retry['kind'], 'serverError');
      expect(retry['delay_ms'], inInclusiveRange(179, 220));
      expect(events.where((e) => e.event == 'model_call'), hasLength(1));
    });

    test('a provider error in the stream is retried (stream layer)', () async {
      final (h, _) = await start([
        ScriptedCall(
          error: {'code': -500, 'error_type': 'InvokeServerUnavailableError'},
        ),
        ScriptedCall(
          error: {'code': -429, 'error_type': 'InvokeRateLimitError'},
        ),
        ScriptedCall.text('Recovered.'),
      ]);
      final (status, events) = await runToEnd(h, codexOp());
      expect(status['status'], 'succeeded', reason: jsonEncode(status));
      final retries = [
        for (final e in events)
          if (e.event == 'model_retry') e.data,
      ];
      expect([for (final r in retries) r['layer']], ['stream', 'stream']);
      expect([for (final r in retries) r['kind']], ['stream', 'rateLimited']);
      expect(
        [
          for (final r in h.gateway.llmRequests)
            (r['caller'] as Map)['attempt'],
        ],
        [null, 2, 3],
      );
    });

    test('terminal errors are not retried', () async {
      for (final (call, type) in [
        (ScriptedCall(httpStatus: 400), 'model_error'),
        (
          ScriptedCall(error: {'code': -429, 'message': 'quota'}),
          'model_quota',
        ),
        (
          ScriptedCall(
            error: {'code': -500, 'error_type': 'InvokeAuthorizationError'},
          ),
          'model_error',
        ),
      ]) {
        final (h, _) = await start([call, ScriptedCall.text('never')]);
        final (status, events) = await runToEnd(h, codexOp());
        expect(status['status'], 'failed');
        expect(resultOf(status)['error_type'], type);
        expect(h.gateway.llmRequests, hasLength(1));
        expect(events.where((e) => e.event == 'model_retry'), isEmpty);
      }
    });

    test('a gateway that refuses the retry ends the run with the first '
        'error', () async {
      final (h, _) = await start([
        ScriptedCall(httpStatus: 502),
        ScriptedCall(
          httpStatus: 409,
          httpBody: {'error': 'duplicate_invocation'},
        ),
      ]);
      final (status, _) = await runToEnd(h, codexOp());
      expect(status['status'], 'failed');
      final r = resultOf(status);
      expect(r['message'], contains('HTTP 502'));
      expect(r['message'], contains('refused by the gateway'));
    });
  });

  group('questions, snapshots, declared outputs', () {
    test('ask_human pauses; the answer resumes from the items', () async {
      final (h, _) = await start([
        calls([
          (
            'q1',
            'ask_human',
            {
              'title': 'Pick',
              'question': 'Which city?',
              'fields': [
                {'name': 'city', 'type': 'paragraph', 'label': 'City'},
              ],
            },
          ),
        ]),
        ScriptedCall.text('Going to Kyoto.'),
      ]);
      final (paused, _) = await runToEnd(h, codexOp());
      expect(paused['status'], 'paused', reason: jsonEncode(paused));
      final p = resultOf(paused);
      expect(p['tool_call_id'], 'q1');
      final snapshot = p['snapshot'] as Map;
      expect(snapshot['pending'], {
        'question_id': 'E1:q1',
        'tool_call_id': 'q1',
      });

      // A dify-style request cannot resume a codex snapshot.
      final dify = operation(
        resumeSequence: 1,
        continuation: answer(p, {'city': 'Kyoto'}),
      );
      final (code, body) = await h.post('/v1/operations', dify);
      expect(code, 422);
      expect(body['error'], 'snapshot_incompatible');

      final (done, events) = await runToEnd(
        h,
        codexOp(resumeSequence: 1, continuation: answer(p, {'city': 'Kyoto'})),
      );
      expect(done['status'], 'succeeded', reason: jsonEncode(done));
      expect(
        events.any((e) => e.event == 'tool_call' && e.data['id'] == 'q1'),
        isTrue,
      );
      final msgs = messagesOf(h.gateway.llmRequests[1]);
      final tool = msgs.firstWhere((m) => m['role'] == 'tool');
      expect(tool['tool_call_id'], 'q1');
      expect(jsonDecode(tool['content'] as String)['values'], {
        'city': 'Kyoto',
      });
    });

    test('declared outputs: the final message is the candidate; an output '
        'retry continues the items', () async {
      final schema = {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'score': {'type': 'integer'},
        },
        'required': ['text', 'score'],
      };
      final (h, _) = await start([
        ScriptedCall.text('```json\n{"text": "draft", "score": "high"}\n```'),
        ScriptedCall.text('{"text": "final", "score": 3}'),
      ]);
      final (first, _) = await runToEnd(h, codexOp(outputSchema: schema));
      expect(first['status'], 'succeeded', reason: jsonEncode(first));
      final r1 = resultOf(first);
      expect(r1['candidate'], {'text': 'draft', 'score': 'high'});
      expect((r1['candidate_errors'] as List).single['field'], 'score');
      expect(
        toolNamesOf(h.gateway.llmRequests.first),
        isNot(contains('final_output')),
      );
      expect(
        messagesOf(h.gateway.llmRequests.first)[1]['content'],
        contains('# Final answer format'),
      );

      final (second, _) = await runToEnd(
        h,
        codexOp(
          outputSchema: schema,
          outputAttempt: 1,
          continuation: {
            'kind': 'output_retry',
            'snapshot': r1['snapshot'],
            'feedback': [
              {'field': 'score', 'error': 'must be an integer'},
            ],
          },
        ),
      );
      expect(resultOf(second)['candidate'], {'text': 'final', 'score': 3});
      final last = messagesOf(h.gateway.llmRequests[1]).last;
      expect(
        last['content'],
        startsWith('Your previous output failed validation'),
      );
    });

    test(
      'a final answer that is no JSON object is a candidate error',
      () async {
        final (h, _) = await start([ScriptedCall.text('I could not finish.')]);
        final (status, _) = await runToEnd(
          h,
          codexOp(
            outputSchema: {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
            },
          ),
        );
        final r = resultOf(status);
        expect(r['candidate'], isNull);
        expect((r['candidate_errors'] as List).single['field'], '');
      },
    );
  });

  test('max_turns: the notice before the last call; a last call with tools '
      'fails', () async {
    final (h, _) = await start([
      calls([('c1', 'unknown_tool', {})]),
      calls([('c2', 'unknown_tool', {})]),
    ]);
    final (status, events) = await runToEnd(h, codexOp(maxTurns: 2));
    expect(status['status'], 'failed');
    expect(resultOf(status)['error_type'], 'max_turns');
    final notice = events.singleWhere((e) => e.event == 'budget_notice').data;
    expect(notice['call_index'], 2);
    final last = messagesOf(h.gateway.llmRequests[1]);
    expect(
      last.last['content'],
      startsWith('Budget notice from the agent service'),
    );
    final tool = last.firstWhere((m) => m['role'] == 'tool');
    expect(tool['content'], 'unsupported call: unknown_tool');
  });

  test('view_image: Codex schema; the image follows the tool message on the '
      'plugin wire', () async {
    final (h, _) = await start(
      [
        calls([
          ('v1', 'view_image', {'path': 'out/a.png', 'detail': 'original'}),
        ]),
        ScriptedCall.text('Seen.'),
      ],
      shell: true,
      configure: (s) =>
          s.files['/workspace/out/a.png'] = png(64, 32, size: 200),
    );
    final (status, _) = await runToEnd(
      h,
      codexOp(shell: true, viewImage: true),
    );
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final tools =
        (h.gateway.llmRequests.first['target'] as Map)['tools'] as List;
    final view = tools.cast<Map>().firstWhere((t) => t['name'] == 'view_image');
    expect(((view['parameters'] as Map)['properties'] as Map).keys, [
      'detail',
      'path',
    ]);
    final msgs = messagesOf(h.gateway.llmRequests[1]);
    final i = msgs.indexWhere((m) => m['role'] == 'tool');
    expect(msgs[i]['content'], 'Image attached after this result: out/a.png');
    final image = (msgs[i + 1]['content'] as List).cast<Map>().last;
    expect(image['type'], 'image');
    expect(image['detail'], 'high');
    expect(image['url'], startsWith('dify-sf-file:up'));
  });

  test('update_plan (opt-in) emits a plan event', () async {
    final (h, _) = await start([
      calls([
        (
          'p1',
          'update_plan',
          {
            'plan': [
              {'step': 'Read', 'status': 'in_progress'},
            ],
          },
        ),
      ]),
      ScriptedCall.text('Planned.'),
    ]);
    final (status, events) = await runToEnd(h, codexOp(updatePlan: true));
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    expect(events.singleWhere((e) => e.event == 'plan').data['plan'], [
      {'step': 'Read', 'status': 'in_progress'},
    ]);
    expect(toolNamesOf(h.gateway.llmRequests.first), [
      'update_plan',
      'ask_human',
    ]);
  });

  test('422 for ultra and unknown styles, before anything runs', () async {
    final (h, _) = await start([]);
    final (c1, b1) = await h.post('/v1/operations', codexOp(effort: 'ultra'));
    expect(c1, 422);
    expect(b1['error'], 'unsupported_reasoning_effort');
    final o = codexOp()..['harness_style'] = 'claude_code';
    final (c2, b2) = await h.post('/v1/operations', o);
    expect(c2, 422);
    expect(b2['error'], 'unsupported_harness_style');
    expect(h.gateway.llmRequests, isEmpty);
  });

  test('cancel during a model call ends the run cancelled', () async {
    final (h, _) = await start([ScriptedCall(hang: true)]);
    final run = await h.startOperation(codexOp());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final (code, _) = await h.post('/v1/runs/$run/cancel', {
      'protocol': protocolName,
      'generation': 1,
    });
    expect(code, 202);
    final status = await h.waitEnded(run);
    expect(status['status'], 'cancelled');
    await h.gateway.observations.single.closedByClient.future.timeout(
      const Duration(seconds: 5),
    );
  });

  test('invalid ask_human arguments are a tool error; no pause', () async {
    final (h, _) = await start([
      calls([
        ('q1', 'ask_human', {'question': ''}),
      ]),
      ScriptedCall.text('Fine without asking.'),
    ]);
    final (status, events) = await runToEnd(h, codexOp());
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final finished = events.singleWhere(
      (e) => e.event == 'tool_call' && e.data['phase'] == 'finished',
    );
    expect(finished.data['error'], isNotEmpty);
    final tool = messagesOf(h.gateway.llmRequests[1])
        .firstWhere((m) => m['role'] == 'tool');
    expect(tool['content'], startsWith('Invalid ask_human arguments: '));
  });

  test('ask_human is not a question when tools.ask_human is off', () async {
    final (h, _) = await start([
      calls([
        ('q1', 'ask_human', {'question': 'Which?'}),
      ]),
      ScriptedCall.text('Done.'),
    ]);
    final (status, _) = await runToEnd(h, codexOp(askHuman: false));
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final tool = messagesOf(h.gateway.llmRequests[1])
        .firstWhere((m) => m['role'] == 'tool');
    expect(tool['content'], 'unsupported call: ask_human');
  });
}
