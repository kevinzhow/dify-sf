import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:genkit/genkit.dart';
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

/// A JPEG with an APP0 segment and a baseline SOF0 of [w] x [h].
List<int> jpeg(int w, int h) => [
  0xff, 0xd8, //
  0xff, 0xe0, 0, 16, ...'JFIF'.codeUnits, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
  0xff, 0xc0, 0, 17, 8, h >> 8, h & 0xff, w >> 8, w & 0xff, 3,
  1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
  0xff, 0xd9,
];

/// A WebP (VP8X) of [w] x [h].
List<int> webp(int w, int h) => [
  ...'RIFF'.codeUnits, 30, 0, 0, 0, ...'WEBP'.codeUnits, //
  ...'VP8X'.codeUnits, 10, 0, 0, 0, 0, 0, 0, 0,
  (w - 1) & 0xff, ((w - 1) >> 8) & 0xff, ((w - 1) >> 16) & 0xff,
  (h - 1) & 0xff, ((h - 1) >> 8) & 0xff, ((h - 1) >> 16) & 0xff,
];

Future<(Harness, FakeSupervisor)> startViewing(
  List<ScriptedCall> calls, {
  Map<String, List<int>> files = const {},
  Map<String, String> symlinks = const {},
}) async {
  final sup = FakeSupervisor(
    key: testSupervisorKey,
    configure: (s) {
      s.files.addAll(files);
      s.symlinks.addAll(symlinks);
      s.onJob = (_) => FakeJobSpec(output: 'ok\r\n');
    },
  );
  await sup.start();
  final h = await Harness.start(calls: calls, supervisorUrl: sup.url);
  addTearDown(() async {
    await h.close();
    await sup.close();
  });
  return (h, sup);
}

List<Map> messagesOf(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['prompt_messages'] as List).cast<Map>();

List<Map> imagePartsOf(Map<String, Object?> llmRequest) => [
  for (final m in messagesOf(llmRequest))
    if (m['content'] is List)
      for (final p in (m['content'] as List).cast<Map>())
        if (p['type'] == 'image') p,
];

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

Map<String, Object?> viewOp() =>
    operation(shell: true, viewImage: true, askHuman: false);

