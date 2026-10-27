// The `codex` style on the native Responses wire (`POST
// /inner/agent/responses`), against the scripted gateway's fake route.

import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/transport.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'codex_loop_test.dart'
    show codexOp, localWorkspace, resultOf, runToEnd, start;
import 'support.dart';
import 'view_image_test.dart' show png;

const compat = 'langgenius/openai_api_compatible/openai_api_compatible';

Map<String, Object?> nativeOp({
  bool shell = false,
  bool viewImage = false,
  String? effort = 'max',
  String? apiType = 'responses',
  Map<String, Object?>? outputSchema,
  Map<String, Object?>? continuation,
  int outputAttempt = 0,
}) {
  final o = codexOp(
    shell: shell,
    viewImage: viewImage,
    effort: effort,
    outputSchema: outputSchema,
    continuation: continuation,
    outputAttempt: outputAttempt,
  );
  final m = o['model'] as Map;
  m['provider'] = compat;
  if (apiType != null) m['api_type'] = apiType;
  return o;
}

Map<String, Object?> message(String text, {String phase = 'final_answer'}) => {
  'type': 'message',
  'role': 'assistant',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
  'phase': phase,
};

Map<String, Object?> reasoning(String encrypted) => {
  'type': 'reasoning',
  'id': 'rs_$encrypted',
  'summary': [
    {'type': 'summary_text', 'text': 'thinking'},
  ],
  'encrypted_content': encrypted,
};

Map<String, Object?> functionCall(String id, String name, Object args) => {
  'type': 'function_call',
  'call_id': id,
  'name': name,
  'arguments': jsonEncode(args),
};

/// The body is the raw Responses request.
Map<String, Object?> requestOf(Map<String, Object?> body) => body;

bool hasAnnotation(Object? v) => switch (v) {
  Map() =>
    v.keys.any((k) => '$k'.startsWith('dify_sf_')) ||
        v.values.any(hasAnnotation),
  List() => v.any(hasAnnotation),
  _ => false,
};

