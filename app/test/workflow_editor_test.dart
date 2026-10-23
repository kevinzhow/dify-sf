import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/workflow_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the editor provides its store: control mode shared with the canvas, hydrated, measured', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({'workflow-operation-mode': 'hand', 'workflow-node-panel-width': '460'});

    final demo = DemoBackend(withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);

    WorkflowStore? store;
    CanvasController? canvas;
    await t.pumpWidget(
      MaterialApp(
        home: WorkflowEditor(
          controller: controller,
          control: (context, c) {
            store = WorkflowStoreScope.of(context);
            canvas = c;
            return const SizedBox();
          },
        ),
      ),
    );
    await t.pump();

    expect(store!.controlMode, same(canvas!.controlMode));
    expect(store!.controlMode.value, ControlMode.hand);
    expect(store!.nodePanelWidth.value, 460);
    expect(store!.panelWidth.value, 460);
    expect(store!.workflowCanvasWidth.value, 1600);
    expect(store!.workflowCanvasHeight.value, 900);

    canvas!.controlMode.value = ControlMode.pointer;
    await t.pump();
    expect((await SharedPreferences.getInstance()).getString('workflow-operation-mode'), 'pointer');

    await t.pumpWidget(const SizedBox());
    controller.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
