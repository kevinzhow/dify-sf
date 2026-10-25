import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  Future<Map<String, Object?>> failedResult(
    List<ScriptedCall> calls,
    Map<String, Object?> body,
  ) async {
    final h = await Harness.start(calls: calls);
    addTearDown(h.close);
    final runId = await h.startOperation(body);
    final s = await h.waitEnded(runId);
    expect(s['status'], 'failed');
    return (s['result'] as Map).cast<String, Object?>();
  }

  test('max_turns maps to failed max_turns', () async {
    final r = await failedResult([
      for (var i = 0; i < 5; i++) ScriptedCall.toolCall('t$i', 'ask_human', {}),
    ], operation(maxTurns: 2));
    expect(r['error_type'], 'max_turns');
    expect((r['usage'] as Map)['total_tokens'], 30);
  });

  test('timeout maps to failed timeout', () async {
    final sw = Stopwatch()..start();
    final r = await failedResult([
      ScriptedCall(delayMs: 10000, chunks: [ScriptedChunk(text: 'late')]),
    ], operation(timeoutSeconds: 1));
    expect(r['error_type'], 'timeout');
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('gateway -429 maps to model_quota', () async {
    final r = await failedResult([
      ScriptedCall(
        error: {
          'code': -429,
          'error_type': 'AgentLLMQuotaExceededError',
          'message': 'Insufficient quota',
        },
      ),
    ], operation());
    expect(r['error_type'], 'model_quota');
    expect(r['message'], contains('Insufficient quota'));
  });

  test('gateway -500 mid-stream maps to model_error', () async {
    final r = await failedResult([
      ScriptedCall(
        chunks: [ScriptedChunk(text: 'partial')],
        error: {'code': -500, 'error_type': 'ValueError', 'message': 'boom'},
      ),
    ], operation());
    expect(r['error_type'], 'model_error');
    expect(r['message'], contains('boom'));
  });

  test('HTTP 429 from the gateway maps to model_quota', () async {
    final r = await failedResult([ScriptedCall(httpStatus: 429)], operation());
    expect(r['error_type'], 'model_quota');
  });

  test('the shell tool is unavailable without a sandbox', () async {
    final r = await failedResult(const [], operation(shell: true));
    expect(r['error_type'], 'sandbox_unavailable');
  });

  test('a missing input file maps to file_error', () async {
    final r = await failedResult(
      [ScriptedCall.text('x')],
      operation(
        taskParts: [
          {'type': 'file', 'file_id': 'missing', 'mime_type': 'image/png'},
        ],
      ),
    );
    expect(r['error_type'], 'file_error');
  });
}