void main() {
  group('channel selection', () {
    OperationRequest parse(Map<String, Object?> o) => OperationRequest.parse(o);
    test('native for openai_api_compatible in Responses mode, codex style', () {
      expect(selectWire(parse(nativeOp())).wire, 'responses');
      final openai = nativeOp(apiType: null);
      (openai['model'] as Map)['provider'] = 'langgenius/openai/openai';
      expect(selectWire(parse(openai)).wire, 'responses');
      final plugin = selectWire(parse(nativeOp(apiType: 'chat')));
      expect(plugin.wire, 'plugin');
      expect(plugin.reducedFidelity, isTrue);
      expect(selectWire(parse(codexOp())).reducedFidelity, isTrue);
      // The Swift server's choice wins.
      final chosen = nativeOp(apiType: null);
      (chosen['model'] as Map)['wire'] = 'responses';
      expect(selectWire(parse(chosen)), (
        wire: 'responses',
        reason: 'model.wire set by the Swift server',
        reducedFidelity: false,
      ));
      (chosen['model'] as Map)['wire'] = 'plugin';
      expect(selectWire(parse(chosen)).reducedFidelity, isTrue);
      final dify = nativeOp()..remove('harness_style');
      expect(selectWire(parse(dify)), (
        wire: 'plugin',
        reason: 'harness_style dify',
        reducedFidelity: false,
      ));
    });

    test('recorded in run_started; the plugin fallback flags reduced '
        'fidelity', () async {
      final (h, _) = await start([ScriptedCall.text('ok')]);
      final (_, events) = await runToEnd(h, nativeOp(apiType: 'chat'));
      expect(events.first.data['model_wire'], {
        'wire': 'plugin',
        'reason': 'model.api_type "chat" is not "responses"',
        'reduced_fidelity': true,
      });
      expect(h.gateway.responsesRequests, isEmpty);
    });
  });

  test('encrypted reasoning round-trips; Codex request body; effort is '
      'provable', () async {
    final (h, _) = await start([
      ScriptedCall.responses(
        [
          reasoning('ENC1'),
          message('Planning first.', phase: 'commentary'),
          functionCall('c1', 'update_plan', {
            'plan': [
              {'step': 'Go', 'status': 'in_progress'},
            ],
          }),
        ],
        summary: ['thinking about it'],
      ),
      ScriptedCall.responses([reasoning('ENC2'), message('Done.')]),
    ]);
    final op = nativeOp();
    (op['tools'] as Map)['update_plan'] = true;
    final (status, events) = await runToEnd(h, op);
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    expect(resultOf(status)['candidate'], {'text': 'Done.'});
    expect(events.first.data['model_wire'], {
      'wire': 'responses',
      'reason': 'openai_api_compatible in Responses mode',
      'reduced_fidelity': false,
    });
    expect(h.gateway.llmRequests, isEmpty);

    final bodies = h.gateway.responsesRequests;
    expect(bodies, hasLength(2));
    final first = requestOf(bodies[0]);
    expect(first['store'], false);
    expect(first['include'], ['reasoning.encrypted_content']);
    expect(first['reasoning'], {'effort': 'max'});
    expect(first['prompt_cache_key'], 'E1');
    expect(first['parallel_tool_calls'], true);
    expect(first['tool_choice'], 'auto');
    expect(first['model'], 'codex/gpt-6.1-terra');
    final headers = h.gateway.responsesHeaders;
    final runId = status['run_id'];
    expect(headers[0]['x-agent-call-index'], '1');
    expect(headers[0]['x-agent-invocation-id'], '$runId:1');
    expect(headers[0]['x-agent-attempt'], '1');
    expect(headers[1]['x-agent-call-index'], '2');
    expect(headers[0]['x-agent-run-token'], runToken);
    expect(first.containsKey('caller'), isFalse);
    final input = (first['input'] as List).cast<Map>();
    expect(
      [for (final i in input) i['role']],
      ['developer', 'developer', 'user', 'user'],
    );
    expect(hasAnnotation(first), isFalse);

    final second = (requestOf(bodies[1])['input'] as List).cast<Map>();
    // The first request's items, then the response verbatim, then the output.
    expect(second.sublist(0, 4), input);
    expect(second[4], reasoning('ENC1'));
    expect(second[5]['phase'], 'commentary');
    expect(second[6]['call_id'], 'c1');
    expect(second[7], {
      'type': 'function_call_output',
      'call_id': 'c1',
      'output': 'Plan updated',
    });

    final calls = [
      for (final e in events)
        if (e.event == 'model_call') e.data,
    ];
    expect(calls.first['wire'], 'responses');
    expect(calls.first['reasoning'], {
      'effort_requested': 'max',
      'effort_sent': 'max',
      'effort_sent_by': 'agent_service',
      'effort_forwarded': 'max',
      'effort_echoed': 'max',
      'summary_sent': null,
      'encrypted_items_in': 0,
      'encrypted_items_out': 1,
      'reasoning_tokens': 12,
      'reasoning_tokens_source': 'provider',
    });
    expect((calls[1]['reasoning'] as Map)['encrypted_items_in'], 1);
    expect(calls.first['usage'], {
      'prompt_tokens': 100,
      'completion_tokens': 20,
      'total_tokens': 120,
      'reasoning_tokens': 12,
      'prompt_cache_hit_tokens': 80,
      'prompt_cache_miss_tokens': 20,
    });
    expect((calls[1]['prompt'] as Map)['prefix_stable'], true);
    expect(
      events.where((e) => e.event == 'thought').first.data['text'],
      'thinking about it',
    );
    expect(events.any((e) => e.event == 'commentary'), isTrue);

    // The snapshot keeps the encrypted items for the next operation.
    final snapshot = resultOf(status)['snapshot'] as Map;
    expect((snapshot['codex'] as Map)['wire'], 'responses');
    final items = (snapshot['items'] as List).cast<Map>();
    expect(items.where((i) => i['encrypted_content'] != null), hasLength(2));
  });

  test('freeform apply_patch: custom tool call and output', () async {
    final dir = newDataDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    final (h, _) = await start(
      [
        ScriptedCall.responses([
          {
            'type': 'custom_tool_call',
            'call_id': 'p1',
            'name': 'apply_patch',
            'input': '*** Begin Patch\n*** Add File: hi.txt\n+hello\n*** End Patch\n',
          },
        ]),
        ScriptedCall.responses([message('Added.')]),
      ],
      shell: true,
      configure: (s) => s.onControl = localWorkspace(dir),
    );
    final (status, _) = await runToEnd(h, nativeOp(shell: true));
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    expect(File('${dir.path}/hi.txt').readAsStringSync(), 'hello\n');
    final tools = (requestOf(h.gateway.responsesRequests[0])['tools'] as List)
        .cast<Map>();
    final patch = tools.firstWhere((t) => t['name'] == 'apply_patch');
    expect(patch['type'], 'custom');
    expect((patch['format'] as Map)['syntax'], 'lark');
    final input = (requestOf(h.gateway.responsesRequests[1])['input'] as List)
        .cast<Map>();
    final out = input.last;
    expect(out['type'], 'custom_tool_call_output');
    expect(out['call_id'], 'p1');
    expect(out['output'], contains('A hi.txt'));
  });

  test('declared outputs go as text.format, not in the prompt', () async {
    final schema = {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    };
    final (h, _) = await start([
      ScriptedCall.responses([message('{"text": "yes"}')]),
    ]);
    final (status, _) = await runToEnd(h, nativeOp(outputSchema: schema));
    expect(resultOf(status)['candidate'], {'text': 'yes'});
    final req = requestOf(h.gateway.responsesRequests.single);
    expect(req['text'], {
      'format': {
        'type': 'json_schema',
        'name': 'codex_output_schema',
        'strict': false,
        'schema': schema,
      },
    });
    expect(jsonEncode(req['input']), isNot(contains('# Final answer format')));
    expect(isStrictSchema({...schema, 'additionalProperties': false}), isTrue);
  });

  test('view_image: the image is inside the tool output', () async {
    final (h, _) = await start(
      [
        ScriptedCall.responses([
          functionCall('v1', 'view_image', {
            'path': 'a.png',
            'detail': 'original',
          }),
        ]),
        ScriptedCall.responses([message('Seen.')]),
      ],
      shell: true,
      configure: (s) => s.files['/workspace/a.png'] = png(8, 8),
    );
    final (status, _) = await runToEnd(
      h,
      nativeOp(shell: true, viewImage: true),
    );
    expect(status['status'], 'succeeded', reason: jsonEncode(status));
    final input = (requestOf(h.gateway.responsesRequests[1])['input'] as List)
        .cast<Map>();
    final out = input.last;
    expect(out['type'], 'function_call_output');
    final image = (out['output'] as List).single as Map;
    expect(image['type'], 'input_image');
    expect(image['detail'], 'original');
    expect(image['image_url'], startsWith('dify-sf-file:up'));
    expect(hasAnnotation(out), isFalse);
  });

  test('failures: rate limits retried, context overflow terminal, '
      'incomplete fails', () async {
    ScriptedCall failed(String code) => ScriptedCall(
      responseEvents: [
        {
          'type': 'response.failed',
          'response': {
            'error': {'code': code, 'message': 'scripted'},
          },
        },
      ],
    );
    final (h, _) = await start([
      failed('rate_limit_exceeded'),
      ScriptedCall.responses([message('ok')]),
    ]);
    final (s1, e1) = await runToEnd(h, nativeOp());
    expect(s1['status'], 'succeeded', reason: jsonEncode(s1));
    expect(
      e1.singleWhere((e) => e.event == 'model_retry').data['kind'],
      'rateLimited',
    );
    final hs = h.gateway.responsesHeaders;
    expect([for (final x in hs) x['x-agent-attempt']], ['1', '2']);
    expect(hs[0]['x-agent-invocation-id'], hs[1]['x-agent-invocation-id']);

    final (h2, _) = await start([failed('context_length_exceeded')]);
    final (s2, _) = await runToEnd(h2, nativeOp());
    expect(s2['status'], 'failed');
    expect(resultOf(s2)['message'], contains('context_length_exceeded'));
    expect(h2.gateway.responsesRequests, hasLength(1));

    final (h3, _) = await start([
      ScriptedCall(
        responseEvents: [
          {
            'type': 'response.incomplete',
            'response': {
              'incomplete_details': {'reason': 'max_output_tokens'},
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            },
          },
        ],
      ),
    ]);
    final (s3, _) = await runToEnd(h3, nativeOp());
    expect(s3['status'], 'failed');
    expect(resultOf(s3)['message'], contains('finish_reason length'));
  });

  test('a snapshot of one wire cannot continue on the other', () async {
    final (h, _) = await start([
      ScriptedCall.responses([message('{"text": "a"}')]),
    ]);
    final schema = {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
    };
    final (status, _) = await runToEnd(h, nativeOp(outputSchema: schema));
    final retry = {
      'kind': 'output_retry',
      'snapshot': resultOf(status)['snapshot'],
      'feedback': [
        {'field': 'text', 'error': 'too short'},
      ],
    };
    final (code, body) = await h.post(
      '/v1/operations',
      nativeOp(
        apiType: null,
        outputSchema: schema,
        outputAttempt: 1,
        continuation: retry,
      ),
    );
    expect(code, 422);
    expect(body['message'], contains('model wire'));
  });
}
