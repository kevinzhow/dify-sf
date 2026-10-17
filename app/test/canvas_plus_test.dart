import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

String _title(String type) => DifyI18n.tr('workflow', 'blocks.$type');

void main() {
  Future<(DemoBackend, DifyWorkflowEditor)> open(WidgetTester t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    return (demo, t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)));
  }

  Future<void> close(WidgetTester t, DemoBackend demo) async {
    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }

  testWidgets('hovering a node shows "+" on its source handle; picking a block inserts after it', (t) async {
    final (demo, editor) = await open(t);
    final c = editor.controller;
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.byKey(const ValueKey('node-code'))));
    await t.pump(const Duration(milliseconds: 100));
    final plus = find.byKey(const ValueKey('out-code-source'));
    expect(plus, findsOneWidget);
    await mouse.moveTo(t.getCenter(plus));
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(plus);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(BlockSelectorCard), matching: find.text(_title('template-transform'))));
    await t.pump(const Duration(milliseconds: 500));
    final added = c.doc.nodes.values.singleWhere((n) => n.type == 'template-transform');
    expect(c.doc.edges.values.where((e) => e.source == 'code' && e.target == added.id), hasLength(1));
    expect(c.undo.past, hasLength(1));
    await mouse.removePointer();
    await close(t, demo);
  });

  testWidgets('hovering an edge shows "+" at its middle; picking a block inserts between its nodes', (t) async {
    final (demo, editor) = await open(t);
    final c = editor.controller;
    final edge = c.doc.edges.values.firstWhere((e) => e.source == 'start');
    final target = edge.target;
    // The middle of the edge on screen: between the start node's right side and the target's left side.
    final a = t.getRect(find.byKey(const ValueKey('node-start'))), b = t.getRect(find.byKey(ValueKey('node-$target')));
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    var found = false;
    for (var x = a.right + 4; x < b.left - 4 && !found; x += 4) {
      for (var y = a.top; y < b.bottom && !found; y += 2) {
        await mouse.moveTo(Offset(x, y));
        await t.pump();
        found = find.byKey(ValueKey('edge-${edge.id}')).evaluate().isNotEmpty;
      }
    }
    expect(found, isTrue, reason: 'the edge "+" appears on hover');
    final plus = find.byKey(ValueKey('edge-${edge.id}'));
    await mouse.moveTo(t.getCenter(plus));
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(plus);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(BlockSelectorCard), matching: find.text(_title('template-transform'))));
    await t.pump(const Duration(milliseconds: 500));
    final added = c.doc.nodes.values.singleWhere((n) => n.type == 'template-transform');
    expect(c.doc.edges.values.where((e) => e.source == 'start' && e.target == added.id), hasLength(1));
    expect(c.doc.edges.values.where((e) => e.source == added.id && e.target == target), hasLength(1));
    expect(c.doc.edges.containsKey(edge.id), isFalse);
    await mouse.removePointer();
    await close(t, demo);
  });
}
