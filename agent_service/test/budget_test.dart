import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

const scoreSchema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string'},
    'score': {'type': 'number'},
  },
  'required': ['text', 'score'],
};

const fileSchema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string'},
    'report': {
      'type': 'string',
      'x-dify-sf-file': {
        'extensions': ['csv'],
      },
    },
  },
  'required': ['text', 'report'],
};

/// The `default` profile with `max_turns_max` 1000, for budgets above the
/// implicit profile's 50.
final largeBudgetProfiles = ExecutorProfiles.parse({
  'version': 1,
  'profiles': {
    'default': {
      'image':
          'dify-sf/sandbox@sha256:'
          '1111111111111111111111111111111111111111111111111111111111111111',
      'limits': {'max_turns_max': 1000},
    },
  },
});

Future<Harness> startShell(
  List<ScriptedCall> calls, {
  ExecutorProfiles? profiles,
}) async {
  final sup = FakeSupervisor(
    key: testSupervisorKey,
    configure: (s) {
      s.files['/workspace/out/report.csv'] = utf8.encode('a,b\n1,2\n');
      s.onJob = (_) => FakeJobSpec(output: 'ok\r\n');
    },
  );
  if (profiles != null) {
    sup.profiles = {
      for (final p in profiles.profiles.values)
        p.name: {'status': 'ok', 'digest': p.digest},
    };
  }
  await sup.start();
  final h = await Harness.start(
    calls: calls,
    supervisorUrl: sup.url,
    profiles: profiles,
  );
  addTearDown(() async {
    await h.close();
    await sup.close();
  });
  return h;
}

List<Map> messagesOf(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['prompt_messages'] as List).cast<Map>();

ScriptedCall shell(String id) =>
    ScriptedCall.toolCall(id, 'shell_run', {'script': 'true'});

