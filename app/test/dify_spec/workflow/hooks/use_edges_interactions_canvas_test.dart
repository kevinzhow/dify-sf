// dify-spec: web/app/components/workflow/hooks/__tests__/use-edges-interactions.spec.ts
//
// handleEdgeEnter / handleEdgeLeave on the canvas: the hovered edge is CanvasSelection.hoveredEdge (Dify's
// `data._hovering`, which reveals the edge's "+").
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'editor_harness.dart';

const _edges = [
  Edge(id: 'e1', source: 'n1', sourceHandle: 'source', target: 'n2', targetHandle: 'target'),
  Edge(id: 'e2', source: 'n3', sourceHandle: 'source', target: 'n4', targetHandle: 'target'),
];

Future<EditorHarness> _start(WidgetTester t, {bool readOnly = false}) => EditorHarness.start(
  t,
  [node('n1', x: 100, y: 100), node('n2', x: 500, y: 100), node('n3', x: 100, y: 400), node('n4', x: 500, y: 400)],
  edges: _edges,
  canEdit: !readOnly,
);

Offset _edgeMiddle(EditorHarness h, String id) {
  final e = h.doc.edges[id]!;
  final g = h.canvas.graph!;
  final pts = edgeCurve(g[e.source]!.outPortFor(e.sourceHandle), g[e.target]!.inPort);
  return h.screen(pts[pts.length ~/ 2]);
}

void main() {
  group('useEdgesInteractions', () {
    testWidgets('handleEdgeEnter should set _hovering to true', (t) async {
      final h = await _start(t);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1150, 750));
      await mouse.moveTo(_edgeMiddle(h, 'e1'));
      await t.pump();
      expect(h.canvas.selection.hoveredEdge.value, 'e1');
      await mouse.removePointer();
      await h.dispose(t);
    });

    testWidgets('handleEdgeLeave should set _hovering to false', (t) async {
      final h = await _start(t);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: _edgeMiddle(h, 'e1'));
      await mouse.moveTo(_edgeMiddle(h, 'e1') + const Offset(0, 1));
      await t.pump();
      expect(h.canvas.selection.hoveredEdge.value, 'e1');
      await mouse.moveTo(const Offset(1150, 750));
      await t.pump();
      expect(h.canvas.selection.hoveredEdge.value, isNull);
      await mouse.removePointer();
      await h.dispose(t);
    });

    testWidgets('handleEdgesChange should update edge.selected for select changes', (t) async {
      final h = await _start(t);
      await t.tapAt(_edgeMiddle(h, 'e1'), kind: PointerDeviceKind.mouse);
      await t.pump();
      expect(h.canvas.selection.edge, 'e1');
      await t.tapAt(_edgeMiddle(h, 'e2'), kind: PointerDeviceKind.mouse);
      await t.pump();
      // One edge is selected at a time: e2 selected, e1 not.
      expect(h.canvas.selection.edge, 'e2');
      await h.dispose(t);
    });

    group('read-only mode', () {
      testWidgets('handleEdgeEnter should do nothing', (t) async {
        final h = await _start(t, readOnly: true);
        final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1150, 750));
        await mouse.moveTo(_edgeMiddle(h, 'e1'));
        await t.pump();
        expect(h.canvas.selection.hoveredEdge.value, isNull);
        await mouse.removePointer();
        await h.dispose(t);
      });
    });
  });
}
