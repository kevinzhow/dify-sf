// dify-spec: web/app/components/workflow/operator/__tests__/control.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

void main() {
  group('Control', () {
    late WorkflowStore store;
    late TestCanvas canvas;
    var notes = 0, layouts = 0;

    setUp(() {
      store = WorkflowStore();
      canvas = TestCanvas();
      notes = layouts = 0;
    });

    Future<void> render(WidgetTester t) => pumpWithStore(
      t,
      store,
      WorkflowControl(
        canvas: canvas,
        options: OperatorOptions(
          collaborationEnabled: true,
          onAddNote: () => notes++,
          onOrganize: () => layouts++,
        ),
      ),
    );

    // Rendering and semantic states for control buttons.
    group('Rendering', () {
      testWidgets('should render the child action groups and highlight the active pointer mode', (t) async {
        final semantics = t.ensureSemantics();
        await render(t);

        expect(find.byType(AddBlock), findsOneWidget);
        expect(find.byType(MoreActions), findsOneWidget);
        expect(t.getSemantics(pressable('common.pointerMode')), isSemantics(isToggled: true));
        expect(t.getSemantics(pressable('common.handMode')), isSemantics(isToggled: false));
        semantics.dispose();
      });

      testWidgets('should highlight hand mode when it is active', (t) async {
        final semantics = t.ensureSemantics();
        store.setControlMode(ControlMode.hand);
        await render(t);

        expect(t.getSemantics(pressable('common.handMode')), isSemantics(isToggled: true));
        semantics.dispose();
      });
    });

    // User interactions exposed by the control bar.
    group('User Interactions', () {
      testWidgets('should trigger the note, mode, and organize handlers', (t) async {
        store.setControlMode(ControlMode.hand);
        await render(t);

        await t.tap(pressable('nodes.note.addNote'));
        await t.tap(pressable('common.pointerMode'));
        await t.pump();
        expect(store.controlMode.value, ControlMode.pointer);
        await t.tap(pressable('common.handMode'));
        await t.pump();
        expect(store.controlMode.value, ControlMode.hand);
        await t.tap(pressable('common.commentMode'));
        await t.pump();
        expect(store.controlMode.value, ControlMode.comment);
        await t.tap(pressable('panel.organizeBlocks'));

        expect(notes, 1);
        expect(layouts, 1);
      });

      testWidgets('should keep read-only actions focusable without activating them', (t) async {
        final semantics = t.ensureSemantics();
        store.setCanvasReadOnly(true);
        await render(t);

        expect(t.getSemantics(pressable('nodes.note.addNote')), isSemantics(isEnabled: false));
        expect(await focusButton(t, 'nodes.note.addNote'), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);

        expect(notes, 0);
        semantics.dispose();
      });

      testWidgets('should keep comment mode enabled when nodes are read-only', (t) async {
        final semantics = t.ensureSemantics();
        store.setCanvasReadOnly(true);
        await render(t);

        expect(t.getSemantics(pressable('common.commentMode')), isSemantics(isEnabled: true));
        await t.tap(pressable('common.commentMode'));

        expect(store.controlMode.value, ControlMode.comment);
        semantics.dispose();
      });

      testWidgets('should keep blocked comment mode focusable without activating it', (t) async {
        final semantics = t.ensureSemantics();
        store.setWorkflowRunningData({
          'result': {'status': 'running'},
        });
        await render(t);

        expect(t.getSemantics(pressable('common.commentMode')), isSemantics(isEnabled: false));
        expect(await focusButton(t, 'common.commentMode'), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);

        expect(store.controlMode.value, ControlMode.pointer);
        semantics.dispose();
      });
    });
  });
}
