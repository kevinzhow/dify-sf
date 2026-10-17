import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/workflow_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the operator in the editor: bars mounted, minimap pans, shortcuts reach the canvas', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});

    final demo = DemoBackend(withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    var layouts = 0;
    final options = OperatorOptions(onOrganize: () => layouts++);

    WorkflowStore? store;
    CanvasController? canvas;
    await t.pumpWidget(
      MaterialApp(
        home: OperatorShortcuts(
          history: controller.undo,
          options: options,
          child: WorkflowEditor(
            controller: controller,
            control: (context, c) {
              store = WorkflowStoreScope.of(context);
              canvas = c;
              return workflowControlBuilder(options)(context, c);
            },
            operator: workflowOperatorBuilder(controller, options),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    expect(find.byType(WorkflowControl), findsOneWidget);
    expect(find.byType(UndoRedo), findsOneWidget);
    expect(find.byType(WorkflowMiniMap), findsOneWidget);
    // The bottom bar reported its height; the control bar is centred above it.
    expect(store!.bottomPanelHeight.value, lessThan(60));

    // Shortcuts work from the start (the wrapper takes focus) and after clicking the canvas.
    await t.sendKeyEvent(LogicalKeyboardKey.keyH);
    expect(store!.controlMode.value, ControlMode.hand);
    await t.tapAt(const Offset(800, 300));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    expect(store!.controlMode.value, ControlMode.pointer);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyO);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(layouts, 1);

    // Dragging on the minimap moves the view; the wheel zooms.
    final mini = t.getCenter(find.byType(WorkflowMiniMap));
    final percent = find.descendant(of: find.byType(ZoomInOut), matching: find.textContaining('%'));
    final before = t.widget<Text>(percent).data;
    final center = canvas!.view.center;
    final drag = await t.startGesture(mini, kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(10, 0));
    await drag.up();
    await t.pump();
    expect(canvas!.view.center.dx, greaterThan(center.dx));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(pointer.hover(mini));
    await t.sendEventToBinding(pointer.scroll(const Offset(0, -50)));
    await t.pump();
    expect(t.widget<Text>(percent).data, isNot(before));

    await t.pumpWidget(const SizedBox());
    controller.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
