// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/components.spec.tsx
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/conversation-variable-modal.spec.tsx
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/user-input.spec.tsx
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/chat-wrapper.spec.tsx
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/debug-and-preview.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/resize_handle.dart';
import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/debug_and_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/workflow_preview.dart' show RunPanelContext;
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run/run_harness.dart';

/// `useChat` as Dify's specs mock it: records the calls, returns the given state.
class FakeChat extends DebugChatController {
  FakeChat(WorkflowStore store, {this.list = const [], this.responding = false})
    : super(
        run: WorkflowRunController(
          store: store,
          service: MockWorkflowRunService(graph: () => const StaticRunGraph()),
          graph: const StaticRunGraph(),
        ),
        service: MockWorkflowRunService(graph: () => const StaticRunGraph()),
        store: store,
      );

  List<DifyJson> list;
  bool responding;
  final sends = <(DifyJson, SuggestedQuestionsFetcher?)>[];
  final switches = <(String, SuggestedQuestionsFetcher?)>[];
  int restarts = 0, stops = 0;

  @override
  List<DifyJson> get chatList => list;
  @override
  bool get isResponding => responding;
  @override
  String get conversationId => 'conversation-1';

  @override
  bool handleSend(DifyJson params, {SuggestedQuestionsFetcher? onGetSuggestedQuestions}) {
    sends.add((params, onGetSuggestedQuestions));
    return true;
  }

  @override
  void handleSwitchSibling(String siblingMessageId, {SuggestedQuestionsFetcher? onGetSuggestedQuestions}) =>
      switches.add((siblingMessageId, onGetSuggestedQuestions));

  @override
  void handleRestart() => restarts++;

  @override
  void handleStop() => stops++;

  void respond() {
    responding = true;
    notifyListeners();
  }
}

DifyJson conversationVariable([DifyJson o = const {}]) => {
  'id': 'var-1',
  'name': 'session_state',
  'description': 'Session state',
  'value_type': 'object',
  'value': '{"draft":true}',
  ...o,
};

DifyJson textVar(String variable, String label, {Object? defaultValue, bool hide = false, bool required = false}) => {
  'type': 'text-input',
  'variable': variable,
  'label': label,
  'required': required,
  'default': ?defaultValue,
  if (hide) 'hide': true,
};

/// The text field of the form item labelled [label].
Finder inputOf(String label) => find.descendant(
  of: find.ancestor(of: find.text(label).first, matching: find.byType(Column)).first,
  matching: find.byType(EditableText),
);

