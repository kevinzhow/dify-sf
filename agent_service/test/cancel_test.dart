import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  Future<void> cancelPromptly(Harness h, String runId) async {
    final sw = Stopwatch()..start();
    final (s, j) = await h.post('/v1/runs/$runId/cancel', {
      'protocol': protocolName,
      'generation': 1,
    });
    expect(s, 202);
    expect(j['run_id'], runId);
    final ended = await h.waitEnded(runId);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(ended['status'], 'cancelled');
    expect((ended['result'] as Map)['usage'], isA<Map>());
    await h.gateway.observations.single.closedByClient.future.timeout(
      const Duration(seconds: 1),
    );
    // A second cancel answers 409 with the result.
    final (s2, j2) = await h.post('/v1/runs/$runId/cancel', {
      'protocol': protocolName,
      'generation': 1,
    });
    expect(s2, 409);
    expect(j2['result'], ended['result']);
  }

  test('cancel before the first chunk', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall(delayMs: 10000, chunks: [ScriptedChunk(text: 'late')]),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    await until(() => h.gateway.observations.isNotEmpty);
    await cancelPromptly(h, runId);
  });

  test('cancel mid-stream', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall(
          chunkDelayMs: 300,
          chunks: [
            for (var i = 0; i < 20; i++) ScriptedChunk(reasoning: 'step $i '),
          ],
        ),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    // Reasoning is buffered per model call, so wait for the stream itself.
    await until(() => h.gateway.observations.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await cancelPromptly(h, runId);
    final events = await h.events(runId);
    expect(events.last.event, 'cancelled');
    // Nothing is emitted after the terminal event.
    expect(events.where((e) => e.event == 'cancelled'), hasLength(1));
  });

  test('lease expiry cancels a running operation with cancel_lost', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall(hang: true, chunks: [ScriptedChunk(reasoning: '…')]),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    final (s, _) = await h.post('/v1/executions/E1/lease', {
      'protocol': protocolName,
      'generation': 1,
      'ttl_seconds': 1,
    });
    expect(s, 200);
    final ended = await h.waitEnded(runId, timeout: const Duration(seconds: 4));
    expect(ended['status'], 'failed');
    expect((ended['result'] as Map)['error_type'], 'cancel_lost');
    await h.gateway.observations.single.closedByClient.future.timeout(
      const Duration(seconds: 1),
    );
  });

  test('a renewed lease keeps the run alive', () async {
    final h = await Harness.start(
      calls: [ScriptedCall.text('ok', delayMs: 1500)],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    for (var i = 0; i < 3; i++) {
      await h.post('/v1/executions/E1/lease', {
        'protocol': protocolName,
        'generation': 1,
        'ttl_seconds': 1,
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    final ended = await h.waitEnded(runId);
    expect(ended['status'], 'succeeded');
  });
}
