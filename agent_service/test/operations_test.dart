import 'dart:async';
import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('idempotency and generations', () {
    test('the same operation twice runs once; a different body conflicts; '
        'an older generation is stale', () async {
      final h = await Harness.start(
        calls: [ScriptedCall.text('first', delayMs: 100)],
      );
      addTearDown(h.close);
      final body = operation(generation: 3);
      final runId = await h.startOperation(body);

      // A network resend while running and after the end: 200, same run.
      final (s1, j1) = await h.post('/v1/operations', body);
      expect(s1, 200);
      expect(j1['run_id'], runId);
      expect(j1['status'], 'running');
      await h.waitEnded(runId);
      final (s2, j2) = await h.post('/v1/operations', body);
      expect(s2, 200);
      expect(j2['run_id'], runId);
      expect(j2['status'], 'succeeded');
      expect((j2['result'] as Map)['candidate'], {'text': 'first'});

      // A newer generation adopting the same operation is the same digest.
      final (s3, j3) = await h.post('/v1/operations', operation(generation: 4));
      expect(s3, 200);
      expect(j3['run_id'], runId);
      expect(h.gateway.llmRequests, hasLength(1));

      final (s4, j4) = await h.post(
        '/v1/operations',
        operation(generation: 4, task: 'something else'),
      );
      expect(s4, 409);
      expect(j4['error'], 'operation_conflict');
      expect(j4['run_id'], runId);

      final (s5, j5) = await h.post('/v1/operations', operation(generation: 2));
      expect(s5, 409);
      expect(j5['error'], 'stale_generation');
      expect(h.gateway.llmRequests, hasLength(1));
    });

    test('a lease of a newer generation makes older requests stale', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      final (s, _) = await h.post('/v1/executions/E9/lease', {
        'protocol': protocolName,
        'generation': 5,
        'ttl_seconds': 60,
      });
      expect(s, 200);
      final (s2, j2) = await h.post(
        '/v1/operations',
        operation(executionId: 'E9', generation: 4),
      );
      expect(s2, 409);
      expect(j2['error'], 'stale_generation');
    });
  });

  group('events and status', () {
    test('cursor resume returns the remaining events; status agrees with the '
        'terminal event; expired cursors answer 410', () async {
      final h = await Harness.start(
        calls: [
          ScriptedCall(
            chunks: [
              ScriptedChunk(reasoning: 'a'),
              ScriptedChunk(reasoning: 'b'),
              ScriptedChunk(text: 'done'),
              ScriptedChunk(usage: defaultUsage(), finishReason: 'stop'),
            ],
          ),
        ],
      );
      addTearDown(h.close);
      final runId = await h.startOperation(operation(askHuman: false));
      final all = await h.events(runId);
      expect(all.map((e) => e.event), [
        'run_started',
        'thought',
        'thought',
        'model_call',
        'succeeded',
      ]);
      expect(all.map((e) => e.id), [1, 2, 3, 4, 5]);

      final rest = await h.events(runId, after: 2);
      expect(rest.map((e) => e.id), [3, 4, 5]);
      final viaHeader = await h.events(runId, lastEventId: 3);
      expect(viaHeader.map((e) => e.id), [4, 5]);
      expect(await h.events(runId, after: 5), isEmpty);

      final (_, status) = await h.get('/v1/runs/$runId');
      expect(status['status'], 'succeeded');
      expect(status['last_event_id'], 5);
      expect(status['result'], all.last.data);
      expect(status['acknowledged'], isFalse);

      // Still kept just before the retention ends.
      h.clock.offset = const Duration(hours: 23);
      expect((await h.eventsWithStatus(runId, after: 1)).$1, 200);
      // 24 hours after the end the events are gone.
      h.clock.offset = const Duration(hours: 24, minutes: 1);
      expect((await h.eventsWithStatus(runId, after: 1)).$1, 410);
      expect(h.service.store.sweep(), 1);
      expect((await h.eventsWithStatus(runId, after: 1)).$1, 410);
      final (_, after) = await h.get('/v1/runs/$runId');
      expect(after['result'], all.last.data);
    });

    test('ack ends event retention; it is idempotent and checks the '
        'terminal event id', () async {
      final h = await Harness.start(calls: [ScriptedCall.text('ok')]);
      addTearDown(h.close);
      final runId = await h.startOperation(operation(askHuman: false));
      final status = await h.waitEnded(runId);
      final last = status['last_event_id'] as int;
      final (bad, badJson) = await h.post('/v1/runs/$runId/ack', {
        'protocol': protocolName,
        'generation': 1,
        'result_event_id': last - 1,
      });
      expect(bad, 409);
      expect(badJson['error'], 'result_mismatch');
      for (var i = 0; i < 2; i++) {
        final (s, j) = await h.post('/v1/runs/$runId/ack', {
          'protocol': protocolName,
          'generation': 1,
          'result_event_id': last,
        });
        expect(s, 200);
        expect(j['acknowledged'], isTrue);
      }
      expect((await h.eventsWithStatus(runId, after: 1)).$1, 410);
      final (_, list) = await h.get('/v1/runs?state=active');
      expect(list['runs'], isEmpty);
    });

    test('active runs are listed with operation_id and generation', () async {
      final h = await Harness.start(
        calls: [
          ScriptedCall(delayMs: 2000, chunks: [ScriptedChunk(text: 'x')]),
        ],
      );
      addTearDown(h.close);
      final runId = await h.startOperation(operation(generation: 2));
      final (s, j) = await h.get('/v1/runs?state=active');
      expect(s, 200);
      expect(j['runs'], [
        {
          'run_id': runId,
          'operation_id': 'E1:0:0',
          'execution_id': 'E1',
          'generation': 2,
          'status': 'running',
          'acknowledged': false,
          'last_event_id': isA<int>(),
        },
      ]);
    });
  });

  group('durability', () {
    test('the run finishes without a subscriber and a new service instance '
        'serves its result', () async {
      final h = await Harness.start(
        calls: [
          ScriptedCall(
            chunkDelayMs: 100,
            chunks: [
              ScriptedChunk(reasoning: 'one'),
              ScriptedChunk(reasoning: 'two'),
              ScriptedChunk(text: 'final answer'),
              ScriptedChunk(usage: defaultUsage(), finishReason: 'stop'),
            ],
          ),
        ],
      );
      addTearDown(h.close);
      final runId = await h.startOperation(operation(askHuman: false));
      final (res, stream) = await h.openEvents(runId);
      expect(res.statusCode, 200);
      final first = await stream.first; // closes the subscription
      expect(first.event, 'run_started');

      final ended = await h.waitEnded(runId);
      expect(ended['status'], 'succeeded');
      final events = await h.events(runId);
      expect(events.last.event, 'succeeded');

      await h.restart();
      final (s, again) = await h.get('/v1/runs/$runId');
      expect(s, 200);
      expect(again['status'], 'succeeded');
      expect(again['result'], ended['result']);
      final replay = await h.events(runId);
      expect(replay.map((e) => e.id), events.map((e) => e.id));
      // Idempotency survives the restart too.
      final (s2, j2) = await h.post(
        '/v1/operations',
        operation(askHuman: false),
      );
      expect(s2, 200);
      expect(j2['run_id'], runId);
      expect(h.gateway.llmRequests, hasLength(1));
    });

    test('a run in flight when the process stops ends failed (internal) and '
        'is not replayed', () async {
      final h = await Harness.start(
        calls: [
          ScriptedCall(hang: true, chunks: [ScriptedChunk(reasoning: 'x')]),
        ],
      );
      addTearDown(h.close);
      final runId = await h.startOperation(operation(askHuman: false));
      while (h.gateway.observations.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await h.restart();
      final (_, status) = await h.get('/v1/runs/$runId');
      expect(status['status'], 'failed');
      expect((status['result'] as Map)['error_type'], 'internal');
      expect(h.gateway.llmRequests, hasLength(1));
    });

    test('DELETE removes the execution and refuses late operations', () async {
      final h = await Harness.start(calls: [ScriptedCall.text('ok')]);
      addTearDown(h.close);
      final runId = await h.startOperation(operation(askHuman: false));
      await h.waitEnded(runId);
      for (var i = 0; i < 2; i++) {
        final (s, j) = await h.delete('/v1/executions/E1', {
          'protocol': protocolName,
          'generation': 1,
        });
        expect(s, 200);
        expect(j['deleted'], isTrue);
      }
      expect((await h.get('/v1/runs/$runId')).$1, 404);
      final (s, j) = await h.post('/v1/operations', operation(askHuman: false));
      expect(s, 410);
      expect(j['error'], 'execution_deleted');
    });
  });

  group('validation', () {
    test('missing or invalid auth answers 401', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      expect((await h.post('/v1/operations', operation(), key: null)).$1, 401);
      expect(
        (await h.post('/v1/operations', operation(), key: 'nope')).$1,
        401,
      );
      final r = await http.get(h.base.resolve('/v1/health'));
      expect(r.statusCode, 401);
      final (s, health) = await h.get('/v1/health');
      expect(s, 200);
      expect(health, {
        'protocol': protocolName,
        'status': 'ok',
        'sandbox': 'disabled',
        'version': serviceVersion,
      });
    });

    test('unknown protocol and reserved env answer 400', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      final (s1, j1) = await h.post(
        '/v1/operations',
        operation(protocol: 'dify-sf-agent/2'),
      );
      expect(s1, 400);
      expect(j1['error'], 'unsupported_protocol');
      for (final name in ['HOME', 'https_proxy', 'SHELLCTL_X', 'no_proxy']) {
        final (s, j) = await h.post(
          '/v1/operations',
          operation(env: {name: 'v', 'OK': 'fine'}),
        );
        expect(s, 400, reason: name);
        expect(j['error'], 'reserved_env');
      }
      final (s3, j3) = await h.post('/v1/executions/E1/lease', {
        'protocol': 'x',
      });
      expect(s3, 400);
      expect(j3['error'], 'unsupported_protocol');
      expect(h.gateway.requests, isEmpty);
    });

    test(
      'a snapshot of another config or envelope version answers 422',
      () async {
        final h = await Harness.start(
          calls: [
            ScriptedCall.toolCall('ask_human:0', 'ask_human', {
              'question': 'City?',
            }),
          ],
        );
        addTearDown(h.close);
        final runId = await h.startOperation(operation());
        final paused =
            (await h.waitEnded(runId))['result'] as Map<String, Object?>;
        expect((await h.waitEnded(runId))['status'], 'paused');

        Future<(int, Map<String, Object?>)> resume(
          Map<String, Object?> snapshot, {
          String config = 'cfg-1',
          bool ask = true,
        }) => h.post(
          '/v1/operations',
          operation(
            resumeSequence: 1,
            configSnapshotId: config,
            askHuman: ask,
            continuation: answer(
              {...paused, 'snapshot': snapshot},
              {'city': 'Kyoto'},
            ),
          ),
        );

        final snapshot = (paused['snapshot'] as Map).cast<String, Object?>();
        final cases = <String, Future<(int, Map<String, Object?>)>>{
          'config': resume(snapshot, config: 'cfg-2'),
          'envelope': resume({
            ...snapshot,
            'envelope': 'dify-sf-agent-session/2',
          }),
          'genkit': resume({...snapshot, 'genkit': '2.0.0'}),
          'tools': resume(snapshot, ask: false),
          'question': h.post(
            '/v1/operations',
            operation(
              resumeSequence: 1,
              continuation: {
                ...answer(paused, {'city': 'Kyoto'}),
                'question_id': 'E1:q9',
              },
            ),
          ),
        };
        for (final e in cases.entries) {
          final (s, j) = await e.value;
          expect(s, 422, reason: e.key);
          expect(j['error'], 'snapshot_incompatible', reason: e.key);
        }
        expect(h.gateway.llmRequests, hasLength(1));
      },
    );

    test('8 MiB body limit', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      final big = operation(task: 'x' * (8 * 1024 * 1024 + 10));
      final r = await h.client.post(
        h.base.resolve('/v1/operations'),
        headers: h.headers(),
        body: jsonEncode(big),
      );
      expect(r.statusCode, 413);
    });
  });
}
