import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('<think> split across chunks becomes thought events, not answer text; '
      'it is kept in history and sent back as a think tag', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall(
          chunks: [
            ScriptedChunk(text: '<thi'),
            ScriptedChunk(text: 'nk>\nLet me rea'),
            ScriptedChunk(text: 'son.\n</th'),
            ScriptedChunk(
              text: 'ink>',
              // An invalid ask_human call: the model reads the error, and the
              // loop calls it again with the history.
              toolCalls: [
                toolCallDelta(id: 'c1', name: 'ask_human', arguments: '{}'),
              ],
            ),
            ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
          ],
        ),
        ScriptedCall(
          chunks: [
            ScriptedChunk(text: '<think>again</think>The '),
            ScriptedChunk(text: 'answer.'),
            ScriptedChunk(
              usage: defaultUsage(prompt: 20, completion: 7, reasoning: 3),
              finishReason: 'stop',
            ),
          ],
        ),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    final events = await h.events(runId);
    final thoughts = events
        .where((e) => e.event == 'thought')
        .map((e) => e.data['text'])
        .join();
    expect(thoughts, '\nLet me reason.\nagain');
    final terminal = events.last;
    expect(terminal.event, 'succeeded');
    expect(terminal.data['candidate'], {'text': 'The answer.'});

    final toolEvents = events.where((e) => e.event == 'tool_call').toList();
    expect(toolEvents.map((e) => e.data['phase']), ['started', 'finished']);
    expect(toolEvents.last.data['error'], contains('question'));

    final second =
        ((h.gateway.llmRequests[1]['target'] as Map)['prompt_messages'] as List)
            .cast<Map>();
    final assistant = second.lastWhere((m) => m['role'] == 'assistant');
    expect(assistant['content'], '<think>\nLet me reason.\n</think>');
    expect((assistant['tool_calls'] as List).single['id'], 'c1');
    expect(second.last['role'], 'tool');
    expect(second.last['content'], contains('Fix the errors and try again'));

    // Usage summed over both calls; reasoning reported by the second only.
    final calls = events.where((e) => e.event == 'model_call').toList();
    expect(calls.map((e) => e.data['invocation_id']), ['$runId:1', '$runId:2']);
    expect(terminal.data['usage'], {
      'prompt_tokens': 30,
      'completion_tokens': 12,
      'total_tokens': 42,
      'reasoning_tokens': 3,
    });
  });

  test('reasoning_tokens stays null when no call reports it', () async {
    final h = await Harness.start(
      calls: [
        ScriptedCall.toolCall('t1', 'ask_human', {}),
        ScriptedCall.text('done'),
      ],
    );
    addTearDown(h.close);
    final runId = await h.startOperation(operation());
    final s = await h.waitEnded(runId);
    expect((s['result'] as Map)['usage'], {
      'prompt_tokens': 20,
      'completion_tokens': 10,
      'total_tokens': 30,
      'reasoning_tokens': null,
    });
  });

  test(
    'image task parts are sent as Dify image content with a fresh URL',
    () async {
      final h = await Harness.start(
        calls: [ScriptedCall.text('a cat')],
        files: {
          'F1': {'mime_type': 'image/png', 'size': 3},
        },
      );
      addTearDown(h.close);
      final runId = await h.startOperation(
        operation(
          askHuman: false,
          taskParts: [
            {'type': 'text', 'text': 'What is this?'},
            {'type': 'file', 'file_id': 'F1', 'mime_type': 'image/png'},
          ],
        ),
      );
      final s = await h.waitEnded(runId);
      expect(s['status'], 'succeeded');
      final user =
          ((h.gateway.llmRequests.single['target'] as Map)['prompt_messages']
                  as List)
              .cast<Map>()
              .firstWhere((m) => m['role'] == 'user');
      final content = (user['content'] as List).cast<Map>();
      expect(content.first, {'type': 'text', 'data': 'What is this?'});
      expect(content.last['type'], 'image');
      expect(content.last['mime_type'], 'image/png');
      expect(content.last['url'], 'dify-sf-file:F1');
      final snapshot = (s['result'] as Map)['snapshot'] as Map;
      expect(snapshot['file_ids'], ['F1']);
      expect(snapshot.toString(), isNot(contains('/files/F1')));
      // The model path never asks for a signed URL.
      expect(
        h.gateway.requests.where(
          (r) => r.path == '/inner/agent/files/download-request',
        ),
        isEmpty,
      );
    },
  );
}
