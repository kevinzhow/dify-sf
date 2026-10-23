import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  for (final width in [320.0, 360.0, 390.0, 430.0, 640.0]) {
    testWidgets('phone $width: header, panels, keyboard and rotation remain reachable', (t) async {
      await useAppFonts();
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final demo = DemoBackend(withBo: false);
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: EditorPage(backend: demo, docId: 'demo', clientId: 'mobile-layout', journaled: false),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await settle();
      expect(t.takeException(), isNull);
      final editor = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor));
      final c = editor.controller;
      final ctx = t.element(find.byType(WorkflowCanvas));
      final store = WorkflowStoreScope.of(ctx);
      final storedWidth = store.nodePanelWidth.value;
      c.selectNode(c.doc.nodes.values.first.id);
      await settle();
      expect(t.takeException(), isNull);
      final rect = t.getRect(find.byType(WorkflowNodePanel));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(width));
      expect(store.nodePanelWidth.value, storedWidth);
      // A real keyboard inset resizes the host; the panel close/header stay visible.
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await settle();
      expect(t.takeException(), isNull);
      expect(t.getRect(find.byType(WorkflowNodePanel)).bottom, lessThanOrEqualTo(544));
      t.view.viewInsets = const FakeViewPadding();
      t.view.physicalSize = const Size(1200, 844);
      await settle();
      expect(t.takeException(), isNull);
      expect(store.nodePanelWidth.value, storedWidth);
      expect(t.getRect(find.byType(WorkflowNodePanel)).width, greaterThanOrEqualTo(storedWidth));
      await t.pumpWidget(const SizedBox());
      await demo.dispose();
      await t.pump(const Duration(seconds: 20));
    });
  }
}
