import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A PNG header (signature and IHDR) of [w] x [h], padded to [size] bytes.
List<int> png(int w, int h, {int size = 64}) {
  int b(int v, int s) => (v >> s) & 0xff;
  final head = [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    0, 0, 0, 13, ...'IHDR'.codeUnits,
    b(w, 24), b(w, 16), b(w, 8), b(w, 0),
    b(h, 24), b(h, 16), b(h, 8), b(h, 0),
    8, 6, 0, 0, 0,
  ];
  return [...head, ...List.filled(size - head.length, 7)];
}

Future<Harness> startShell(
  List<ScriptedCall> calls, {
  Map<String, List<int>> files = const {},
}) async {
  final sup = FakeSupervisor(
    key: testSupervisorKey,
    configure: (s) {
      s.files.addAll(files);
      s.onJob = (_) => FakeJobSpec(output: 'ok\r\n');
    },
  );
  await sup.start();
  final h = await Harness.start(calls: calls, supervisorUrl: sup.url);
  addTearDown(() async {
    await h.close();
    await sup.close();
  });
  return h;
}

ScriptedCall toolCalls(List<(String, String, Map<String, Object?>)> calls) =>
    ScriptedCall(
      chunks: [
        ScriptedChunk(
          toolCalls: [
            for (final (i, (id, name, args)) in calls.indexed)
              toolCallDelta(
                index: i,
                id: id,
                name: name,
                arguments: jsonEncode(args),
              ),
          ],
        ),
        ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
      ],
    );

Map<String, Object?> progressOp({int maxTurns = 10}) => {
  ...operation(shell: true, askHuman: false, maxTurns: maxTurns),
  'tools': {'ask_human': false, 'shell': true, 'report_progress': true},
};

List<Map> messagesOf(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['prompt_messages'] as List).cast<Map>();

void main() {
  test('report_progress uploads the image, emits progress and gives the '
      'model text only; the run goes on', () async {
    final image = png(800, 600, size: 2048);
    final h = await startShell(
      [
        ScriptedCall.toolCall('p1', 'report_progress', {
          'path': 'out/render.png',
          'caption': 'First render of the facade',
        }),
        ScriptedCall.text('done'),
      ],
      files: {'/workspace/out/render.png': image},
    );
    final run = await h.startOperation(progressOp());
    final s = await h.waitEnded(run);
    expect(s['status'], 'succeeded', reason: jsonEncode(s));

    final tools =
        ((h.gateway.llmRequests.first['target'] as Map)['tools'] as List).map(
          (t) => (t as Map)['name'],
        );
    expect(tools.last, 'report_progress');

    final uploadId = h.gateway.uploads.keys.single;
    expect(h.gateway.uploads[uploadId], image);
    final events = await h.events(run);
    final progress = events.singleWhere((e) => e.event == 'progress');
    expect(progress.data, {
      'file': {
        'upload_id': uploadId,
        'filename': 'render.png',
        'mime_type': 'image/png',
        'size': 2048,
      },
      'caption': 'First render of the facade',
      'call_index': 1,
    });
    // Between the tool call's start and finish.
    final names = events.map((e) => e.event).toList();
    expect(
      names.sublist(
        names.indexOf('progress') - 1,
        names.indexOf('progress') + 2,
      ),
      ['tool_call', 'progress', 'tool_call'],
    );
    // Never in the model's context.
    final second = h.gateway.llmRequests[1];
    expect(jsonEncode(second), isNot(contains(uploadId)));
    expect(
      messagesOf(second).last['content'],
      'Progress reported: out/render.png with your caption (1 of at most '
      '$progressMaxPerRun in this run).',
    );
  });

  test('problems are tool errors: caption, format, size, path; at most '
      '$progressMaxPerRun per run', () async {
    final h = await startShell(
      [
        toolCalls([
          ('a', 'report_progress', {'path': 'a.png', 'caption': ''}),
          (
            'b',
            'report_progress',
            {'path': 'a.png', 'caption': 'x' * (progressCaptionMaxChars + 1)},
          ),
          ('c', 'report_progress', {'path': 'notes.png', 'caption': 'c'}),
          ('d', 'report_progress', {'path': 'big.png', 'caption': 'd'}),
          ('e', 'report_progress', {'path': 'missing.png', 'caption': 'e'}),
        ]),
        toolCalls([
          for (var i = 0; i <= progressMaxPerRun; i++)
            ('m$i', 'report_progress', {'path': 'a.png', 'caption': 'n $i'}),
        ]),
        ScriptedCall.text('ok'),
      ],
      files: {
        '/workspace/a.png': png(2, 2),
        '/workspace/notes.png': utf8.encode('text'),
        '/workspace/big.png': png(9, 9, size: progressImageBytes + 1),
      },
    );
    final run = await h.startOperation(progressOp());
    final s = await h.waitEnded(run);
    expect(s['status'], 'succeeded', reason: jsonEncode(s));
    final first = {
      for (final m in messagesOf(h.gateway.llmRequests[1]))
        if (m['role'] == 'tool') m['tool_call_id']: m['content'] as String,
    };
    expect(first['a'], contains('caption is required'));
    expect(first['b'], contains('at most $progressCaptionMaxChars'));
    expect(first['c'], contains('is not a PNG, JPEG or WebP image'));
    expect(first['d'], contains('at most $progressImageBytes bytes'));
    expect(first['e'], contains('does not exist'));
    final second = [
      for (final m in messagesOf(h.gateway.llmRequests[2]))
        if (m['role'] == 'tool' &&
            (m['tool_call_id'] as String).startsWith('m'))
          m['content'] as String,
    ];
    expect(second.where((t) => t.contains('the most it may')), hasLength(1));
    final progress = (await h.events(run)).where((e) => e.event == 'progress');
    expect(progress, hasLength(progressMaxPerRun));
  });

  test('tools.report_progress needs the shell; the flag adds the tool and '
      'changes the tool definitions digest', () async {
    final h = await Harness.start();
    addTearDown(h.close);
    final (s, j) = await h.post('/v1/operations', {
      ...operation(),
      'tools': {'ask_human': true, 'shell': false, 'report_progress': true},
    });
    expect((s, j['error']), (400, 'invalid_request'));
    final withTool = OperationRequest.parse(progressOp());
    final without = OperationRequest.parse(
      operation(shell: true, askHuman: false),
    );
    expect(
      toolDefinitions(withTool).map((t) => t['name']),
      contains('report_progress'),
    );
    expect(
      toolDefinitionsDigest(withTool),
      isNot(toolDefinitionsDigest(without)),
    );
  });
}
