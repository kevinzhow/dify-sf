import 'package:agent_service/agent_service.dart';
import 'package:genkit/genkit.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, Object?> chunk({
  String? content,
  String? reasoning,
  List<Map<String, Object?>>? toolCalls,
  Map<String, Object?>? usage,
  String? finish,
}) => {
  'delta': {
    'message': {
      'role': 'assistant',
      'content': content ?? '',
      'tool_calls': toolCalls ?? const <Object?>[],
      'reasoning_content': ?reasoning,
    },
    'usage': usage,
    'finish_reason': finish,
  },
};

void main() {
  group('request digest', () {
    test('ignores generation and key order', () {
      final a = operation(generation: 1);
      final b = Map<String, Object?>.fromEntries(
        operation(generation: 7).entries.toList().reversed,
      );
      expect(requestDigest(a), requestDigest(b));
      expect(requestDigest(a), isNot(requestDigest(operation(task: 'other'))));
    });

    test('canonical JSON sorts keys recursively', () {
      expect(
        canonicalJson({
          'b': [
            {'y': 1, 'x': 2},
          ],
          'a': null,
        }),
        '{"a":null,"b":[{"x":2,"y":1}]}',
      );
    });
  });

  test('reserved env names', () {
    for (final n in [
      'HOME',
      'path',
      'TMPDIR',
      'tmp',
      'TEMP',
      'SHELLCTL_SOCKET',
      'https_proxy',
      'HTTP_PROXY',
      'no_proxy',
    ]) {
      expect(isReservedEnvName(n), isTrue, reason: n);
    }
    for (final n in ['API_KEY', 'PROXY_HOST', 'HOMEPAGE']) {
      expect(isReservedEnvName(n), isFalse, reason: n);
    }
  });

  group('think parser', () {
    test('splits tags across chunk boundaries', () {
      final p = ThinkParser();
      final pieces = [
        ...p.parse('Hi <thi'),
        ...p.parse('nk>reason'),
        ...p.parse('ing</th'),
        ...p.parse('ink> there<'),
        ...p.flush(),
      ];
      final thinking = pieces.where((e) => e.$1).map((e) => e.$2).join();
      final text = pieces.where((e) => !e.$1).map((e) => e.$2).join();
      expect(thinking, 'reasoning');
      expect(text, 'Hi  there<');
    });
  });

  group('tool call merge', () {
    test('index-only continuation deltas join the call with that index', () {
      final acc = LlmAccumulator();
      acc.add(
        chunk(
          toolCalls: [
            toolCallDelta(
              index: 0,
              id: 'call_a',
              name: 'ask_human',
              arguments: '{"qu',
            ),
          ],
        ),
      );
      acc.add(
        chunk(toolCalls: [toolCallDelta(index: 0, arguments: 'estion"')]),
      );
      acc.add(chunk(toolCalls: [toolCallDelta(index: 0, arguments: ':"A?"}')]));
      expect(acc.toolCalls, hasLength(1));
      expect(acc.toolCalls.single.id, 'call_a');
      expect(acc.toolCalls.single.name.toString(), 'ask_human');
      expect(acc.toolCalls.single.arguments.toString(), '{"question":"A?"}');
    });

    test('two interleaved calls merge by index, id set by the first delta', () {
      final acc = LlmAccumulator();
      acc.add(
        chunk(
          toolCalls: [toolCallDelta(index: 0, name: 'get_', arguments: '{"a"')],
        ),
      );
      acc.add(
        chunk(
          toolCalls: [
            toolCallDelta(index: 1, id: 'b', name: 'put', arguments: '{"b"'),
          ],
        ),
      );
      acc.add(
        chunk(
          toolCalls: [
            toolCallDelta(index: 0, id: 'a', name: 'x', arguments: ':1}'),
          ],
        ),
      );
      acc.add(
        chunk(
          toolCalls: [toolCallDelta(index: 1, id: 'ignored', arguments: ':2}')],
        ),
      );
      expect(acc.toolCalls.map((c) => c.id), ['a', 'b']);
      expect(acc.toolCalls.map((c) => c.name.toString()), ['get_x', 'put']);
      expect(acc.toolCalls.map((c) => c.arguments.toString()), [
        '{"a":1}',
        '{"b":2}',
      ]);
    });

    test('id-only deltas match by id; interleaving keeps order', () {
      final acc = LlmAccumulator();
      acc.add(
        chunk(
          toolCalls: [toolCallDelta(id: 'x', name: 'f', arguments: '[1')],
        ),
      );
      acc.add(
        chunk(
          toolCalls: [toolCallDelta(id: 'y', name: 'g', arguments: '[2')],
        ),
      );
      acc.add(
        chunk(
          toolCalls: [toolCallDelta(id: 'x', arguments: ']')],
        ),
      );
      acc.add(
        chunk(
          toolCalls: [toolCallDelta(id: 'y', arguments: ']')],
        ),
      );
      expect(acc.toolCalls.map((c) => '${c.id}:${c.arguments}'), [
        'x:[1]',
        'y:[2]',
      ]);
    });

    test('a call without any id gets a generated one', () {
      final acc = LlmAccumulator()
        ..add(
          chunk(
            toolCalls: [toolCallDelta(index: 0, name: 'f', arguments: '{}')],
          ),
        )
        ..assignMissingIds();
      expect(acc.toolCalls.single.id, startsWith('call_'));
    });
  });

  test('reasoning from both forms, usage last, finish first', () {
    final acc = LlmAccumulator();
    acc.add(chunk(reasoning: 'field '));
    acc.add(chunk(content: '<think>\ntag\n</think>', reasoning: 'more'));
    acc.add(
      chunk(content: 'answer', finish: 'stop', usage: {'prompt_tokens': 1}),
    );
    acc.add(chunk(usage: {'prompt_tokens': 2}, finish: 'length'));
    expect(acc.fieldReasoning.toString(), 'field more');
    expect(acc.thinkReasoning.toString(), '\ntag\n');
    expect(acc.answer.toString(), 'answer');
    expect(acc.usage, {'prompt_tokens': 2});
    expect(acc.finishReason, 'stop');
    final m = responseMessage(acc);
    expect(m.content.map((p) => p.isReasoning ? 'reasoning' : 'text'), [
      'reasoning',
      'reasoning',
      'text',
    ]);
    expect(m.content.first.metadata?[reasoningFormKey], 'think_tag');
    expect(m.content.first.reasoning, 'tag');
  });

  test('usage sums; reasoning_tokens stays null unless reported', () {
    final total = Usage()
      ..add(Usage.fromDify({'prompt_tokens': 3, 'completion_tokens': 2}));
    expect(total.toJson(), {
      'prompt_tokens': 3,
      'completion_tokens': 2,
      'total_tokens': 5,
      'reasoning_tokens': null,
    });
    total.add(
      Usage.fromDify({
        'prompt_tokens': 1,
        'completion_tokens': 4,
        'total_tokens': 5,
        'completion_tokens_details': {'reasoning_tokens': 3},
      }),
    );
    expect(total.toJson()['reasoning_tokens'], 3);
    expect(total.toJson()['total_tokens'], 10);
  });

  test('candidate errors are reported per field', () async {
    final schema = {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'score': {'type': 'number'},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['text', 'score'],
    };
    final errors = await candidateErrors(schema, {
      'score': 'high',
      'tags': [1],
    });
    expect(
      errors.map((e) => e['field']),
      unorderedEquals(['text', 'score', 'tags']),
    );
    expect(await candidateErrors(schema, {'text': 't', 'score': 1}), isEmpty);
  });

  group('ask_human arguments', () {
    test('normalizes the default Submit action', () {
      final args = normalizeAskHumanArgs({'question': 'City?'});
      expect(args['actions'], [
        {'id': 'submit', 'label': 'Submit', 'style': 'primary'},
      ]);
      expect(args['urgency'], 'normal');
    });

    test('rejects out-of-policy calls as Dify does', () {
      for (final bad in [
        <String, Object?>{},
        {'question': '   '},
        {'question': 'q', 'extra': 1},
        {
          'question': 'q',
          'fields': [
            {'type': 'file', 'name': 'f', 'label': 'F'},
          ],
        },
        {
          'question': 'q',
          'fields': [
            {
              'type': 'select',
              'name': 's',
              'label': 'S',
              'options': <Object?>[],
            },
          ],
        },
        {'question': 'x' * 1001},
        {
          'question': 'q',
          'actions': [
            for (var i = 0; i < 5; i++) {'id': 'a$i', 'label': 'A'},
          ],
        },
      ]) {
        expect(
          () => normalizeAskHumanArgs(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  test('a run left running by a crashed process loads as failed internal', () {
    final dir = newDataDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = RunStore(dir.path)..load();
    final request = OperationRequest.parse(operation());
    final run = store.createRun(request, request.digest);
    store.append(run, 'run_started', {});
    // No finish: the process "dies" here.
    final reloaded = RunStore(dir.path)..load();
    final r = reloaded.run(run.runId)!;
    expect(r.status, 'failed');
    expect(r.result!.data['error_type'], 'internal');
    expect(r.lastEventId, 2);
    expect(reloaded.eventsAfter(r, 0).map((e) => e.event), [
      'run_started',
      'failed',
    ]);
    expect(reloaded.execution('E1')!.operations['E1:0:0']!.runId, run.runId);
  });
}
