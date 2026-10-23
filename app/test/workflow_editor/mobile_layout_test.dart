import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/app_detail/app_sidebar.dart';
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_buttons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  for (final width in [320.0, 390.0, 640.0]) {
    testWidgets('phone $width keeps the sidebar left and the header on one band', (t) async {
      await useAppFonts();
      SharedPreferences.setMockInitialValues({detailSidebarStorageKey: 'expand'});
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final demo = DemoBackend(withBo: false);
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: DetailSidebarFrame(
            renderTop: (context, expand, toggle) => AppDetailTop(expand: expand, onToggle: toggle, onHome: () {}),
            renderSection: (context, expand) => const SizedBox.shrink(),
            accountSection: (context, compact) => const SizedBox.shrink(),
            child: EditorPage(backend: demo, docId: 'demo', clientId: 'original-layout', journaled: false),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 15; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await settle();
      expect(t.takeException(), isNull);
      final canvas = find.byType(WorkflowCanvas);
      expect(t.getRect(canvas).left, 64);
      expect(t.getRect(canvas).top, 0);
      final toggle = find.byWidgetPredicate((w) => w is DetailSidebarToggleButton && !w.expand);
      final top = t.getCenter(toggle).dy;
      expect(top, 28);
      expect(t.getCenter(find.byType(HeaderInNormal)).dy, top);
      await t.tap(toggle);
      await settle();
      final close = find.byWidgetPredicate((w) => w is DetailSidebarToggleButton && w.expand);
      expect(close, findsOneWidget);
      await t.tap(close);
      await settle();
      expect((await SharedPreferences.getInstance()).getString(detailSidebarStorageKey), 'expand');
      final strip = find.descendant(of: find.byType(HeaderInNormal), matching: find.byType(DifyToolbarStrip));
      await t.drag(strip, const Offset(-1000, 0));
      await settle();
      expect(t.getRect(find.byType(VersionHistoryButton)).right, lessThanOrEqualTo(width));
      final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
      c.selectNode(c.doc.nodes.values.first.id);
      await settle();
      expect(t.takeException(), isNull);
      final rect = t.getRect(find.byType(WorkflowNodePanel));
      expect(rect.left, greaterThanOrEqualTo(64));
      expect(rect.right, lessThanOrEqualTo(width));
      await t.pumpWidget(const SizedBox());
      await demo.dispose();
      await t.pump(const Duration(seconds: 20));
    });
  }

  testWidgets('phone panels and history headers remain usable', (t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: EditorPage(backend: demo, docId: 'demo', clientId: 'mobile-panels', journaled: false),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 15; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
    store.setShowEnvPanel(true);
    await settle();
    expect(t.takeException(), isNull, reason: 'environment panel');
    store.setShowEnvPanel(false);
    store.setShowDebugAndPreviewPanel(true);
    await settle();
    expect(t.takeException(), isNull, reason: 'test run panel');
    store.setShowDebugAndPreviewPanel(false);
    store.setHistoryWorkflowData({'id': 'mobile-history', 'status': 'succeeded'});
    await settle();
    expect(t.takeException(), isNull, reason: 'history header');
    final headerScroll = find.descendant(of: find.byType(WorkflowHeader), matching: find.byType(SingleChildScrollView));
    await t.drag(headerScroll, const Offset(-800, 0));
    await settle();
    final back = find.descendant(of: find.byType(HeaderInHistory), matching: find.byType(DifyButton));
    expect(t.getRect(back).right, lessThanOrEqualTo(390));
    await t.tap(back);
    await settle();
    expect(store.historyWorkflowData.value, isNull);
    store.isRestoring.value = true;
    await settle();
    expect(t.takeException(), isNull, reason: 'restore header');
    await t.drag(headerScroll, const Offset(-800, 0));
    await settle();
    final exit = find.descendant(of: find.byType(HeaderInRestoring), matching: find.byType(DifyButton)).last;
    expect(t.getRect(exit).right, lessThanOrEqualTo(390));
    await t.tap(exit);
    await settle();
    expect(store.isRestoring.value, isFalse);
    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });

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