void main() {
  group('debug-and-preview components', () {
    group('ConversationVariableModal', () {
      testWidgets('should load latest values, switch variable tabs, and close the modal', (t) async {
        final fetched = <String>[];
        var hidden = 0;
        await renderRun(
          t,
          ConversationVariableModal(
            conversationId: 'conversation-1',
            onHide: () => hidden++,
            formatTime: (v, f) => 'formatted-$v',
            varList: [
              conversationVariable(),
              conversationVariable({'id': 'var-2', 'name': 'summary', 'value_type': 'string', 'value': 'plain text'}),
            ],
            fetchValues: (id) async {
              fetched.add(id);
              return [
                {
                  ...conversationVariable({'value': '{"latest":1}'}),
                  'updated_at': 100,
                  'created_at': 50,
                },
                {
                  ...conversationVariable({
                    'id': 'var-2',
                    'name': 'summary',
                    'value_type': 'string',
                    'value': 'latest text',
                  }),
                  'updated_at': 200,
                  'created_at': 150,
                },
              ];
            },
          ),
          size: const Size(1000, 700),
        );
        await t.pump();
        expect(fetched, ['conversation-1']);
        expect(find.text('session_state'), findsNWidgets(2));
        expect(find.textContaining('formatted-100'), findsOneWidget);
        expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).value, '{"latest":1}');
        await t.tap(find.text('summary'));
        await t.pump();
        expect(find.text('latest text'), findsOneWidget);
        await t.tap(find.bySemanticsLabel('common.operation.close'));
        expect(hidden, 1);
      });

      testWidgets('should copy the current variable value and reset the copied state after the timeout', (t) async {
        final copied = <String>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
          return null;
        });
        addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        await renderRun(
          t,
          ConversationVariableModal(
            conversationId: 'conversation-1',
            onHide: () {},
            varList: [conversationVariable()],
            fetchValues: (_) async => const [],
          ),
          size: const Size(1000, 700),
        );
        await t.tap(find.bySemanticsLabel('common.operation.copy'));
        expect(copied, ['{"draft":true}']);
        await t.pump(const Duration(seconds: 2));
      });
    });

    group('UserInput', () {
      testWidgets('should hide secret fields outside the expanded panel and persist edits into workflow state', (
        t,
      ) async {
        final store = await renderRun(
          t,
          UserInput(
            variables: [textVar('question', 'Question'), textVar('internal_note', 'Internal Note', hide: true)],
          ),
          initialStoreState: (s) => s
            ..setInputs({'question': 'draft'})
            ..setShowDebugAndPreviewPanel(false),
        );
        expect(find.text('Question'), findsWidgets);
        expect(find.text('Internal Note'), findsNothing);
        await t.enterText(inputOf('Question'), 'updated draft');
        expect(store.inputs.value, {'question': 'updated draft'});
      });

      testWidgets('should reveal hidden fields when the debug-and-preview panel is expanded', (t) async {
        await renderRun(
          t,
          UserInput(variables: [textVar('internal_note', 'Internal Note', hide: true)]),
          initialStoreState: (s) => s.setShowDebugAndPreviewPanel(true),
        );
        expect(find.text('Internal Note'), findsWidgets);
      });
    });

    group('ChatWrapper', () {
      testWidgets('should seed start defaults into workflow inputs and expose restart through the ref handle', (
        t,
      ) async {
        FakeChat? chat;
        final restart = ValueNotifier<VoidCallback?>(null);
        final store = await renderRun(
          t,
          Builder(
            builder: (context) => ChatWrapper(
              controller: chat ??= FakeChat(WorkflowStoreScope.of(context)),
              startVariables: [textVar('name', 'Name', defaultValue: 'Ada')],
              showInputsFieldsPanel: true,
              onHide: () {},
              restart: restart,
            ),
          ),
          initialStoreState: (s) => s.setInputs({'custom': 'value'}),
        );
        await t.pump();
        expect(store.inputs.value, {'name': 'Ada', 'custom': 'value'});
        expect(find.text('workflow.common.previewPlaceholder'), findsOneWidget);
        restart.value!();
        expect(chat!.restarts, 1);
        expect(store.inputs.value, {'name': 'Ada'});
      });

      testWidgets('should hide the side panel while responding and render the conversation modal when requested', (
        t,
      ) async {
        FakeChat? chat;
        var hides = 0;
        await renderRun(
          t,
          Builder(
            builder: (context) => ChatWrapper(
              controller: chat ??= FakeChat(WorkflowStoreScope.of(context)),
              startVariables: const [],
              showInputsFieldsPanel: false,
              showConversationVariableModal: true,
              onHide: () => hides++,
            ),
          ),
          initialStoreState: (s) => s.setConversationVariables([conversationVariable()]),
          size: const Size(1200, 900),
        );
        await t.pump();
        chat!.respond();
        await t.pump();
        expect(hides, 1);
        expect(find.text('session_state'), findsNWidgets(2));
      });

      testWidgets('should forward chat actions, stop subscriptions, and expose paused input state', (t) async {
        FakeChat? chat;
        final store = await renderRun(
          t,
          Builder(
            builder: (context) => ChatWrapper(
              controller: chat ??= FakeChat(
                WorkflowStoreScope.of(context),
                list: [
                  {'id': 'answer-1', 'isAnswer': true, 'content': 'first answer'},
                  {
                    'id': 'question-1',
                    'isAnswer': false,
                    'content': 'first question',
                    'parentMessageId': 'answer-1',
                    'message_files': <Object?>[],
                  },
                  {
                    'id': 'answer-2',
                    'isAnswer': true,
                    'parentMessageId': 'question-1',
                    'content': 'latest answer',
                    'workflowProcess': {'status': 'paused'},
                  },
                ],
              ),
              startVariables: [textVar('name', 'Name', defaultValue: 'Ada')],
              showInputsFieldsPanel: false,
              onHide: () {},
            ),
          ),
          initialStoreState: (s) => s.setInputs({'existing': 'value'}),
          size: const Size(800, 900),
        );
        await t.pump();
        expect(store.inputs.value, {'name': 'Ada', 'existing': 'value'});
        final view = t.widget<DebugChat>(find.byType(DebugChat));
        expect(view.inputDisabled, isTrue);
        view.onSend!('hello');
        final (params, fetcher) = chat!.sends.single;
        expect(params, containsPair('query', 'hello'));
        expect(params, containsPair('conversation_id', 'conversation-1'));
        expect(params['inputs'], {'name': 'Ada', 'existing': 'value'});
        expect(params, containsPair('parent_message_id', 'answer-2'));
        expect(fetcher, isNotNull);
        view.onRegenerate!(chat!.list[2]);
        expect(chat!.sends[1].$1, containsPair('query', 'first question'));
        expect(chat!.sends[1].$1, containsPair('parent_message_id', 'answer-1'));
        view.switchSibling!('sibling-2');
        expect(chat!.switches.single.$1, 'sibling-2');
        expect(chat!.switches.single.$2, isNotNull);
        // EVENT_WORKFLOW_STOP stops the run; the responding answer stops with it.
        chat!.respond();
        store.setWorkflowRunningData({
          'result': {'status': 'stopped'},
        });
        expect(chat!.stops, 1);
      });
    });
  });

  group('ChatWrapper', () {
    testWidgets('seeds start defaults into workflow inputs and exposes restart through the ref handle', (t) async {
      FakeChat? chat;
      final restart = ValueNotifier<VoidCallback?>(null);
      final store = await renderRun(
        t,
        Builder(
          builder: (context) => ChatWrapper(
            controller: chat ??= FakeChat(WorkflowStoreScope.of(context)),
            startVariables: [textVar('name', 'Name', defaultValue: 'Ada')],
            showInputsFieldsPanel: true,
            onHide: () {},
            restart: restart,
          ),
        ),
      );
      await t.pump();
      expect(store.inputs.value, {'name': 'Ada'});
      restart.value!();
      expect(chat!.restarts, 1);
    });

    testWidgets('forwards chat actions and stops the active run when workflow-stop is emitted', (t) async {
      FakeChat? chat;
      final store = await renderRun(
        t,
        Builder(
          builder: (context) => ChatWrapper(
            controller: chat ??= FakeChat(WorkflowStoreScope.of(context)),
            startVariables: const [],
            showInputsFieldsPanel: false,
            onHide: () {},
          ),
        ),
      );
      await t.pump();
      t.widget<DebugChat>(find.byType(DebugChat)).onSend!('hi');
      expect(chat!.sends.single.$1, containsPair('query', 'hi'));
      chat!.respond();
      store.setWorkflowRunningData({
        'result': {'status': 'stopped'},
      });
      expect(chat!.stops, 1);
    });

    testWidgets('collapses the side panel while the chat is responding', (t) async {
      FakeChat? chat;
      var hides = 0;
      await renderRun(
        t,
        Builder(
          builder: (context) => ChatWrapper(
            controller: chat ??= FakeChat(WorkflowStoreScope.of(context)),
            startVariables: const [],
            showInputsFieldsPanel: true,
            onHide: () => hides++,
          ),
        ),
      );
      await t.pump();
      chat!.respond();
      await t.pump();
      expect(hides, 1);
    });
  });

  group('ConversationVariableModal', () {
    testWidgets('loads latest values, switches the active variable, and closes the modal', (t) async {
      final fetched = <String>[];
      var hidden = 0;
      await renderRun(
        t,
        ConversationVariableModal(
          conversationId: 'conversation-1',
          onHide: () => hidden++,
          formatTime: (v, f) => 'formatted-$v',
          varList: [
            conversationVariable(),
            conversationVariable({'id': 'var-2', 'name': 'summary', 'value_type': 'string', 'value': 'plain text'}),
          ],
          fetchValues: (id) async {
            fetched.add(id);
            return [
              {
                ...conversationVariable({'value': '{"latest":1}'}),
                'updated_at': 100,
                'created_at': 50,
              },
              {
                ...conversationVariable({
                  'id': 'var-2',
                  'name': 'summary',
                  'value_type': 'string',
                  'value': 'latest text',
                }),
                'updated_at': 200,
                'created_at': 150,
              },
            ];
          },
        ),
        size: const Size(1000, 700),
      );
      await t.pump();
      expect(fetched, ['conversation-1']);
      expect(find.text('session_state'), findsNWidgets(2));
      expect(find.textContaining('formatted-100'), findsOneWidget);
      expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).value, '{"latest":1}');
      await t.tap(find.text('summary'));
      await t.pump();
      expect(find.text('latest text'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('common.operation.close'));
      expect(hidden, 1);
    });

    testWidgets('copies the current variable value and resets the copied state after the timeout', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await renderRun(
        t,
        ConversationVariableModal(
          conversationId: 'conversation-1',
          onHide: () {},
          varList: [conversationVariable()],
          fetchValues: (_) async => const [],
        ),
        size: const Size(1000, 700),
      );
      await t.tap(find.bySemanticsLabel('common.operation.copy'));
      expect(copied, ['{"draft":true}']);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('debug-and-preview UserInput', () {
    testWidgets('returns null when no visible variables remain', (t) async {
      await renderRun(
        t,
        UserInput(variables: [textVar('hidden_field', 'Hidden field', hide: true)]),
        initialStoreState: (s) => s.setShowDebugAndPreviewPanel(false),
      );
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('renders start variables and writes updates back to the workflow store', (t) async {
      final store = await renderRun(
        t,
        UserInput(
          variables: [
            textVar('query', 'Query', required: true),
            textVar('hidden_field', 'Hidden field', hide: true),
          ],
        ),
        initialStoreState: (s) => s.setShowDebugAndPreviewPanel(true),
      );
      await t.enterText(inputOf('Query'), 'hello');
      expect(find.text('Hidden field'), findsWidgets);
      expect(store.inputs.value, {'query': 'hello'});
    });
  });

  group('DebugAndPreview', () {
    Future<(WorkflowStore, FakeChat Function())> pump(WidgetTester t, {double width = 400, double? canvas}) async {
      FakeChat? chat;
      final store = await renderRun(
        t,
        Builder(
          builder: (context) => DebugAndPreview(
            controller: chat ??= FakeChat(WorkflowStoreScope.of(context)),
            panel: RunPanelContext(startVariables: [textVar('query', 'Query')]),
          ),
        ),
        initialStoreState: (s) {
          s.setPreviewPanelWidth(width);
          if (canvas != null) s.setWorkflowCanvasWidth(canvas);
        },
        size: const Size(800, 900),
      );
      return (store, () => chat!);
    }

    testWidgets('resizes from the left edge with the keyboard and persists the width', (t) async {
      final (store, _) = await pump(t, width: 480, canvas: 1000);
      t
          .widget<Focus>(find.descendant(of: find.byType(ResizeHandle), matching: find.byType(Focus)).first)
          .focusNode!
          .requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump();
      expect(store.previewPanelWidth.value, 488);
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump();
      expect(store.previewPanelWidth.value, 600);
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.pump();
      expect(store.previewPanelWidth.value, 400);
    });

    testWidgets('exposes and invokes the restart action by name', (t) async {
      final (store, chat) = await pump(t);
      store
        ..setNodeRunData('n1', {'_runningStatus': 'succeeded'})
        ..setEdgeRunData('e1', {'_sourceRunningStatus': 'succeeded'});
      await t.tap(find.bySemanticsLabel('common.operation.refresh'));
      expect(store.nodeRunData.value, isEmpty);
      expect(store.edgeRunData.value, isEmpty);
      expect(chat().restarts, 1);
    });

    testWidgets('exposes the user input field toggle state by name', (t) async {
      await pump(t);
      final toggle = find.bySemanticsLabel('workflow.panel.userInputField');
      expect(t.getSemantics(toggle).flagsCollection.isExpanded.toString(), contains('isTrue'));
      await t.tap(toggle);
      await t.pump();
      expect(t.getSemantics(toggle).flagsCollection.isExpanded.toString(), contains('isFalse'));
    });

    testWidgets('closes the panel through a named keyboard action', (t) async {
      final (store, _) = await pump(t);
      store.setShowDebugAndPreviewPanel(true);
      // The close button, found by its name.
      await t.tap(find.bySemanticsLabel('common.operation.close'));
      await t.pump();
      expect(store.showDebugAndPreviewPanel.value, isFalse);
    });
  });
}
