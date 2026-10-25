import 'dart:convert';

import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

List<Map<String, Object?>> promptMessages(Map<String, Object?> llmRequest) => [
  for (final m in ((llmRequest['target'] as Map)['prompt_messages'] as List))
    (m as Map).cast<String, Object?>(),
];

void main() {
  test('ask A, answer in a new instance, ask B with the same provider id, '
      'answer, succeed', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall.toolCall('ask_human:0', 'ask_human', {
          'question': 'Which city?',
          'fields': [
            {'type': 'paragraph', 'name': 'city', 'label': 'City'},
          ],
        }),
        // kimi reuses ask_human:0 in a later turn.
        ScriptedCall.toolCall('ask_human:0', 'ask_human', {
          'question': 'Which month?',
        }),
        ScriptedCall.text('Kyoto in April.'),
      ],
    );
    addTearDown(h.close);

    final run1 = await h.startOperation(operation());
    final s1 = await h.waitEnded(run1);
    expect(s1['status'], 'paused');
    final p1 = (s1['result'] as Map).cast<String, Object?>();
    expect(p1['question_id'], 'E1:q1');
    expect(p1['tool_call_id'], 'ask_human:0');
    expect((p1['question'] as Map)['question'], 'Which city?');
    expect((p1['snapshot'] as Map)['revision'], 1);

    // The answer is a new operation on a new service instance.
    await h.restart();
    final run2 = await h.startOperation(
      operation(resumeSequence: 1, continuation: answer(p1, {'city': 'Kyoto'})),
    );
    final s2 = await h.waitEnded(run2);
    expect(s2['status'], 'paused');
    final p2 = (s2['result'] as Map).cast<String, Object?>();
    expect(p2['question_id'], 'E1:q2');
    expect(p2['tool_call_id'], 'ask_human:0');
    expect((p2['question'] as Map)['question'], 'Which month?');
    final snap2 = (p2['snapshot'] as Map).cast<String, Object?>();
    expect(snap2['revision'], 2);
    expect(snap2['resume_sequence'], 1);
    expect(snap2['pending'], {
      'question_id': 'E1:q2',
      'tool_call_id': 'ask_human:0',
    });

    // The second model request answers the ORIGINAL tool call.
    final second = promptMessages(h.gateway.llmRequests[1]);
    final assistant = second.lastWhere((m) => m['role'] == 'assistant');
    expect((assistant['tool_calls'] as List).single, {
      'id': 'ask_human:0',
      'type': 'function',
      'function': {
        'name': 'ask_human',
        'arguments': jsonEncode({
          'question': 'Which city?',
          'fields': [
            {'type': 'paragraph', 'name': 'city', 'label': 'City'},
          ],
        }),
      },
    });
    final tool = second.last;
    expect(tool['role'], 'tool');
    expect(tool['tool_call_id'], 'ask_human:0');
    expect(tool['name'], 'ask_human');
    expect(jsonDecode(tool['content'] as String), {
      'status': 'submitted',
      'action': {'id': 'submit', 'label': 'Submit'},
      'values': {'city': 'Kyoto'},
      'rendered_content': 'answered',
    });
    final events2 = await h.events(run2);
    expect(events2[1].event, 'tool_call');
    expect(events2[1].data['phase'], 'finished');
    expect(events2[1].data['id'], 'ask_human:0');

    // Answering the old question again for the next resume is refused.
    final (stale, staleJson) = await h.post(
      '/v1/operations',
      operation(resumeSequence: 2, continuation: answer(p1, {'city': 'Oslo'})),
    );
    expect(stale, 422);
    expect(staleJson['error'], 'snapshot_incompatible');

    final run3 = await h.startOperation(
      operation(
        resumeSequence: 2,
        continuation: answer(p2, {'month': 'April'}),
      ),
    );
    final s3 = await h.waitEnded(run3);
    expect(s3['status'], 'succeeded');
    expect((s3['result'] as Map)['candidate'], {'text': 'Kyoto in April.'});

    final third = promptMessages(h.gateway.llmRequests[2]);
    final tools = third.where((m) => m['role'] == 'tool').toList();
    expect(tools.map((m) => m['tool_call_id']), ['ask_human:0', 'ask_human:0']);
    expect(
      tools.map((m) => (jsonDecode(m['content'] as String) as Map)['values']),
      [
        {'city': 'Kyoto'},
        {'month': 'April'},
      ],
    );
    expect(h.gateway.llmRequests, hasLength(3));
    // Every request carried the run token and a fresh invocation id.
    final ids = h.gateway.llmRequests
        .map((r) => (r['caller'] as Map)['invocation_id'])
        .toSet();
    expect(ids, hasLength(3));
    expect(
      h.gateway.requests.every(
        (r) => r.headers['x-agent-run-token'] == runToken,
      ),
      isTrue,
    );
  });

  test('two ask_human calls in one turn fail with ask_human_invalid', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall(
          chunks: [
            // Two interleaved calls; later deltas carry only the index.
            ScriptedChunk(
              toolCalls: [
                toolCallDelta(
                  index: 0,
                  id: 'a',
                  name: 'ask_human',
                  arguments: '{"question"',
                ),
              ],
            ),
            ScriptedChunk(
              toolCalls: [
                toolCallDelta(
                  index: 1,
                  id: 'b',
                  name: 'ask_human',
                  arguments: '{"question"',
                ),
              ],
            ),
            ScriptedChunk(
              toolCalls: [toolCallDelta(index: 0, arguments: ':"A?"}')],
            ),
            ScriptedChunk(
              toolCalls: [toolCallDelta(index: 1, arguments: ':"B?"}')],
            ),
            ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
          ],
        ),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    final s = await h.waitEnded(runId);
    expect(s['status'], 'failed');
    final result = s['result'] as Map;
    expect(result['error_type'], 'ask_human_invalid');
    expect(result['message'], contains('got 2'));
    expect(h.gateway.llmRequests, hasLength(1));
  });

  test(
    'index-only continuation deltas form one call with the provider id',
    () async {
      final h = await Harness.start(
        calls: [
          ScriptedCall(
            chunks: [
              ScriptedChunk(
                toolCalls: [
                  toolCallDelta(
                    index: 0,
                    id: 'call_7',
                    name: 'ask_human',
                    arguments: '{"ques',
                  ),
                ],
              ),
              ScriptedChunk(
                toolCalls: [toolCallDelta(index: 0, arguments: 'tion": "Wh')],
              ),
              ScriptedChunk(
                toolCalls: [toolCallDelta(index: 0, arguments: 'en?"}')],
              ),
              ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
            ],
          ),
        ],
      );
      addTearDown(h.close);
      final runId = await h.startOperation(operation());
      final s = await h.waitEnded(runId);
      expect(s['status'], 'paused');
      final result = s['result'] as Map;
      expect(result['tool_call_id'], 'call_7');
      expect((result['question'] as Map)['question'], 'When?');
    },
  );

  for (final form in ['reasoning_content', 'think_tag']) {
    test(
      'reasoning ($form) survives a pause and is sent back on resume',
      () async {
        final first = form == 'reasoning_content'
            ? ScriptedCall(
                chunks: [
                  ScriptedChunk(reasoning: 'I need '),
                  ScriptedChunk(reasoning: 'the city.'),
                  ScriptedChunk(
                    toolCalls: [
                      toolCallDelta(
                        id: 'ask_human:0',
                        name: 'ask_human',
                        arguments: '{"question":"City?"}',
                      ),
                    ],
                  ),
                  ScriptedChunk(
                    usage: defaultUsage(),
                    finishReason: 'tool_calls',
                  ),
                ],
              )
            : ScriptedCall(
                chunks: [
                  ScriptedChunk(text: '<think>\nI need '),
                  ScriptedChunk(text: 'the city.\n</thi'),
                  ScriptedChunk(
                    text: 'nk>',
                    toolCalls: [
                      toolCallDelta(
                        id: 'ask_human:0',
                        name: 'ask_human',
                        arguments: '{"question":"City?"}',
                      ),
                    ],
                  ),
                  ScriptedChunk(
                    usage: defaultUsage(),
                    finishReason: 'tool_calls',
                  ),
                ],
              );
        final h = await Harness.start(
          calls: [first, ScriptedCall.text('Kyoto.')],
        );
        addTearDown(h.close);
        final run1 = await h.startOperation(operation());
        final s1 = await h.waitEnded(run1);
        expect(s1['status'], 'paused');
        final thoughts = (await h.events(run1))
            .where((e) => e.event == 'thought')
            .map((e) => e.data['text'])
            .join();
        expect(thoughts, contains('I need the city.'));

        await h.restart();
        final run2 = await h.startOperation(
          operation(
            resumeSequence: 1,
            continuation: answer(
              (s1['result'] as Map).cast<String, Object?>(),
              {'city': 'Kyoto'},
            ),
          ),
        );
        final s2 = await h.waitEnded(run2);
        expect(s2['status'], 'succeeded');
        expect((s2['result'] as Map)['candidate'], {'text': 'Kyoto.'});

        final assistant = promptMessages(h.gateway.llmRequests[1])
            .lastWhere((m) => m['role'] == 'assistant');
        if (form == 'reasoning_content') {
          expect(assistant['reasoning_content'], 'I need the city.');
          expect(assistant['content'], '');
        } else {
          expect(assistant.containsKey('reasoning_content'), isFalse);
          expect(assistant['content'], '<think>\nI need the city.\n</think>');
        }
      },
    );
  }
}