void main() {
  test('callsToFinish: one call, two when declared file outputs must be '
      'written first', () {
    OperationRequest op(Map<String, Object?>? schema, {bool shell = true}) =>
        OperationRequest.parse(
          operation(outputSchema: schema, shell: shell, askHuman: false),
        );
    expect(callsToFinish(op(null)), 1);
    expect(callsToFinish(op(scoreSchema)), 1);
    expect(callsToFinish(op(fileSchema)), 2);
    expect(callsToFinish(op(fileSchema, shell: false)), 1);
  });

  test('noticeReserve: a tenth of max_turns, at most 20, none below 40', () {
    expect(noticeReserve(1), 0);
    expect(noticeReserve(2), 0);
    expect(noticeReserve(39), 0);
    expect(noticeReserve(40), 4);
    expect(noticeReserve(200), 20);
    expect(noticeReserve(1000), 20);
  });

  test('noticeCalls: what finishing needs plus the reserve', () {
    int calls(int maxTurns, Map<String, Object?>? schema) => noticeCalls(
      OperationRequest.parse(
        operation(
          outputSchema: schema,
          shell: true,
          askHuman: false,
          maxTurns: maxTurns,
        ),
      ),
    );
    for (final (maxTurns, plain, files) in [
      (2, 1, 2),
      (39, 1, 2),
      (40, 5, 6),
      (200, 21, 22),
      (1000, 21, 22),
    ]) {
      expect(
        calls(maxTurns, scoreSchema),
        plain,
        reason: 'max_turns $maxTurns',
      );
      expect(calls(maxTurns, fileSchema), files, reason: 'max_turns $maxTurns');
    }
  });

  for (final (maxTurns, noticeAt) in [(39, 38), (200, 179)]) {
    test(
      'max_turns $maxTurns with declared file outputs: the notice before '
      'call $noticeAt (remaining_calls ${maxTurns - noticeAt + 1})',
      () async {
        final h = await startShell([
          for (var i = 1; i <= noticeAt; i++) shell('c$i'),
          ScriptedCall.toolCall('fo', 'final_output', {
            'text': 'partial report',
            'report': 'out/report.csv',
          }),
        ], profiles: largeBudgetProfiles);
        final run = await h.startOperation(
          operation(
            shell: true,
            askHuman: false,
            outputSchema: fileSchema,
            maxTurns: maxTurns,
            timeoutSeconds: 600,
          ),
        );
        final s = await h.waitEnded(run, timeout: const Duration(seconds: 60));
        expect(s['status'], 'succeeded', reason: jsonEncode(s));
        final result = s['result'] as Map;
        expect(result['partial'], {
          'reason': 'max_turns',
          'notice_call_index': noticeAt,
        });
        final notice = (await h.events(run))
            .singleWhere((e) => e.event == 'budget_notice');
        final left = maxTurns - noticeAt + 1;
        expect(notice.data, {
          'reason': 'max_turns',
          'call_index': noticeAt,
          'remaining_calls': left,
        });
        expect(h.gateway.llmRequests, hasLength(noticeAt + 1));
        expect(
          jsonEncode(h.gateway.llmRequests[noticeAt - 2]),
          isNot(contains('Budget notice')),
        );
        final text = messagesOf(h.gateway.llmRequests[noticeAt - 1]).last;
        expect(text['role'], 'user');
        expect(
          text['content'],
          contains('$left model calls (this one included)'),
        );
        expect(
          text['content'],
          contains(
            left == 2
                ? 'use at most one step to write'
                : 'use at most ${left - 1} steps to write',
          ),
        );
      },
    );
  }

  test('the last call gets the notice, kept in the history; final_output '
      'then succeeds with partial', () async {
    final h = await startShell([
      shell('c1'),
      shell('c2'),
      ScriptedCall.toolCall('fo', 'final_output', {
        'text': 'unfinished',
        'score': 1,
      }),
    ]);
    final run = await h.startOperation(
      operation(
        shell: true,
        askHuman: false,
        outputSchema: scoreSchema,
        maxTurns: 3,
      ),
    );
    final s = await h.waitEnded(run);
    expect(s['status'], 'succeeded', reason: jsonEncode(s));
    final result = (s['result'] as Map).cast<String, Object?>();
    expect(result['partial'], {'reason': 'max_turns', 'notice_call_index': 3});
    expect(result['candidate'], {'text': 'unfinished', 'score': 1});

    expect(h.gateway.llmRequests, hasLength(3));
    for (final r in h.gateway.llmRequests.take(2)) {
      expect(jsonEncode(r), isNot(contains('Budget notice')));
    }
    final last = messagesOf(h.gateway.llmRequests[2]).last;
    expect(last['role'], 'user');
    expect(
      last['content'],
      'Budget notice from the agent service: this run has 1 model call (this '
      'one included) left. Stop exploring. Call final_output now with the '
      'best result you have: fill every required field and say in `text` '
      'what is unfinished. A last step that calls other tools instead is not '
      'run, and the run fails without a result.',
    );
    // Appended after the history: the previous request is a prefix.
    final events = await h.events(run);
    final notice = events.singleWhere((e) => e.event == 'budget_notice');
    expect(notice.data, {
      'reason': 'max_turns',
      'call_index': 3,
      'remaining_calls': 1,
    });
    expect(
      events
          .where((e) => e.event == 'model_call')
          .map((e) => (e.data['prompt'] as Map)['prefix_stable']),
      [null, true, true],
    );
    // The snapshot keeps it where it was added (an output retry continues
    // from the same prefix).
    final messages = ((result['snapshot'] as Map)['messages'] as List)
        .cast<Map>();
    final at = messages.indexWhere(
      (m) => jsonEncode(m).contains('Budget notice'),
    );
    expect(at, messages.length - 3); // notice, final_output call, its answer
  });

  test('a last call that does not finish: its tools are not run and the run '
      'fails max_turns', () async {
    final h = await startShell([shell('c1'), shell('c2'), shell('c3')]);
    final run = await h.startOperation(
      operation(
        shell: true,
        askHuman: false,
        outputSchema: scoreSchema,
        maxTurns: 2,
      ),
    );
    final s = await h.waitEnded(run);
    expect(s['status'], 'failed');
    final result = s['result'] as Map;
    expect(result['error_type'], 'max_turns');
    expect(
      result['message'],
      'the run reached max_turns (2) without a final answer; the model was '
      'told to finish at call 2',
    );
    final started = (await h.events(run))
        .where((e) => e.event == 'tool_call' && e.data['phase'] == 'started');
    expect(started.map((e) => e.data['id']), ['c1']);
    expect(h.gateway.llmRequests, hasLength(2));
  });

  test('without declared outputs the notice asks for a text answer', () async {
    final h = await startShell([shell('c1'), ScriptedCall.text('so far: x')]);
    final run = await h.startOperation(
      operation(shell: true, askHuman: false, maxTurns: 2),
    );
    final s = await h.waitEnded(run);
    expect(s['status'], 'succeeded');
    final result = s['result'] as Map;
    expect(result['candidate'], {'text': 'so far: x'});
    expect(result['partial'], {'reason': 'max_turns', 'notice_call_index': 2});
    expect(
      messagesOf(h.gateway.llmRequests[1]).last['content'],
      contains('Give your final answer as text now, without calling tools'),
    );
  });

  test('declared file outputs: the notice comes one call earlier and offers '
      'one step to write the files', () async {
    final h = await startShell([
      shell('c1'),
      shell('c2'),
      ScriptedCall.toolCall('fo', 'final_output', {
        'text': 'partial report',
        'report': 'out/report.csv',
      }),
    ]);
    final run = await h.startOperation(
      operation(
        shell: true,
        askHuman: false,
        outputSchema: fileSchema,
        maxTurns: 3,
      ),
    );
    final s = await h.waitEnded(run);
    expect(s['status'], 'succeeded', reason: jsonEncode(s));
    final result = s['result'] as Map;
    expect(result['partial'], {'reason': 'max_turns', 'notice_call_index': 2});
    expect(result['candidate_errors'], isEmpty);
    final second = messagesOf(h.gateway.llmRequests[1]);
    expect(second.last['content'], contains('2 model calls'));
    expect(second.last['content'], contains('use at most one step to write'));
    // Call 3 repeats call 2's messages, the notice included.
    final third = messagesOf(h.gateway.llmRequests[2]);
    expect(jsonEncode(third.sublist(0, second.length)), jsonEncode(second));
  });

  test('time: the notice comes when the time left is no more than the '
      'longest step so far', () async {
    final h = await startShell([
      ScriptedCall(
        delayMs: 1200,
        chunks: [
          ScriptedChunk(
            toolCalls: [
              toolCallDelta(id: 'c1', name: 'shell_run', arguments: '{}'),
            ],
          ),
          ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
        ],
      ),
      ScriptedCall(
        delayMs: 1200,
        chunks: [
          ScriptedChunk(
            toolCalls: [
              toolCallDelta(id: 'c2', name: 'shell_run', arguments: '{}'),
            ],
          ),
          ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
        ],
      ),
      ScriptedCall.text('what I have'),
    ]);
    final run = await h.startOperation(
      operation(shell: true, askHuman: false, maxTurns: 50, timeoutSeconds: 3),
    );
    final s = await h.waitEnded(run);
    expect(s['status'], 'succeeded', reason: jsonEncode(s));
    expect((s['result'] as Map)['partial'], {
      'reason': 'timeout',
      'notice_call_index': 3,
    });
    final notice = (await h.events(run))
        .singleWhere((e) => e.event == 'budget_notice');
    expect(notice.data['reason'], 'timeout');
    expect(notice.data['remaining_seconds'], lessThanOrEqualTo(1));
    expect(
      messagesOf(h.gateway.llmRequests[2]).last['content'],
      contains('48 model calls (this one included) and about'),
    );
  });

  test('enough budget: no notice, partial null', () async {
    final h = await startShell([shell('c1'), ScriptedCall.text('done')]);
    final run = await h.startOperation(
      operation(shell: true, askHuman: false, maxTurns: 3),
    );
    final s = await h.waitEnded(run);
    expect((s['result'] as Map)['partial'], isNull);
    expect(
      (await h.events(run)).where((e) => e.event == 'budget_notice'),
      isEmpty,
    );
  });
}
