import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_node.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

/// The run UI in the editor with the mock runtime (dify-sf has no workflow runtime): a test run from the header, the
/// chatflow preview, a single node run and the run history. Run state stays local: no document ops.

class _Backend extends DemoBackend {
  _Backend(this._meta, {super.server}) : super(withBo: false);
  final DocMeta _meta;
  @override
  Future<DocMeta> docMeta(String docId) async => _meta;
}

/// start (query: text input, required) → llm → code → end (workflow) or answer (chatflow).
FakeServer _server({required bool chat}) {
  Value ref(String n, String o) => VRef(OutputRef(n, o));
  final nodes = [
    Node(
      id: 'start',
      type: 'start',
      title: 'Start',
      x: 80,
      y: 120,
      config: {
        'variables': VItems([
          Item(
            'v-query',
            Value.of({'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true, 'max_length': 48}),
          ),
        ]),
      },
    ),
    Node(
      id: 'llm',
      type: 'llm',
      title: 'Answer the question',
      x: 380,
      y: 120,
      config: {
        'model': const VMap({'provider': VString('openai'), 'name': VString('gpt-4o')}),
        'context': ref('start', 'query'),
      },
    ),
    Node(
      id: 'code',
      type: 'code',
      title: 'Post-process',
      x: 680,
      y: 120,
      config: {
        'language': const VString('python3'),
        'code': const VString("def main(text):\n    return {'result': text.strip()}"),
        'inputs': ref('llm', 'text'),
      },
    ),
    chat
        ? Node(id: 'answer', type: 'answer', title: 'Answer', x: 980, y: 120, config: {'answer': ref('code', 'result')})
        : Node(
            id: 'end',
            type: 'end',
            title: 'End',
            x: 980,
            y: 120,
            config: {
              'outputs': VItems([
                Item('o1', VMap({'variable': const VString('result'), 'value_selector': ref('code', 'result')})),
              ]),
            },
          ),
  ];
  return FakeServer(
    initial: Document(
      nodes: nodes,
      edges: [
        const Edge(id: 'e1', source: 'start', target: 'llm'),
        const Edge(id: 'e2', source: 'llm', target: 'code'),
        Edge(id: 'e3', source: 'code', target: chat ? 'answer' : 'end'),
      ],
    ),
  );
}

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  for (var i = 0; i < d.inMilliseconds ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<_Backend> _open(WidgetTester t, {bool chat = false}) async {
  await useAppFonts();
  t.view.physicalSize = const Size(3200, 2000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final backend = _Backend(
    DocMeta(appMode: chat ? 'advanced-chat' : 'workflow', appName: 'App'),
    server: _server(chat: chat),
  );
  await t.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Noto Sans'),
        home: EditorPage(backend: backend, docId: 'demo', clientId: 'me-abc123', journaled: false),
      ),
    ),
  );
  await _settle(t);
  return backend;
}

Future<void> _close(WidgetTester t, DemoBackend backend) async {
  await t.pumpWidget(const SizedBox());
  await backend.dispose();
  await t.pump(const Duration(seconds: 20));
}

WorkflowRunScope _scope(WidgetTester t) => WorkflowRunScope.of(t.element(find.byKey(const ValueKey('node-start'))));

final _boundary = GlobalKey();

Future<void> _monoFont() async {
  final loader = FontLoader('DejaVu Sans Mono')..addFont(rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
  await loader.load();
}

Future<void> _shot(WidgetTester t, String name) async {
  final dir = Platform.environment['RUN_UI_SHOTS']!;
  await t.runAsync(() async {
    final ro = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  if (Platform.environment['RUN_UI_SHOTS'] == null) return;

  testWidgets('run UI screenshots (workflow)', (t) async {
    await t.runAsync(() async => DifyI18n.current = await DifyI18n.load('en-US'));
    await _monoFont();
    final backend = await _open(t);
    final scope = _scope(t);
    (scope.service as MockWorkflowRunService).scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 200));
    await t.tap(find.text('Test Run'));
    await _settle(t, const Duration(milliseconds: 800));
    await _shot(t, '01-inputs');
    await t.enterText(find.byType(EditableText).last, 'What is dify-sf?');
    await t.pump();
    await t.tap(find.text('Start Run'));
    await _settle(t, const Duration(milliseconds: 500));
    await _shot(t, '02-result-running');
    await _settle(t, const Duration(seconds: 4));
    await _shot(t, '03-result');
    await t.tap(find.text('DETAIL').first);
    await _settle(t, const Duration(milliseconds: 300));
    await _shot(t, '04-detail');
    await t.tap(find.text('TRACING').first);
    await _settle(t, const Duration(milliseconds: 300));
    await t.tap(find.descendant(of: find.byType(RunNodePanel), matching: find.text('ANSWER THE QUESTION')));
    await _settle(t, const Duration(milliseconds: 500));
    await _shot(t, '05-tracing');
    scope.run.handleCancelDebugAndPreviewPanel();
    await t.pump();
    final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    c.selectNode('llm');
    await _settle(t, const Duration(milliseconds: 500));
    await t.tap(
      find.descendant(of: find.byType(WorkflowNodePanel), matching: find.bySemanticsLabel('Run this step')).first,
    );
    await _settle(t, const Duration(milliseconds: 500));
    await _shot(t, '06-single-run-form');
    await t.enterText(find.descendant(of: find.byType(BeforeRunForm), matching: find.byType(EditableText)).first, 'hi');
    await t.pump();
    await t.tap(find.text('Start Run'));
    await _settle(t, const Duration(seconds: 2));
    await _shot(t, '07-last-run');
    c.selectNode(null);
    await _settle(t, const Duration(milliseconds: 300));
    await t.tap(find.bySemanticsLabel('View run history'));
    await _settle(t, const Duration(milliseconds: 500));
    await _shot(t, '08-history-popup');
    await t.tap(find.textContaining('Test Run (').first);
    await _settle(t, const Duration(seconds: 1));
    await _shot(t, '09-record');
    await _close(t, backend);
  });

  testWidgets('run UI screenshots (chatflow)', (t) async {
    await t.runAsync(() async => DifyI18n.current = await DifyI18n.load('en-US'));
    await _monoFont();
    final backend = await _open(t, chat: true);
    final scope = _scope(t);
    (scope.service as MockWorkflowRunService).scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 200));
    await t.tap(find.text('Preview'));
    await _settle(t, const Duration(milliseconds: 800));
    await _shot(t, '10-chat-empty');
    final input = find.descendant(of: find.byType(ChatInputArea), matching: find.byType(EditableText));
    await t.enterText(input, 'Hello there');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(t, const Duration(milliseconds: 700));
    await _shot(t, '11-chat-responding');
    await _settle(t, const Duration(seconds: 5));
    await _shot(t, '12-chat-answer');
    await t.tap(find.descendant(of: find.byType(WorkflowProcessItem), matching: find.byType(Row)).first);
    await _settle(t, const Duration(milliseconds: 300));
    await _shot(t, '13-chat-process');
    await _close(t, backend);
  });
}
