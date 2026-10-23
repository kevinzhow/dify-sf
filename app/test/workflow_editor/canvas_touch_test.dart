import 'package:dify_sf_app/src/canvas/canvas_view_state.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';

void main() {
  testWidgets('two fingers zoom around their midpoint without moving the touched node', (t) async {
    final h = await EditorHarness.start(t, [
      node('a', x: 200, y: 250),
    ], wrap: (child) => DifySelectionRegion(child: child));
    final center = h.nodeCenter('a'), before = h.doc.nodes['a']!;
    final anchor = h.canvas.view.toCanvas(center);
    final first = await t.startGesture(center - const Offset(50, 0), pointer: 1, kind: PointerDeviceKind.touch);
    final second = await t.startGesture(center + const Offset(50, 0), pointer: 2, kind: PointerDeviceKind.touch);
    for (var i = 1; i <= 8; i++) {
      await first.moveTo(center - Offset(50 + i * 6, 0));
      await second.moveTo(center + Offset(50 + i * 6, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(h.canvas.view.scale, greaterThan(1.4));
    expect((h.canvas.view.toCanvas(center) - anchor).distance, lessThan(2));
    await first.up();
    await second.up();
    await EditorHarness.settle(t);
    expect((h.doc.nodes['a']!.x, h.doc.nodes['a']!.y), (before.x, before.y));
    expect(h.controller.undo.past, isEmpty);
    await h.dispose(t);
  });

  testWidgets('a new single-finger pan works after a completed pinch', (t) async {
    final h = await EditorHarness.start(t, [
      node('a', x: 100, y: 100),
    ], wrap: (child) => DifySelectionRegion(child: child));
    final first = await t.startGesture(const Offset(120, 560), pointer: 1);
    final second = await t.startGesture(const Offset(270, 560), pointer: 2);
    for (var i = 1; i <= 6; i++) {
      await first.moveTo(Offset(120 - 9 * i.toDouble(), 560));
      await second.moveTo(Offset(270 + 9 * i.toDouble(), 560));
      await t.pump(const Duration(milliseconds: 60));
    }
    await first.up();
    await second.up();
    await t.pump(const Duration(milliseconds: 600));
    final before = h.canvas.view.center, scale = h.canvas.view.scale;
    final pan = await t.startGesture(const Offset(160, 580), pointer: 3);
    for (var i = 1; i <= 6; i++) {
      await pan.moveTo(Offset(160 + 10 * i.toDouble(), 580 + 4 * i.toDouble()));
      await t.pump(const Duration(milliseconds: 45));
    }
    await pan.up();
    await EditorHarness.settle(t);
    expect((h.canvas.view.center - (before - const Offset(60, 24) / scale)).distance, lessThan(.01));
    await h.dispose(t);
  });

  testWidgets('one finger on empty canvas pans rather than drawing a selection box', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 100, y: 100)]);
    final before = h.canvas.view.center;
    final drag = await t.startGesture(const Offset(700, 600), kind: PointerDeviceKind.touch);
    await drag.moveTo(const Offset(730, 620));
    await t.pump();
    await drag.moveTo(const Offset(780, 650));
    await t.pump();
    await drag.up();
    await EditorHarness.settle(t);
    expect(h.canvas.view.center, before - const Offset(80, 50));
    expect(h.controller.undo.past, isEmpty);
    await h.dispose(t);
  });

  testWidgets('a remaining finger after pinch cannot begin an accidental node drag', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 200, y: 250)]);
    final center = h.nodeCenter('a');
    final first = await t.startGesture(center - const Offset(50, 0), pointer: 1, kind: PointerDeviceKind.touch);
    final second = await t.startGesture(center + const Offset(50, 0), pointer: 2, kind: PointerDeviceKind.touch);
    await first.moveTo(center - const Offset(90, 0));
    await second.moveTo(center + const Offset(90, 0));
    await t.pump();
    await second.up();
    await t.pump();
    final scale = h.canvas.view.scale, view = h.canvas.view.center, before = h.doc.nodes['a']!;
    await first.moveTo(center + const Offset(130, 80));
    await t.pump();
    expect(h.canvas.view.scale, scale);
    expect(h.canvas.view.center, view);
    await first.up();
    await EditorHarness.settle(t);
    expect((h.doc.nodes['a']!.x, h.doc.nodes['a']!.y), (before.x, before.y));
    await h.dispose(t);
  });

  testWidgets('single-finger node drag remains one undo step', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 200, y: 250)]);
    final from = h.nodeCenter('a');
    final finger = await t.startGesture(from, kind: PointerDeviceKind.touch);
    await t.pump(const Duration(milliseconds: 150));
    await finger.moveTo(from + const Offset(30, 20));
    await t.pump();
    await finger.moveTo(from + const Offset(60, 40));
    await t.pump();
    await finger.up();
    await EditorHarness.settle(t);
    expect((h.doc.nodes['a']!.x, h.doc.nodes['a']!.y), (260, 290));
    expect(h.controller.undo.past, hasLength(1));
    h.controller.undo.undo();
    await EditorHarness.settle(t);
    expect((h.doc.nodes['a']!.x, h.doc.nodes['a']!.y), (200, 250));
    await h.dispose(t);
  });

  testWidgets('a completed finger connection persists one edge', (t) async {
    final h = await EditorHarness.start(t, [
      node('a', x: 100, y: 100),
      node('b', x: 500, y: 300),
    ], wrap: (child) => DifySelectionRegion(child: child));
    final finger = await t.startGesture(h.outPort('a'));
    await finger.moveTo(h.outPort('a') + const Offset(25, 0));
    await t.pump();
    await finger.moveTo(h.nodeCenter('b'));
    await t.pump();
    await finger.up();
    await EditorHarness.settle(t);
    expect(h.doc.edges, hasLength(1));
    expect((h.doc.edges.values.single.source, h.doc.edges.values.single.target), ('a', 'b'));
    await h.dispose(t);
  });

  testWidgets('read-only touch can navigate without moving or connecting nodes', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 100, y: 100)], canEdit: false);
    final finger = await t.startGesture(h.nodeCenter('a'));
    await finger.moveBy(const Offset(60, 30));
    await t.pump();
    await finger.up();
    final pan = await t.startGesture(const Offset(800, 600));
    final before = h.canvas.view.center;
    await pan.moveBy(const Offset(60, 30));
    await t.pump();
    await pan.up();
    await EditorHarness.settle(t);
    expect(h.canvas.view.center, before - const Offset(60, 30));
    expect((h.doc.nodes['a']!.x, h.doc.nodes['a']!.y), (100, 100));
    expect(h.doc.edges, isEmpty);
    expect(h.controller.undo.past, isEmpty);
    await h.dispose(t);
  });

  testWidgets('cancelled pointer does not drop a connection onto a node', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 100, y: 100), node('b', x: 500, y: 300)]);
    final finger = await t.startGesture(h.outPort('a'), kind: PointerDeviceKind.touch);
    await finger.moveTo(h.nodeCenter('b'));
    await t.pump();
    await finger.cancel();
    await EditorHarness.settle(t);
    expect(h.doc.edges, isEmpty);
    await h.dispose(t);
  });

  testWidgets('pinch clamps at both zoom limits and double tap zooms empty canvas', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 50, y: 50)]);
    final first = await t.startGesture(const Offset(500, 500), pointer: 1);
    final second = await t.startGesture(const Offset(600, 500), pointer: 2);
    await first.moveTo(const Offset(100, 500));
    await second.moveTo(const Offset(1000, 500));
    await t.pump();
    expect(h.canvas.view.scale, CanvasViewState.maxScale);
    await first.up();
    await second.up();
    await t.pump();
    final a = await t.startGesture(const Offset(100, 600), pointer: 3);
    final b = await t.startGesture(const Offset(1100, 600), pointer: 4);
    await a.moveTo(const Offset(590, 600));
    await b.moveTo(const Offset(610, 600));
    await t.pump();
    expect(h.canvas.view.scale, CanvasViewState.minScale);
    await a.up();
    await b.up();
    await EditorHarness.settle(t);
    await t.tapAt(const Offset(800, 700));
    await t.pump(const Duration(milliseconds: 80));
    await t.tapAt(const Offset(800, 700));
    await EditorHarness.settle(t);
    expect(h.canvas.view.scale, .5);
    await h.dispose(t);
  });

  testWidgets('trackpad pan/zoom remains handled once by the desktop path', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 50, y: 50)]);
    final before = h.canvas.view.center;
    await t.sendEventToBinding(const PointerPanZoomStartEvent(pointer: 20, position: Offset(600, 400)));
    await t.sendEventToBinding(
      const PointerPanZoomUpdateEvent(
        pointer: 20,
        position: Offset(600, 400),
        pan: Offset(40, 20),
        panDelta: Offset(40, 20),
        scale: 1.5,
      ),
    );
    await t.sendEventToBinding(const PointerPanZoomEndEvent(pointer: 20, position: Offset(600, 400)));
    await EditorHarness.settle(t);
    expect(h.canvas.view.scale, 1.5);
    expect(h.canvas.view.center, before - const Offset(40, 20));
    expect(h.controller.undo.past, isEmpty);
    await h.dispose(t);
  });

  testWidgets('long press opens existing node menu without moving the node', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 200, y: 250)]);
    await t.longPressAt(h.nodeCenter('a'));
    await EditorHarness.settle(t);
    expect(h.store.contextMenuTarget.value, isA<NodeContextMenuTarget>());
    expect(find.byType(DifyMenuItem), findsWidgets);
    expect((h.doc.nodes['a']!.x, h.doc.nodes['a']!.y), (200, 250));
    expect(h.controller.undo.past, isEmpty);
    await h.dispose(t);
  });
}
