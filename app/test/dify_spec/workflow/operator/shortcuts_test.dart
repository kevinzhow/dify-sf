// dify-spec: web/app/components/workflow/hooks/__tests__/use-shortcuts.spec.ts
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

void main() {
  late WorkflowStore store;
  late TestCanvas canvas;
  late TestHistory history;
  var layouts = 0, syncs = 0;

  setUp(() {
    store = WorkflowStore();
    canvas = TestCanvas();
    history = TestHistory(past: 1);
    layouts = syncs = 0;
  });

  /// The shortcuts around an "editor" holding a text field and a bar that hands over the canvas and store.
  Future<void> render(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: OperatorShortcuts(
            history: history,
            options: OperatorOptions(onOrganize: () => layouts++, onSyncDraft: () => syncs++),
            child: WorkflowStoreScope(
              store: store,
              child: OperatorShortcutsTarget(canvas: canvas, child: const TextField()),
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  Future<void> press(WidgetTester t, LogicalKeyboardKey key, {bool ctrl = false, bool shift = false}) async {
    if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(key);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  group('useShortcuts', () {
    testWidgets('runs layout and zoom shortcuts through the workflow actions', (t) async {
      await render(t);

      await press(t, LogicalKeyboardKey.keyO, ctrl: true);
      expect(layouts, 1);
      await press(t, LogicalKeyboardKey.digit5, shift: true);
      expect(canvas.view.scale, 0.5);
      await press(t, LogicalKeyboardKey.minus, ctrl: true);
      expect(canvas.view.scale, closeTo(0.4, 1e-9));
      await press(t, LogicalKeyboardKey.equal, ctrl: true);
      expect(canvas.view.scale, closeTo(0.5, 1e-9));
      await press(t, LogicalKeyboardKey.digit1, shift: true);
      expect(canvas.view.scale, 1);
      expect(syncs, 4);
    });
  });

  // Not in Dify's spec: undo / redo, modes, and inputs.
  group('OperatorShortcuts', () {
    testWidgets('undoes, redoes and switches modes; not while typing or with history shortcuts off', (t) async {
      await render(t);

      await press(t, LogicalKeyboardKey.keyZ, ctrl: true);
      expect((history.past.length, history.future.length), (0, 1));
      await press(t, LogicalKeyboardKey.keyZ, ctrl: true, shift: true);
      expect((history.past.length, history.future.length), (1, 0));
      await press(t, LogicalKeyboardKey.keyH);
      expect(store.controlMode.value, ControlMode.hand);
      await press(t, LogicalKeyboardKey.keyV);
      expect(store.controlMode.value, ControlMode.pointer);

      store.setHistoryShortcutsEnabled(false);
      await press(t, LogicalKeyboardKey.keyZ, ctrl: true);
      expect(history.past.length, 1);

      await t.tap(find.byType(TextField));
      await t.pump();
      await press(t, LogicalKeyboardKey.keyH);
      expect(store.controlMode.value, ControlMode.pointer);
    });
  });
}
