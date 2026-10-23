// dify-spec: web/app/components/workflow/hooks/__tests__/use-edges-interactions.helpers.spec.ts
//
// The helpers' effects through the actions that use them (WorkflowActions over the canvas selection and the store);
// the hovered edge is the canvas's (one at a time).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';
import 'editor_harness.dart' show EditorHarness;

const _edges = [
  Edge(id: 'edge-1', source: 'node-1', sourceHandle: 'a', target: 'node-2', targetHandle: 'target'),
  Edge(id: 'edge-2', source: 'node-1', sourceHandle: 'b', target: 'node-2', targetHandle: 'target'),
  Edge(id: 'edge-3', source: 'node-2', sourceHandle: 'source', target: 'node-3', targetHandle: 'target'),
];

Future<Harness> _start(WidgetTester t) =>
    Harness.start(t, [node('node-1'), node('node-2', x: 300), node('node-3', x: 600)], edges: _edges);

void main() {
  group('use-edges-interactions.helpers', () {
    testWidgets('clearEdgeMenuIfNeeded should return true only when the open menu belongs to a removed edge', (
      t,
    ) async {
      final h = await _start(t);
      // The open menu belongs to a removed edge: it closes.
      h.store.setContextMenuTarget(const EdgeContextMenuTarget('edge-1'));
      h.actions().deleteBranch('node-1', 'a');
      expect(h.store.contextMenuTarget.value, isNull);
      // Another edge's menu stays.
      h.store.setContextMenuTarget(const EdgeContextMenuTarget('edge-3'));
      h.actions().deleteBranch('node-1', 'b');
      expect(h.store.contextMenuTarget.value, const EdgeContextMenuTarget('edge-3'));
      // No menu: nothing to close.
      h.store.setContextMenuTarget(null);
      h.actions().deleteEdge('edge-3');
      expect(h.store.contextMenuTarget.value, isNull);
      await h.dispose(t);
    });

    testWidgets('updateEdgeHoverState should toggle only the hovered edge flag', (t) async {
      final h = await EditorHarness.start(
        t,
        [node('node-1', x: 100, y: 100), node('node-2', x: 500, y: 100), node('node-3', x: 100, y: 400)],
        edges: const [
          Edge(id: 'edge-1', source: 'node-1', sourceHandle: 'source', target: 'node-2', targetHandle: 'target'),
          Edge(id: 'edge-2', source: 'node-3', sourceHandle: 'source', target: 'node-2', targetHandle: 'target'),
        ],
      );
      final g = h.canvas.graph!;
      final pts = edgeCurve(g['node-3']!.outPortFor('source'), g['node-2']!.inPort);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1150, 750));
      await mouse.moveTo(h.screen(pts[pts.length ~/ 2]));
      await t.pump();
      // Only edge-2 is hovered.
      expect(h.canvas.selection.hoveredEdge.value, 'edge-2');
      await mouse.removePointer();
      await h.dispose(t);
    });

    testWidgets('buildContextMenuEdges should select the target edge and clear bundled markers', (t) async {
      final h = await _start(t);
      h.canvas.selection.selectEdge('edge-1');
      expect(h.actions().handleEdgeContextMenu('edge-2'), isTrue);
      expect(h.canvas.selection.edge, 'edge-2');
      await h.dispose(t);
    });

    testWidgets('clearNodeSelectionState should clear selected state and bundled markers on every node', (t) async {
      final h = await _start(t);
      // A box selection (Dify's bundled nodes) and the panel's node.
      h.select(['node-1', 'node-2']);
      h.controller.selectNode('node-1');
      h.actions().handleEdgeContextMenu('edge-3');
      expect(h.canvas.selection.nodes, isEmpty);
      await h.dispose(t);
    });
  });
}
