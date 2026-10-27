import 'dart:ui' show Tristate, SemanticsAction;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/debug_and_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_node.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/workflow_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

/// The run UI in the editor with an explicit mock runtime: a test run from the header, the
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
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final backend = _Backend(
    DocMeta(appMode: chat ? 'advanced-chat' : 'workflow', appName: 'App'),
    server: _server(chat: chat),
  );
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Noto Sans'),
      home: EditorPage(backend: backend, docId: 'demo', clientId: 'me-abc123', journaled: false),
    ),
  );
  await _settle(t);
  // These UI fixtures intentionally use a synthetic model without a configured
  // workspace. Preflight behavior is covered by chat_request_validation_test;
  // give the mock runtime a successful preflight to exercise its result UI.
  _store(t).computeRunChecklist = () => const [];
  return backend;
}

Future<void> _close(WidgetTester t, DemoBackend backend) async {
  await t.pumpWidget(const SizedBox());
  await backend.dispose();
  await t.pump(const Duration(seconds: 20));
}

WorkflowStore _store(WidgetTester t) => WorkflowStoreScope.of(t.element(find.byKey(const ValueKey('node-start'))));
WorkflowRunScope _scope(WidgetTester t) => WorkflowRunScope.of(t.element(find.byKey(const ValueKey('node-start'))));

