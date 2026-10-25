import 'package:agent_service/agent_service.dart';
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

List<Map> promptMessages(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['prompt_messages'] as List).cast<Map>();

List<Map> tools(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['tools'] as List).cast<Map>();

void main() {
  test('declared outputs are the final_output tool; its arguments are the '
      'candidate', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall.toolCall('fo_1', 'final_output', {
          'text': 'good',
          'score': 4,
        }),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation(outputSchema: schema));
    final s = await h.waitEnded(runId);
    expect(s['status'], 'succeeded');
    final result = s['result'] as Map;
    expect(result['candidate'], {'text': 'good', 'score': 4});
    expect(result['candidate_errors'], isEmpty);

    final request = h.gateway.llmRequests.single;
    final finalOutput = tools(request)
        .firstWhere((t) => t['name'] == 'final_output');
    expect(finalOutput['description'], defaultFinalOutputDescription);
    expect(finalOutput['parameters'], {...schema, 'title': 'final_output'});
    expect(tools(request).map((t) => t['name']), contains('ask_human'));
    // No prompt instructions and no response_format.
    final system = promptMessages(request).first;
    expect(system['content'], isNot(contains('"score"')));
    expect(
      (request['target'] as Map)['model_parameters'],
      isNot(contains('response_format')),
    );

    final snapshot = result['snapshot'] as Map;
    final last = (snapshot['messages'] as List).last as Map;
    expect(last['role'], 'tool');
    expect(((last['content'] as List).single as Map)['toolResponse'], {
      'ref': 'fo_1',
      'name': 'final_output',
      'output': finalResultProcessed,
    });
  });

  test('an invalid field succeeds with candidate_errors and no extra call; '
      'output_retry sends the feedback and gets a fixed candidate', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall.toolCall('fo_1', 'final_output', {
          'text': 'good',
          'score': 'high',
        }),
        ScriptedCall.toolCall('fo_2', 'final_output', {
          'text': 'good',
          'score': 0.9,
        }),
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

    final messages = promptMessages(h.gateway.llmRequests[1]);
    final n = messages.length;
    expect(messages[n - 3]['role'], 'assistant');
    expect((messages[n - 3]['tool_calls'] as List).single['id'], 'fo_1');
    expect(messages[n - 2], {
      'role': 'tool',
      'content': finalResultProcessed,
      'name': 'final_output',
      'tool_call_id': 'fo_1',
    });
    expect(messages.last['role'], 'user');
    expect(
      messages.last['content'],
      contains('score: expected number, got string'),
    );
  });

  test('a plain-text answer with declared outputs is a null candidate with '
      'a root error', () async {
    final h = await Harness.start(calls: [ScriptedCall.text('no tool call')]);
    addTearDown(h.close);
    final runId = await h.startOperation(
      operation(outputSchema: schema, askHuman: false),
    );
    final s = await h.waitEnded(runId);
    expect(s['status'], 'succeeded');
    final result = s['result'] as Map;
    expect(result['candidate'], isNull);
    final error = (result['candidate_errors'] as List).single as Map;
    expect(error['field'], '');
    expect(error['error'], contains('final_output'));
  });

  test('final_output ends the turn: other calls of that turn are not '
      'executed (end_strategy early)', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall(
          chunks: [
            ScriptedChunk(
              toolCalls: [
                toolCallDelta(
                  index: 0,
                  id: 'ask_1',
                  name: 'ask_human',
                  arguments: '{"question":"Sure?"}',
                ),
                toolCallDelta(
                  index: 1,
                  id: 'fo_1',
                  name: 'final_output',
                  arguments: '{"text":"a","score":1}',
                ),
                toolCallDelta(
                  index: 2,
                  id: 'fo_2',
                  name: 'final_output',
                  arguments: '{"text":"b","score":2}',
                ),
              ],
            ),
            ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
          ],
        ),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation(outputSchema: schema));
    final events = await h.events(runId);
    final terminal = events.last;
    expect(terminal.event, 'succeeded');
    expect(terminal.data['candidate'], {'text': 'a', 'score': 1});
    expect(
      events.where(
        (e) => e.event == 'tool_call' && e.data['name'] == 'ask_human',
      ),
      isEmpty,
    );
    final last =
        ((terminal.data['snapshot'] as Map)['messages'] as List).last as Map;
    expect(
      [
        for (final p in last['content'] as List)
          ((p as Map)['toolResponse'] as Map)['output'],
      ],
      [toolNotExecuted, finalResultProcessed, outputToolNotUsed],
    );
  });

  test('the schema description becomes the tool description; local \$defs '
      'are inlined; a non-object schema is refused', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall.toolCall('fo', 'final_output', {
          'text': 't',
          'item': {'n': 1},
        }),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(
      operation(
        askHuman: false,
        outputSchema: {
          'type': 'object',
          'description': 'Upload files before calling final_output.',
          'properties': {
            'text': {'type': 'string'},
            'item': {r'$ref': r'#/$defs/Item'},
          },
          r'$defs': {
            'Item': {
              'type': 'object',
              'properties': {
                'n': {'type': 'integer'},
              },
            },
          },
        },
      ),
    );
    final s = await h.waitEnded(runId);
    expect((s['result'] as Map)['candidate_errors'], isEmpty);
    final tool = tools(h.gateway.llmRequests.single).single;
    expect(tool['description'], 'Upload files before calling final_output.');
    expect(tool['parameters'], {
      'type': 'object',
      'title': 'final_output',
      'properties': {
        'text': {'type': 'string'},
        'item': {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer'},
          },
        },
      },
    });

    final (status, json) = await h.post(
      '/v1/operations',
      operation(executionId: 'E2', outputSchema: {'type': 'string'}),
    );
    expect(status, 400);
    expect(json['error'], 'invalid_request');
  });

  test('a non-streamed call: one complete chunk with reasoning, two tool '
      'calls without index, usage and finish reason', () async {
    // Shape the Swift gateway sends when it calls the plugin without
    // streaming (calls that offer tools; see docs/agent-v2.md).
    final h = await Harness.start(
      calls: [
        ScriptedCall(
          chunks: [
            ScriptedChunk(
              reasoning: 'Score it.',
              toolCalls: [
                toolCallDelta(
                  id: 'fo_1',
                  name: 'final_output',
                  arguments: '{"text":"ok","score":3}',
                ),
                toolCallDelta(
                  id: 'fo_2',
                  name: 'final_output',
                  arguments: '{"text":"second","score":1}',
                ),
              ],
              usage: defaultUsage(),
              finishReason: 'tool_calls',
            ),
          ],
        ),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation(outputSchema: schema));
    final s = await h.waitEnded(runId);
    expect(s['status'], 'succeeded');
    final result = s['result'] as Map;
    // Complete calls are kept apart by id; the first final_output wins.
    expect(result['candidate'], {'text': 'ok', 'score': 3});
    expect(result['candidate_errors'], isEmpty);
    final events = await h.events(runId);
    expect(
      events.where((e) => e.event == 'thought').map((e) => e.data['text']),
      ['Score it.'],
    );
    expect(events.where((e) => e.event == 'model_call'), hasLength(1));
    expect(h.gateway.llmRequests, hasLength(1));
  });
}
