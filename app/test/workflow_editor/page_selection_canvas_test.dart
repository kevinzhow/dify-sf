import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  testWidgets('real editor page retains canvas keys after repeated drags open the node panel', (t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: EditorPage(
          backend: demo,
          docId: 'demo',
          clientId: 'selection-probe',
          journaled: false,
        ),
      ),
    );
    Future<void> settle([int ms = 1000]) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await settle(2000);
    final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    final canvas = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas)).canvas;
    final id = c.doc.nodes.values.first.id;
    for (var i = 0; i < 8; i++) {
      final n = canvas.graph![id]!;
      final from = t.getTopLeft(find.byType(WorkflowCanvas)) + canvas.view.toScreen(n.rect.center);
      final drag = await t.startGesture(from, kind: PointerDeviceKind.mouse);
      // A slow mouse down outlasts the ancestor selection tap-down deadline.
      await t.pump(const Duration(milliseconds: 150));
      await drag.moveTo(from + const Offset(6, 3.5));
      await t.pump(const Duration(milliseconds: 16));
      await drag.moveTo(from + const Offset(12, 7));
      await drag.up();
      await settle(200);
    }
    await settle();
    final x = c.doc.nodes[id]!.x;
    final primary = FocusManager.instance.primaryFocus?.debugLabel;
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle();
    expect(c.doc.nodes[id]!.x, x + 5, reason: 'primary focus before key: $primary');
    final n = canvas.graph![id]!;
    final center = t.getTopLeft(find.byType(WorkflowCanvas)) + canvas.view.toScreen(n.rect.center);
    final click = await t.startGesture(center, kind: PointerDeviceKind.mouse);
    await t.pump(const Duration(milliseconds: 150));
    await click.up();
    await settle();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle();
    expect(c.doc.nodes[id]!.x, x);
    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }, variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.macOS}));
}