void main() {
  testWidgets('test run from the header: the inputs, Start Run, the result, detail and tracing tabs', (t) async {
    final backend = await _open(t);
    final store = _store(t);
    final opsBefore = backend.server.head;
    final mock = _scope(t).service as MockWorkflowRunService;
    mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 200));

    // The header's Test Run (one start option: it runs at once) opens the panel on its INPUT tab.
    await t.tap(find.text('common.run'));
    await _settle(t, const Duration(milliseconds: 500));
    expect(store.showDebugAndPreviewPanel.value, isTrue);
    expect(store.showInputsPanel.value, isTrue);
    expect(find.byType(WorkflowPreview), findsOneWidget);
    expect(find.byType(InputsPanel), findsOneWidget);
    expect(find.text('Query'), findsWidgets); // the label and the placeholder

    // A required input left empty: nothing runs.
    await t.tap(find.text('singleRun.startRun'));
    await t.pump();
    expect(mock.requests, isEmpty);

    await t.enterText(find.byType(EditableText).last, 'What is dify-sf?');
    await t.pump();
    expect(store.inputs.value['query'], 'What is dify-sf?');
    await t.tap(find.text('singleRun.startRun'));
    await t.pump();
    expect(mock.requests, hasLength(1));
    expect(runningStatusOf(store.workflowRunningData.value), WorkflowRunningStatus.running);
    // The panel moved to RESULT; the run goes on.
    expect(find.byType(InputsPanel), findsNothing);
    await _settle(t, const Duration(seconds: 4));
    expect(runningStatusOf(store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
    expect(find.textContaining('Test Run ('), findsOneWidget);

    // DETAIL: the status box and the metadata; TRACING: a row per node in order.
    await t.tap(find.text('detail'));
    await t.pump();
    expect(find.text('SUCCESS'), findsWidgets);
    expect(find.text('META.TITLE'), findsOneWidget);
    await t.tap(find.text('tracing'));
    await t.pump();
    final rows = t.widgetList<RunNodePanel>(find.byType(RunNodePanel)).map((r) => r.nodeInfo['node_id']).toList();
    expect(rows, ['start', 'llm', 'code', 'end']);
    // A row opens to its input and output.
    await t.tap(find.descendant(of: find.byType(RunNodePanel), matching: find.text('ANSWER THE QUESTION')));
    await t.pump();
    expect(find.text('COMMON.INPUT'), findsOneWidget);
    expect(find.text('COMMON.OUTPUT'), findsOneWidget);

    // Closing the panel clears the run; nothing was written to the document.
    await t.tap(find.bySemanticsLabel('operation.close').first);
    await t.pump();
    expect(store.showDebugAndPreviewPanel.value, isFalse);
    expect(store.workflowRunningData.value, isNull);
    expect(backend.server.head, opsBefore);
    await _close(t, backend);
  });

  testWidgets('chatflow preview: send a message, the answer streams in with its workflow process', (t) async {
    final backend = await _open(t, chat: true);
    final store = _store(t);
    final opsBefore = backend.server.head;
    final mock = _scope(t).service as MockWorkflowRunService;
    mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 200));

    await t.tap(find.text('common.debugAndPreview'));
    await _settle(t, const Duration(milliseconds: 500));
    expect(store.showDebugAndPreviewPanel.value, isTrue);
    expect(find.byType(DebugAndPreview), findsOneWidget);
    // The Start variables' card is open; the empty state shows until a message is sent.
    expect(find.byType(UserInput), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byType(UserInput), matching: find.byType(EditableText)),
      'context',
    );
    expect(store.inputs.value['query'], 'context');

    final input = find.descendant(of: find.byType(ChatInputArea), matching: find.byType(EditableText));
    final semantics = t.ensureSemantics();
    final fields = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      if (!node.isMergedIntoParent && node.getSemanticsData().flagsCollection.isTextField) fields.add(node);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(t.getSemantics(input));
    expect(fields, hasLength(1), reason: 'Web must expose one editable field, without a disabled nested textarea');
    expect(fields.single.getSemanticsData().flagsCollection.isEnabled, Tristate.isTrue);
    expect(fields.single.getSemanticsData().flagsCollection.isMultiline, isTrue);
    await t.tap(input);
    await t.pump();
    expect(t.widget<EditableText>(input).focusNode.hasFocus, isTrue);
    // Web can dismiss its editing session while the Flutter focus node stays focused.
    // Accessibility focus must request the keyboard again rather than only re-requesting node focus.
    t.testTextInput.hide();
    expect(t.testTextInput.isVisible, isFalse);
    final editableSemantics = t.getSemantics(input);
    editableSemantics.owner!.performAction(editableSemantics.id, SemanticsAction.focus);
    await t.pump();
    expect(t.testTextInput.isVisible, isTrue);
    semantics.dispose();
    await t.enterText(input, 'Hello there');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(mock.requests, hasLength(1));
    // The question shows at once, the answer follows; while it responds the input card folds and Stop shows.
    expect(
      find.descendant(of: find.byType(ChatQuestion), matching: find.textContaining('Hello there')),
      findsOneWidget,
    );
    await _settle(t, const Duration(milliseconds: 600));
    expect(find.byType(ChatAnswer), findsOneWidget);
    expect(find.text('operation.stopResponding'), findsOneWidget);
    expect(find.byType(UserInput), findsNothing);
    await _settle(t, const Duration(seconds: 5));
    expect(find.text('operation.stopResponding'), findsNothing);
    expect(find.byType(WorkflowProcessItem), findsOneWidget);
    final answer = t.widget<ChatAnswer>(find.byType(ChatAnswer));
    expect('${answer.item['content']}', isNotEmpty);
    expect((answer.item['workflowProcess'] as Map)['status'], WorkflowRunningStatus.succeeded);
    // The process opens to the tracing.
    await t.tap(find.descendant(of: find.byType(WorkflowProcessItem), matching: find.byType(Row)).first);
    await t.pump();
    expect(find.descendant(of: find.byType(WorkflowProcessItem), matching: find.byType(RunNodePanel)), findsWidgets);

    // Restart clears the conversation.
    await t.tap(find.bySemanticsLabel('operation.refresh'));
    await t.pump();
    expect(find.byType(ChatAnswer), findsNothing);
    expect(backend.server.head, opsBefore);
    await _close(t, backend);
  });

  testWidgets('single node run from the panel: the before-run form, then the Last Run tab shows the result', (t) async {
    final backend = await _open(t);
    final store = _store(t);
    final opsBefore = backend.server.head;
    final mock = _scope(t).service as MockWorkflowRunService;
    mock.scenario = const MockRunScenario(stepDelay: Duration(milliseconds: 100));

    final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    c.selectNode('llm');
    await _settle(t, const Duration(milliseconds: 500));
    // No run yet: the Last Run tab's empty state.
    await t.tap(find.text('DEBUG.LASTRUNTAB'));
    await _settle(t, const Duration(milliseconds: 300));
    expect(find.text('debug.noData.description'), findsOneWidget);

    // Run this step: the LLM reads start.query, which has no value yet, so the form asks for it.
    await t.tap(
      find.descendant(of: find.byType(WorkflowNodePanel), matching: find.bySemanticsLabel('panel.runThisStep')).first,
    );
    await _settle(t, const Duration(milliseconds: 300));
    expect(find.text('singleRun.testRun Answer the question'), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byType(BeforeRunFormFinder.type), matching: find.byType(EditableText)).first,
      'hello',
    );
    await t.pump();
    await t.tap(find.text('singleRun.startRun'));
    await t.pump();
    expect(find.text('singleRun.testRun Answer the question'), findsNothing);
    await _settle(t, const Duration(seconds: 2));
    // The Last Run tab shows the run: the status box, the input and output, no steps row.
    expect(find.text('SUCCESS'), findsWidgets);
    expect(find.text('COMMON.INPUT'), findsOneWidget);
    expect(find.text('META.STEPS'), findsNothing);
    expect(store.nodeRunDataOf('llm')['_singleRunningStatus'], NodeRunningStatus.succeeded);
    expect(backend.server.head, opsBefore);
    await _close(t, backend);
  });

  testWidgets('run history: a past run opens read-only with its result, detail and tracing', (t) async {
    final backend = await _open(t);
    final store = _store(t);
    final scope = _scope(t);
    final mock = scope.service as MockWorkflowRunService;
    mock.scenario = const MockRunScenario(stepDelay: Duration.zero);
    await scope.run.handleRun({
      'inputs': {'query': 'q'},
    });
    await _settle(t, const Duration(seconds: 1));
    scope.run.handleCancelDebugAndPreviewPanel();
    await t.pump();

    // The header's run history: one run; picking it shows the Record panel.
    await t.tap(find.bySemanticsLabel('common.viewRunHistory'));
    await _settle(t, const Duration(milliseconds: 500));
    await t.tap(find.textContaining('Test Run (').first);
    await _settle(t, const Duration(milliseconds: 500));
    expect(store.historyWorkflowData.value, isNotNull);
    expect(find.byType(RunRecord), findsOneWidget);
    expect(find.byType(RunPanel), findsOneWidget);
    // RESULT: the output; DETAIL: the status; TRACING: the nodes.
    await t.tap(find.text('DETAIL'));
    await _settle(t, const Duration(milliseconds: 300));
    expect(find.text('SUCCESS'), findsWidgets);
    await t.tap(find.text('TRACING'));
    await _settle(t, const Duration(milliseconds: 300));
    expect(t.widgetList<RunNodePanel>(find.byType(RunNodePanel)).map((r) => r.nodeInfo['node_id']), [
      'start',
      'llm',
      'code',
      'end',
    ]);
    await _close(t, backend);
  });
}

/// The before-run form's type, for finders.
abstract final class BeforeRunFormFinder {
  static const type = BeforeRunForm;
}
