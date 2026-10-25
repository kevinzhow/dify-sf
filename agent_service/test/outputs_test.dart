import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

const schema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string'},
    'score': {'type': 'number'},
  },
  'required': ['text', 'score'],
};

void main() {
  test(
    'a valid candidate has no errors; the schema reaches the model',
    () async {
      final h = await Harness.start(
        calls: [
          ScriptedCall.text('```json\n{"text": "good", "score": 4}\n```'),
        ],
      );
      addTearDown(h.close);
      final runId = await h.startOperation(
        operation(outputSchema: schema, askHuman: false),
      );
      final s = await h.waitEnded(runId);
      expect(s['status'], 'succeeded');
      final result = s['result'] as Map;
      expect(result['candidate'], {'text': 'good', 'score': 4});
      expect(result['candidate_errors'], isEmpty);
      final system =
          (((h.gateway.llmRequests.single['target'] as Map)['prompt_messages']
                      as List)
                  .first
              as Map);
      expect(system['role'], 'system');
      expect(system['content'], contains('"score"'));
    },
  );

  test('an invalid field succeeds with candidate_errors and no extra call; '
      'output_retry sends the feedback and gets a fixed candidate', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall.text('{"text": "good", "score": "high"}'),
        ScriptedCall.text('{"text": "good", "score": 0.9}'),
      ],
    );
    addTearDown(h.close);
    final run1 = await h.startOperation(
      operation(outputSchema: schema, askHuman: false),
    );
    final s1 = await h.waitEnded(run1);
    expect(s1['status'], 'succeeded');
    final r1 = (s1['result'] as Map).cast<String, Object?>();
    expect(r1['candidate'], {'text': 'good', 'score': 'high'});
    final errors = (r1['candidate_errors'] as List).cast<Map>();
    expect(errors.single['field'], 'score');
    expect(errors.single['error'], contains('number'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.gateway.llmRequests, hasLength(1));

    final run2 = await h.startOperation(
      operation(
        outputAttempt: 1,
        outputSchema: schema,
        askHuman: false,
        continuation: {
          'kind': 'output_retry',
          'snapshot': r1['snapshot'],
          'feedback': [
            {'field': 'score', 'error': 'expected number, got string'},
          ],
        },
      ),
    );
    final s2 = await h.waitEnded(run2);
    expect(s2['status'], 'succeeded');
    final r2 = s2['result'] as Map;
    expect(r2['candidate'], {'text': 'good', 'score': 0.9});
    expect(r2['candidate_errors'], isEmpty);
    expect((r2['snapshot'] as Map)['revision'], 2);
    expect((r2['snapshot'] as Map)['output_attempt'], 1);

    final messages =
        ((h.gateway.llmRequests[1]['target'] as Map)['prompt_messages'] as List)
            .cast<Map>();
    expect(messages[messages.length - 2]['role'], 'assistant');
    expect(
      messages[messages.length - 2]['content'],
      '{"text": "good", "score": "high"}',
    );
    expect(messages.last['role'], 'user');
    expect(
      messages.last['content'],
      contains('score: expected number, got string'),
    );
    // The schema instructions are not duplicated on the retry.
    final system = messages.first['content'] as String;
    expect('Output should be in JSON format'.allMatches(system), hasLength(1));
  });

  test(
    'a non-JSON final answer is a null candidate with a root error',
    () async {
      final h = await Harness.start(calls: [ScriptedCall.text('no json here')]);
      addTearDown(h.close);
      final runId = await h.startOperation(
        operation(outputSchema: schema, askHuman: false),
      );
      final s = await h.waitEnded(runId);
      expect(s['status'], 'succeeded');
      final result = s['result'] as Map;
      expect(result['candidate'], isNull);
      expect((result['candidate_errors'] as List).single['field'], '');
    },
  );
}
