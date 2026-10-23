import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/workflow_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('canvas panning preserves chrome paint and chrome updates still paint', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(server: FakeServer(initial: Document()), withBo: false);
    final opened = await demo.openSession('demo', clientId: 'paint-test', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    for (var i = 0; i < 50 && !controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final paints = <String, int>{};
    Widget region(String name, Widget child) => _PaintObserver(
      onPaint: () => paints.update(name, (count) => count + 1, ifAbsent: () => 1),
      child: child,
    );
    final label = ValueNotifier('Header');
    try {
      await t.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              region('sidebar', const SizedBox(width: 80, child: ColoredBox(color: Colors.blue))),
              Expanded(
                child: WorkflowEditor(
                  controller: controller,
                  header: (context, canvas) => ValueListenableBuilder(
                    valueListenable: label,
                    builder: (context, value, _) =>
                        region('header', SizedBox(width: 160, height: 24, child: Text(value))),
                  ),
                  control: (context, canvas) =>
                      region('control', const SizedBox(width: 24, height: 24, child: Text('C'))),
                  operator: (context, canvas) => region('operator', const SizedBox(height: 24, child: Text('O'))),
                  panels: (context, canvas) => region('panels', const SizedBox(width: 120, child: Text('P'))),
                ),
              ),
            ],
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final canvas = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas)).canvas;
      final beforePan = Map<String, int>.of(paints);
      expect(beforePan.keys.toSet(), {'sidebar', 'header', 'control', 'operator', 'panels'});
      for (var i = 0; i < 20; i++) {
        canvas.view.center += const Offset(1, 0);
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(
        paints,
        beforePan,
        reason: 'Only the canvas changed; the editor chrome and surrounding page are unchanged.',
      );
      label.value = 'Updated header';
      await t.pump();
      expect(find.text('Updated header'), findsOneWidget);
      expect(paints['header'], greaterThan(beforePan['header']!), reason: 'Real chrome changes must still paint.');
      for (final name in ['sidebar', 'control', 'operator', 'panels']) {
        expect(paints[name], beforePan[name], reason: 'Updating the header should not repaint $name.');
      }
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      label.dispose();
      controller.dispose();
      await opened.close();
      await demo.dispose();
      await t.pump(const Duration(seconds: 20));
    }
  });
}

class _PaintObserver extends SingleChildRenderObjectWidget {
  const _PaintObserver({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) => _PaintObserverBox(onPaint);
  @override
  void updateRenderObject(BuildContext context, covariant _PaintObserverBox renderObject) {
    renderObject.onPaint = onPaint;
  }
}

class _PaintObserverBox extends RenderProxyBox {
  _PaintObserverBox(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}
