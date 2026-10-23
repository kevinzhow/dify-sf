// dify-spec: web/app/components/workflow/panel/chat-record/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/panel/chat-record/__tests__/user-input.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run/run_harness.dart';

const _history = {'id': 'run-1', 'status': 'succeeded', 'conversation_id': 'conversation-1', 'finished_at': 1700000000};

Finder markdown(String text) => find.textContaining(text, findRichText: true);

void main() {
  group('ChatRecord', () {
    testWidgets('renders fetched chat history with the real chat shell and switches siblings', (t) async {
      final fetched = <String>[];
      await renderRun(
        t,
        ChatRecord(
          fetchChatMessages: (id) async {
            fetched.add(id);
            return [
              {'id': 'msg-1', 'query': 'Question 1', 'answer': 'Answer 1', 'metadata': {}, 'message_files': []},
              {
                'id': 'msg-2',
                'query': 'Question 2',
                'answer': 'Answer 2',
                'parent_message_id': 'msg-1',
                'metadata': {},
                'message_files': [],
              },
              {
                'id': 'msg-3',
                'query': 'Question 3',
                'answer': 'Answer 3',
                'parent_message_id': 'msg-1',
                'metadata': {},
                'message_files': [],
              },
            ];
          },
        ),
        initialStoreState: (s) => s.setHistoryWorkflowData(_history),
        size: const Size(420, 1200),
      );
      await t.pump();
      await t.pump();
      expect(fetched, ['conversation-1']);
      expect(markdown('Question 1'), findsOneWidget);
      expect(markdown('Answer 1'), findsOneWidget);
      expect(markdown('Question 3'), findsOneWidget);
      expect(markdown('Answer 3'), findsOneWidget);
      expect(markdown('Question 2'), findsNothing);
      await t.tap(find.bySemanticsLabel('Previous').first);
      await t.pump();
      expect(markdown('Question 2'), findsOneWidget);
      expect(markdown('Answer 2'), findsOneWidget);
      expect(markdown('Question 3'), findsNothing);
    });

    testWidgets('closes the record panel and restores the backup draft', (t) async {
      var restored = 0;
      final store = await renderRun(
        t,
        ChatRecord(
          onClose: () => restored++,
          fetchChatMessages: (_) async => [
            {'id': 'msg-1', 'query': 'Question 1', 'answer': 'Answer 1', 'metadata': {}, 'message_files': []},
          ],
        ),
        initialStoreState: (s) => s.setHistoryWorkflowData(_history),
      );
      await t.pump();
      await t.pump();
      expect(markdown('Question 1'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('close'));
      expect(restored, 1);
      expect(store.historyWorkflowData.value, isNull);
    });

    testWidgets('stops loading when conversation fetching fails', (t) async {
      await renderRun(
        t,
        ChatRecord(fetchChatMessages: (_) async => throw Exception('network error')),
        initialStoreState: (s) => s.setHistoryWorkflowData(_history),
      );
      await t.pump();
      await t.pump();
      expect(find.textContaining('TEST CHAT'), findsOneWidget);
      expect(markdown('Question 1'), findsNothing);
    });
  });

  group('chat-record UserInput', () {
    testWidgets('returns null when there are no variables', (t) async {
      await renderRun(t, const ChatRecordUserInput());
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('toggles the variable list from the header', (t) async {
      await renderRun(
        t,
        const ChatRecordUserInput(
          variables: [
            {'variable': 'query'},
            {'variable': 'locale'},
          ],
          initialExpanded: false,
        ),
      );
      Finder rows() => find.byWidgetPredicate(
        (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('record-input-'),
      );
      expect(rows(), findsNothing);
      await t.tap(find.text('WORKFLOW.PANEL.USERINPUTFIELD'));
      await t.pump();
      expect(rows(), findsNWidgets(2));
      await t.tap(find.text('WORKFLOW.PANEL.USERINPUTFIELD'));
      await t.pump();
      expect(rows(), findsNothing);
    });
  });
}