void main() {
  test('imageInfo reads PNG, JPEG and WebP headers and nothing else', () {
    expect(imageInfo(png(1600, 900)), (
      mimeType: 'image/png',
      width: 1600,
      height: 900,
    ));
    expect(imageInfo(jpeg(640, 480)), (
      mimeType: 'image/jpeg',
      width: 640,
      height: 480,
    ));
    expect(imageInfo(webp(300, 200)), (
      mimeType: 'image/webp',
      width: 300,
      height: 200,
    ));
    expect(imageInfo(utf8.encode('not an image at all, just text')), isNull);
    expect(imageInfo(png(10, 10).sublist(0, 16)), isNull);
    expect(imageInfo(const <int>[]), isNull);
  });

  test('the image goes to the next model call only, as a user message after '
      'the tool message; later calls carry the tool text alone', () async {
    final image = png(1600, 900, size: 4096);
    final (h, sup) = await startViewing(
      [
        ScriptedCall.toolCall('c1', 'view_image', {'path': 'out/board.png'}),
        ScriptedCall.toolCall('c2', 'shell_run', {'script': 'true'}),
        ScriptedCall.text('looks right'),
      ],
      files: {'/workspace/out/board.png': image},
    );
    final run = await h.startOperation(viewOp());
    final status = await h.waitEnded(run);
    expect(status['status'], 'succeeded', reason: jsonEncode(status));

    // Offered as a tool, after the shell tools.
    final tools =
        ((h.gateway.llmRequests.first['target'] as Map)['tools'] as List)
            .map((t) => (t as Map)['name'])
            .toList();
    expect(tools.last, 'view_image');

    // Uploaded as a file of the execution.
    final upload = h.gateway.requests.firstWhere(
      (r) => r.path == '/inner/agent/files/upload-request',
    );
    expect(upload.body, {
      'filename': 'board.png',
      'mime_type': 'image/png',
      'size': 4096,
    });
    final uploadId = h.gateway.uploads.keys.single;
    expect(h.gateway.uploads[uploadId], image);

    // Call 2: tool message, then the image in a user message.
    final second = messagesOf(h.gateway.llmRequests[1]);
    final tool = second[second.length - 2];
    expect(tool['role'], 'tool');
    expect(tool['tool_call_id'], 'c1');
    expect(
      tool['content'],
      'The image out/board.png (image/png, 1600x900, 4096 bytes) is attached '
      'after this result, for your next step only. It is not kept in the '
      'conversation; call view_image again to look at it later.',
    );
    expect(second.last, {
      'role': 'user',
      'content': [
        {'type': 'text', 'data': 'view_image out/board.png:'},
        {
          'type': 'image',
          'url': 'dify-sf-file:$uploadId',
          'base64_data': '',
          'format': 'png',
          'mime_type': 'image/png',
          'filename': '$uploadId.png',
          'detail': 'high',
        },
      ],
      'name': null,
    });
    // Call 3: the same history without the image.
    expect(imagePartsOf(h.gateway.llmRequests[2]), isEmpty);
    final third = messagesOf(h.gateway.llmRequests[2]);
    expect(
      third.where((m) => m['role'] == 'tool' && m['tool_call_id'] == 'c1'),
      hasLength(1),
    );
    expect(third.where((m) => m['role'] == 'user'), hasLength(1)); // the task

    // The snapshot keeps the reference, never the bytes.
    final snapshot = jsonEncode((status['result'] as Map)['snapshot']);
    expect(snapshot, contains('dify-sf-file:$uploadId'));
    expect(snapshot, isNot(contains(base64.encode(image))));
    final events = await h.events(run);
    final finished = events.firstWhere(
      (e) =>
          e.event == 'tool_call' &&
          e.data['name'] == 'view_image' &&
          e.data['phase'] == 'finished',
    );
    expect(finished.data['output'], contains('out/board.png'));
    expect(sup.sandboxOf('E1'), isNotNull);
  });

  test('detail low, JPEG and WebP, and two images of one step', () async {
    final (h, _) = await startViewing(
      [
        toolCalls([
          ('c1', 'view_image', {'path': '/workspace/a.jpg', 'detail': 'low'}),
          ('c2', 'view_image', {'path': 'b.webp'}),
        ]),
        ScriptedCall.text('done'),
      ],
      files: {
        '/workspace/a.jpg': jpeg(640, 480),
        '/workspace/b.webp': webp(30, 20),
      },
    );
    final run = await h.startOperation(viewOp());
    expect((await h.waitEnded(run))['status'], 'succeeded');
    final parts = imagePartsOf(h.gateway.llmRequests[1]);
    expect(
      [for (final p in parts) (p['mime_type'], p['detail'])],
      [('image/jpeg', 'low'), ('image/webp', 'high')],
    );
    final user = messagesOf(h.gateway.llmRequests[1]).last;
    expect(
      [
        for (final p in (user['content'] as List).cast<Map>())
          if (p['type'] == 'text') p['data'],
      ],
      ['view_image a.jpg:', '\nview_image b.webp:'],
    );
  });

  test(
    'problems are tool errors the model can act on; the run goes on',
    () async {
      final big = png(4000, 4000, size: viewImageTurnBytes + 1);
      final half = png(100, 100, size: viewImageTurnBytes ~/ 2 + 10);
      final (h, _) = await startViewing(
        [
          toolCalls([
            ('c1', 'view_image', {'path': 'missing.png'}),
            ('c2', 'view_image', {'path': 'notes.png'}),
            ('c3', 'view_image', {'path': 'big.png'}),
            ('c4', 'view_image', {'path': 'link.png'}),
            ('c5', 'view_image', {'path': '../etc/passwd'}),
            ('c6', 'view_image', {}),
          ]),
          toolCalls([
            ('d1', 'view_image', {'path': 'half1.png'}),
            ('d2', 'view_image', {'path': 'half2.png'}),
          ]),
          ScriptedCall.text('gave up'),
        ],
        files: {
          '/workspace/notes.png': utf8.encode('just some notes'),
          '/workspace/big.png': big,
          '/workspace/half1.png': half,
          '/workspace/half2.png': half,
          '/etc/shadow': [1, 2, 3],
        },
        symlinks: {'/workspace/link.png': '/etc/shadow'},
      );
      final run = await h.startOperation(viewOp());
      final status = await h.waitEnded(run);
      expect(status['status'], 'succeeded', reason: jsonEncode(status));
      final tools = {
        for (final m in messagesOf(h.gateway.llmRequests[1]))
          if (m['role'] == 'tool') m['tool_call_id']: m['content'] as String,
      };
      expect(tools['c1'], contains('does not exist'));
      expect(tools['c2'], contains('is not a PNG, JPEG or WebP image'));
      expect(tools['c3'], contains('at most $viewImageTurnBytes bytes'));
      expect(tools['c4'], contains('outside the workspace'));
      expect(tools['c5'], isNotEmpty);
      expect(tools['c5'], contains('error'));
      expect(tools['c6'], contains('path is required'));
      expect(imagePartsOf(h.gateway.llmRequests[1]), isEmpty);
      // Only the image of the second step that fits was uploaded.
      expect(h.gateway.uploads, hasLength(1));
      // The second step: one image fits, the other exceeds the step's budget.
      final second = {
        for (final m in messagesOf(h.gateway.llmRequests[2]))
          if (m['role'] == 'tool') m['tool_call_id']: m['content'] as String,
      };
      final errors = [
        for (final id in ['d1', 'd2'])
          if (second[id]!.contains('already viewed in this step')) id,
      ];
      expect(errors, hasLength(1));
      expect(imagePartsOf(h.gateway.llmRequests[2]), hasLength(1));
    },
  );

  test('a failed upload is a tool error, not a run failure', () async {
    final (h, _) = await startViewing(
      [
        ScriptedCall.toolCall('c1', 'view_image', {'path': 'a.png'}),
        ScriptedCall.text('ok'),
      ],
      files: {'/workspace/a.png': png(2, 2)},
    );
    h.gateway.uploadStatus = 500;
    final run = await h.startOperation(viewOp());
    expect((await h.waitEnded(run))['status'], 'succeeded');
    final tool = messagesOf(h.gateway.llmRequests[1])
        .lastWhere((m) => m['role'] == 'tool');
    expect(tool['content'], contains('could not be attached'));
    expect(imagePartsOf(h.gateway.llmRequests[1]), isEmpty);
  });

  test('tools.view_image needs the shell; without the flag there is no tool '
      'and the tool definitions digest differs', () async {
    final h = await Harness.start();
    addTearDown(h.close);
    final (s, j) = await h.post(
      '/v1/operations',
      operation(viewImage: true, shell: false),
    );
    expect((s, j['error']), (400, 'invalid_request'));
    final withTool = OperationRequest.parse(viewOp());
    final without = OperationRequest.parse(
      operation(shell: true, askHuman: false),
    );
    expect(
      toolDefinitions(withTool).map((t) => t['name']),
      contains('view_image'),
    );
    expect(
      toolDefinitions(without).map((t) => t['name']),
      isNot(contains('view_image')),
    );
    expect(
      toolDefinitionsDigest(withTool),
      isNot(toolDefinitionsDigest(without)),
    );
  });

  test('a resumed history never re-sends a viewed image', () async {
    final inner = InnerClient(
      baseUrl: Uri.parse('http://unused.invalid'),
      serviceKey: 'k',
      runToken: 't',
    );
    addTearDown(inner.close);
    final toolMessage = Message(
      role: Role.tool,
      content: [
        ToolResponsePart(
          toolResponse: ToolResponse(
            ref: 'c1',
            name: 'view_image',
            output: 'attached',
            content: [
              MediaPart(
                media: Media(url: 'dify-sf-file:up1', contentType: 'image/png'),
                metadata: {
                  viewImageMetadataKey: {'path': 'a.png', 'detail': 'high'},
                },
              ).toJson(),
            ],
          ),
        ),
      ],
    );
    final call = Message(
      role: Role.model,
      content: [
        ToolRequestPart(
          toolRequest: ToolRequest(ref: 'c1', name: 'view_image', input: {}),
        ),
      ],
    );
    final task = Message(
      role: Role.user,
      content: [TextPart(text: 'go')],
    );
    final last = await toPromptMessages([task, call, toolMessage], inner);
    expect(last.last['role'], 'user');
    expect((last.last['content'] as List).length, 2);
    final later = await toPromptMessages([
      task,
      call,
      toolMessage,
      Message(
        role: Role.model,
        content: [TextPart(text: 'seen')],
      ),
      Message(
        role: Role.user,
        content: [TextPart(text: 'Your previous output failed')],
      ),
    ], inner);
    expect(jsonEncode(later), isNot(contains('dify-sf-file:up1')));
  });
}
