// dify-spec: web/app/components/workflow/header/__tests__/undo-redo.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

void main() {
  group('UndoRedo', () {
    late WorkflowStore store;
    var undos = 0, redos = 0;

    setUp(() {
      store = WorkflowStore();
      undos = redos = 0;
    });

    Future<void> render(WidgetTester t, TestHistory history) => pumpWithStore(
      t,
      store,
      UndoRedo(history: history, onUndo: () => undos++, onRedo: () => redos++),
    );

    testWidgets('enables undo and redo when history exists and triggers the callbacks', (t) async {
      await render(t, TestHistory(past: 1, future: 1));

      await t.tap(pressable('common.undo'));
      await t.tap(pressable('common.redo'));

      expect(undos, 1);
      expect(redos, 1);
    });

    testWidgets('keeps unavailable history actions focusable without activating them', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, TestHistory());

      expect(t.getSemantics(pressable('common.undo')), isSemantics(isEnabled: false));
      expect(t.getSemantics(pressable('common.redo')), isSemantics(isEnabled: false));

      expect(await focusButton(t, 'common.undo'), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(await focusButton(t, 'common.redo'), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.space);

      expect(undos, 0);
      expect(redos, 0);
      semantics.dispose();
    });

    testWidgets('does not trigger callbacks when the canvas is read only', (t) async {
      final semantics = t.ensureSemantics();
      store.setCanvasReadOnly(true);
      await render(t, TestHistory(past: 1, future: 1));

      await t.tap(pressable('common.undo'));
      await t.tap(pressable('common.redo'));

      expect(t.getSemantics(pressable('common.undo')), isSemantics(isEnabled: false));
      expect(t.getSemantics(pressable('common.redo')), isSemantics(isEnabled: false));
      expect(undos, 0);
      expect(redos, 0);
      semantics.dispose();
    });

    testWidgets('unsubscribes from the temporal store on unmount', (t) async {
      final history = TestHistory();
      await render(t, history);
      expect(history.listening, isTrue);

      await t.pumpWidget(const SizedBox());

      expect(history.listening, isFalse);
    });
  });

  // view-workflow-history.tsx (no Dify spec): the change history list.
  group('ViewWorkflowHistory', () {
    testWidgets('lists future, current and past states and jumps to the chosen one', (t) async {
      final history = TestHistory(past: 2, future: 1);
      await pumpWithStore(t, WorkflowStore(), ViewWorkflowHistory(history: history));

      await t.tap(pressable('changeHistory.title'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      final rows = [for (final e in historyEntries(history)) historyEntryText(history, e)];
      expect(rows, [
        'LLM changeHistory.nodeDragStop (changeHistory.stepForward)',
        'LLM changeHistory.nodeDragStop (changeHistory.currentState)',
        'LLM changeHistory.nodeDragStop (changeHistory.stepBackward)',
        'changeHistory.sessionStart (changeHistory.stepBackward)',
      ]);
      for (final r in rows) {
        expect(find.text(r), findsOneWidget);
      }

      await t.tap(find.text(rows.last));
      await t.pump();
      expect((history.past.length, history.future.length), (0, 3));
    });

    testWidgets('shows the placeholder and no clear button without history', (t) async {
      await pumpWithStore(t, WorkflowStore(), ViewWorkflowHistory(history: TestHistory()));

      await t.tap(pressable('changeHistory.title'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(find.text('changeHistory.placeholder'), findsOneWidget);
      expect(find.text('changeHistory.clearHistory'), findsNothing);
    });
  });
}
