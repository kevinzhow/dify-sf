import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  testWidgets('hover handle follows every drag frame before the document commits', (t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', journaled: false),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final state = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas));
    final canvas = state.canvas;
    final start = t.getCenter(find.byKey(const ValueKey('node-code')));
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(start);
    await t.pump();
    final handle = find.byKey(const ValueKey('out-code-source'));
    expect(handle, findsOneWidget);
    final docX = state.widget.controller.doc.nodes['code']!.x;
    await mouse.down(start);
    for (final delta in [const Offset(43, 21), const Offset(137, 53), const Offset(65, 103)]) {
      await mouse.moveTo(start + delta);
      await t.pump(const Duration(milliseconds: 16));
      // The document commits on pointer up; ports must follow live geometry.
      expect(state.widget.controller.doc.nodes['code']!.x, docX);
      final port = canvas.graph!['code']!.outPortFor('source') - const Offset(8, 0);
      final canvasBox = t.renderObject<RenderBox>(find.byType(WorkflowCanvas));
      expect(
        t.getCenter(handle),
        offsetMoreOrLessEquals(canvasBox.localToGlobal(canvas.view.toScreen(port)), epsilon: 0.01),
      );
    }
    await mouse.up();
    await mouse.removePointer();
    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
