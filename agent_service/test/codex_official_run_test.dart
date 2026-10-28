// The official Codex runtime against a scripted app-server (see
// codex_app_server_fake.dart): the run's JSON-RPC exchange with Codex and how
// Codex's notifications become events and the run's result. The real binary
// is covered by tool/codex_e2e.sh.
import 'dart:convert';

import 'package:test/test.dart';

import 'codex_app_server_fake.dart';

void main() {
  Future<(Map<String, Object?>, List<String>, List<Map<String, Object?>>)> ran(
    FakeCodexAppServer fake, {
    Map<String, Object?>? op,
  }) async {
    final (h, run, _) = await fake.startRun(op ?? officialCodexOp());
    final status = await h.waitEnded(run);
    final events = await h.events(run);
    return (
      (status['result'] as Map).cast<String, Object?>(),
      [for (final e in events) e.event],
      [for (final e in events) e.data],
    );
  }

  group('final answer', () {
    for (final phase in [null, 'partial_answer']) {
      test('a last message with phase $phase is the final answer', () async {
        final fake = FakeCodexAppServer(
          turn: (s) async {
            s
              ..message('Looking first.', phase: phase, id: 'm1')
              ..item('started', {
                'type': 'commandExecution',
                'id': 'c1',
                'command': 'ls',
                'cwd': '/workspace',
              })
              ..item('completed', {
                'type': 'commandExecution',
                'id': 'c1',
                'command': 'ls',
                'cwd': '/workspace',
                'status': 'completed',
                'exitCode': 0,
                'aggregatedOutput': 'a\n',
              })
              ..usage()
              ..message('All done.', phase: phase, id: 'm2')
              ..usage()
              ..complete({'status': 'completed'});
          },
        );
        final (result, names, data) = await ran(fake);
        expect(names.last, 'succeeded', reason: jsonEncode(result));
        expect(result['candidate'], {'text': 'All done.'});
        // The first one, followed by a tool call, is commentary.
        final commentary = [
          for (var i = 0; i < names.length; i++)
            if (names[i] == 'commentary') data[i]['text'],
        ];
        expect(commentary, ['Looking first.']);
        expect(
          ((result['snapshot'] as Map)['codex'] as Map)['final_answer'],
          'All done.',
        );
      });
    }

    test('final_answer wins over a later unphased message', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s
            ..message('The answer.', phase: 'final_answer', id: 'm1')
            ..message('trailing remark', id: 'm2')
            ..complete({'status': 'completed'});
        },
      );
      final (result, _, _) = await ran(fake);
      expect(result['candidate'], {'text': 'The answer.'});
    });
  });

  group('usageLimitExceeded', () {
    Future<Map<String, Object?>> failing(
      String message, {
      int calls = 0,
      int retries = 0,
    }) async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          for (var i = 0; i < calls; i++) {
            s.usage();
          }
          for (var i = 0; i < retries; i++) {
            s.notify('error', {
              'threadId': 'thr_root',
              'turnId': 'turn_1',
              'willRetry': true,
              'error': {
                'message': 'Reconnecting... ${i + 1}/2',
                'codexErrorInfo': {
                  'responseStreamDisconnected': {'httpStatusCode': 502},
                },
              },
            });
          }
          s.fail('usageLimitExceeded', message);
        },
      );
      final (result, names, _) = await ran(
        fake,
        op: officialCodexOp(maxTurns: 3),
      );
      expect(names.last, 'failed');
      return result;
    }

    test('the gateway\'s marked call limit is max_turns', () async {
      final r = await failing(
        'You’ve hit your usage limit. dify-sf-agent-call-limit, or try '
        'again later.',
      );
      expect(r['error_type'], 'max_turns');
      expect(r['message'], contains('max_turns (3)'));
    });

    test('an unmarked usage_limit_reached after max_turns calls seen here '
        '(finished and retried) is max_turns', () async {
      final r = await failing(
        'You’ve hit your usage limit. Try again later.',
        calls: 2,
        retries: 1,
      );
      expect(r['error_type'], 'max_turns');
      expect(r['message'], contains('2 model calls finished here, 1 retried'));
    });

    test('an unmarked usage_limit_reached before max_turns calls is the '
        'provider\'s limit: model_quota with Codex\'s message', () async {
      final r = await failing(
        'You’ve hit your usage limit. Try again later.',
        calls: 1,
      );
      expect(r['error_type'], 'model_quota');
      expect(r['message'], contains('not the gateway\'s call limit'));
      expect(r['message'], contains('Codex: You’ve hit your usage limit'));
    });

    test('a provider quota is model_quota', () async {
      final r = await failing(
        'Quota exceeded. Check your plan and billing details.',
        calls: 3,
      );
      expect(r['error_type'], 'model_quota');
      expect(r['message'], contains('Quota exceeded'));
    });
  });

  group('app-server gone mid-turn', () {
    void startCommand(FakeCodexAppServer s) => s.item('started', {
      'type': 'commandExecution',
      'id': 'c1',
      'command': 'sleep 100',
      'cwd': '/workspace',
    });

    test('an exit fails the run sandbox_error with the exit status and the '
        'output tail; the open tool call is finished with an error', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          startCommand(s);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await s.exit(
            exitCode: 101,
            output:
                'starting\nthread \'main\' panicked at core/src/x.rs: boom\n',
          );
        },
      );
      final (result, names, data) = await ran(fake);
      expect(result['error_type'], 'sandbox_error', reason: jsonEncode(result));
      expect(result['message'], startsWith('Codex ended mid-turn: '));
      expect(
        result['message'],
        contains('codex app-server exited (exited 101)'),
      );
      expect(result['message'], contains("panicked at core/src/x.rs: boom"));
      final finished = [
        for (var i = 0; i < names.length; i++)
          if (names[i] == 'tool_call' && data[i]['phase'] == 'finished')
            data[i],
      ];
      expect(finished, [
        {
          'id': 'c1',
          'name': 'exec_command',
          'phase': 'finished',
          'error': 'the Codex app-server ended before the tool finished',
        },
      ]);
    });

    test('a closed connection with the process still running fails '
        'internal', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          startCommand(s);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await s.close();
        },
      );
      final (result, _, _) = await ran(fake);
      expect(result['error_type'], 'internal');
      expect(
        result['message'],
        'Codex ended mid-turn: the connection to the Codex app-server closed '
        'and the process still runs',
      );
    });
  });

  group('thread settings readback', () {
    FakeCodexAppServer answering({String? model, String? effort}) =>
        FakeCodexAppServer(
          threadModel: model,
          threadEffort: effort,
          turn: (s) async => s
            ..message('ok', phase: 'final_answer')
            ..complete({'status': 'completed'}),
        );

    test('run_started records Codex\'s model and effort', () async {
      final fake = answering();
      final (result, names, data) = await ran(
        fake,
        op: officialCodexOp(effort: 'high'),
      );
      expect(names.first, 'run_started');
      expect(names.last, 'succeeded', reason: jsonEncode(result));
      final runtime = data.first['runtime'] as Map;
      expect(runtime['model'], 'test-model');
      expect(runtime['reasoning_effort'], 'high');
      expect(runtime.containsKey('request_reasoning_effort'), isFalse);
    });

    test(
      'ultra is Codex\'s: recorded with the effort its requests carry',
      () async {
        final fake = answering();
        final (result, names, data) = await ran(
          fake,
          op: officialCodexOp(
            effort: 'ultra',
            reasoningEfforts: ['high', 'max', 'ultra'],
          ),
        );
        expect(names.last, 'succeeded', reason: jsonEncode(result));
        final runtime = data.first['runtime'] as Map;
        expect(runtime['reasoning_effort'], 'ultra');
        expect(runtime['request_reasoning_effort'], 'max');
      },
    );

    for (final (what, model, effort, message) in [
      (
        'model',
        'other-model',
        null,
        'model "other-model", not the requested '
            '"test-model"',
      ),
      (
        'effort',
        null,
        'low',
        'reasoning effort "low", not the requested '
            '"high"',
      ),
    ]) {
      test('another $what in the thread/start reply ends the run before the '
          'turn', () async {
        final fake = answering(model: model, effort: effort);
        final (result, names, data) = await ran(
          fake,
          op: officialCodexOp(effort: 'high'),
        );
        expect(result['error_type'], 'internal');
        expect(result['message'], 'Codex started the thread with $message');
        expect(fake.methods, isNot(contains('turn/start')));
        expect(names, ['run_started', 'failed']);
      });
    }

    test('thread/settings/updated to another effort interrupts the turn and '
        'ends the run', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s
            ..notify('model/rerouted', {
              'threadId': 'thr_root',
              'turnId': 'turn_1',
              'fromModel': 'test-model',
              'toModel': 'test-model',
              'reason': 'highRiskCyberActivity',
            })
            ..notify('thread/settings/updated', {
              'threadId': 'thr_child',
              'threadSettings': {'model': 'x', 'effort': 'low'},
            })
            ..notify('thread/settings/updated', {
              'threadId': 'thr_root',
              'threadSettings': {'model': 'test-model', 'effort': 'low'},
            });
        },
      );
      final (result, _, _) = await ran(
        fake,
        op: officialCodexOp(effort: 'high'),
      );
      expect(result['error_type'], 'internal', reason: jsonEncode(result));
      expect(
        result['message'],
        'Codex changed the thread to reasoning effort "low", not the '
        'requested "high"',
      );
      expect(fake.methods, contains('turn/interrupt'));
    });
  });

  group('context', () {
    test('a contextCompaction item is a compaction event pair', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s
            ..usage()
            ..item('started', {'type': 'contextCompaction', 'id': 'cc1'})
            ..item('completed', {'type': 'contextCompaction', 'id': 'cc1'})
            ..notify('thread/compacted', {
              'threadId': 'thr_root',
              'turnId': 'turn_1',
            })
            // a sub-agent's compaction is not the run's
            ..item('started', {
              'type': 'contextCompaction',
              'id': 'cc2',
            }, thread: 'thr_child')
            ..message('ok', phase: 'final_answer')
            ..complete({'status': 'completed'});
        },
      );
      final (result, names, data) = await ran(fake);
      expect(names.last, 'succeeded', reason: jsonEncode(result));
      expect(
        [
          for (var i = 0; i < names.length; i++)
            if (names[i] == 'compaction') data[i],
        ],
        [
          {'phase': 'started', 'call_index': 2},
          {'phase': 'finished', 'call_index': 2},
        ],
      );
    });

    test(
      'contextWindowExceeded names the window and where it came from',
      () async {
        final fake = FakeCodexAppServer(
          turn: (s) async => s.fail(
            'contextWindowExceeded',
            'Codex ran out of room in the model\'s context window.',
          ),
        );
        final (result, names, data) = await ran(fake);
        expect(result['error_type'], 'model_error');
        expect(
          result['message'],
          'the conversation no longer fits the model\'s context window (272000 '
          'tokens, fallback) and Codex could not compact it enough: Codex: '
          'Codex ran out of room in the model\'s context window.',
        );
        final runtime = data.first['runtime'] as Map;
        expect(runtime['context_window'], 272000);
        expect(runtime['context_window_source'], 'fallback');
      },
    );

    test('the operation\'s context window is recorded', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async => s
          ..message('ok', phase: 'final_answer')
          ..complete({'status': 'completed'}),
      );
      final (_, _, data) = await ran(
        fake,
        op: officialCodexOp(contextWindow: 64000),
      );
      final runtime = data.first['runtime'] as Map;
      expect(runtime['context_window'], 64000);
      expect(runtime['context_window_source'], 'operation');
    });
  });

  test(
    'initialize opts out of the notifications the runtime ignores',
    () async {
      final fake = FakeCodexAppServer(
        turn: (s) async => s
          ..message('ok', phase: 'final_answer')
          ..complete({'status': 'completed'}),
      );
      final (result, _, _) = await ran(fake);
      expect(result['candidate'], {'text': 'ok'});
      final caps = fake.paramsOf('initialize')['capabilities'] as Map;
      expect(caps['experimentalApi'], isTrue);
      expect(caps['optOutNotificationMethods'], [
        'item/agentMessage/delta',
        'item/plan/delta',
        'item/reasoning/summaryTextDelta',
        'item/reasoning/summaryPartAdded',
        'item/reasoning/textDelta',
        'item/commandExecution/outputDelta',
        'item/fileChange/outputDelta',
        'item/fileChange/patchUpdated',
        'turn/diff/updated',
        'account/rateLimits/updated',
      ]);
    },
  );
}
