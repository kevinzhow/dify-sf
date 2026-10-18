// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions.spec.ts
//
// The drag, connect and selection handlers on the real canvas (EditorHarness) and WorkflowActions; history back /
// forward are OperatorActions over the editor's UndoManager, whose steps are document ops (what collaborators get).
// The other cases are under context_menu/, node_insertion/ and comment/.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart' show Harness;
import '../operator/operator_harness.dart';
import 'editor_harness.dart';

void main() {
  group('useNodesInteractions', () {
    testWidgets('persists node drags only when the node position actually changes', (t) async {
      final h = await EditorHarness.start(t, [node('node-1', x: 10, y: 20)]);
      // A click (no movement): nothing is written.
      await t.tapAt(h.nodeCenter('node-1'), kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      expect(h.controller.undo.past, isEmpty);
      expect((h.doc.nodes['node-1']!.x, h.doc.nodes['node-1']!.y), (10, 20));
      // A drag: one NodeDragStop step for the node.
      await h.drag(t, h.nodeCenter('node-1'), h.nodeCenter('node-1') + const Offset(110, 60));
      await EditorHarness.settle(t);
      expect((h.doc.nodes['node-1']!.x, h.doc.nodes['node-1']!.y), (120, 80));
      expect([for (final s in h.controller.undo.past) (s.event, s.nodeId)], [(HistoryEvent.nodeDragStop, 'node-1')]);
      await h.dispose(t);
    });

    test('restores history snapshots on undo and clears the edge menu', () {
      final store = WorkflowStore()..setContextMenuTarget(const EdgeContextMenuTarget('edge-1'));
      addTearDown(store.dispose);
      final history = TestHistory(past: 1);
      final canvas = TestCanvas();
      addTearDown(canvas.dispose);
      OperatorActions(canvas, store, history: history).historyBack();
      expect(history.past, isEmpty);
      expect(history.future, hasLength(1));
      expect(store.contextMenuTarget.value, isNull);
    });

    test('skips undo and redo when the workflow is read-only', () {
      final store = WorkflowStore()
        ..setWorkflowRunningData({
          'result': {'status': 'running'},
        });
      addTearDown(store.dispose);
      final history = TestHistory(past: 1, future: 1);
      final canvas = TestCanvas();
      addTearDown(canvas.dispose);
      OperatorActions(canvas, store, history: history)
        ..historyBack()
        ..historyForward();
      expect((history.past.length, history.future.length), (1, 1));
    });

    testWidgets('broadcasts history undo/redo actions to collaborators when connected', (t) async {
      final h = await Harness.start(t, [node('node-1')]);
      h.controller.undo.begin(HistoryEvent.nodeDragStop, nodeId: 'node-1');
      h.controller.moveNode('node-1', 200, 100);
      h.controller.undo.end();
      await Harness.settle(t);
      expect(h.demo.server.doc.nodes['node-1']!.x, 200);
      // Undo and redo are ops the server receives (and passes on to everyone).
      final before = h.demo.server.log.length;
      h.controller.undo.undo();
      await Harness.settle(t);
      expect(h.demo.server.doc.nodes['node-1']!.x, 0);
      h.controller.undo.redo();
      await Harness.settle(t);
      expect(h.demo.server.doc.nodes['node-1']!.x, 200);
      expect(h.demo.server.log.length, before + 2);
      await h.dispose(t);
    });

    testWidgets('stores connecting payload from collaborative nodes when connect starts', (t) async {
      final h = await EditorHarness.start(t, [node('node-1', x: 100, y: 100), node('node-2', x: 500, y: 100)]);
      final from = h.outPort('node-1');
      final g = await t.startGesture(from, kind: PointerDeviceKind.mouse);
      await g.moveTo(from + const Offset(40, 0));
      await t.pump();
      final p = h.store.connectingNodePayload.value;
      expect((p?.nodeId, p?.nodeType, p?.handleType, p?.handleId), ('node-1', 'code', 'source', 'source'));
      await g.moveTo(h.nodeCenter('node-2'));
      await g.up();
      await EditorHarness.settle(t);
      // handleNodeConnectEnd clears it.
      expect(h.store.connectingNodePayload.value, isNull);
      expect(h.doc.edges.values.single.target, 'node-2');
      await h.dispose(t);
    });

    testWidgets('cancels selection state with collaborative nodes snapshot', (t) async {
      final h = await Harness.start(t, [node('selected-node')]);
      h.actions().selectNode('selected-node');
      expect(h.canvas.selection.nodes, isNotEmpty);
      h.actions().cancelNodesSelected();
      expect(h.canvas.selection.nodes, isEmpty);
      expect(h.controller.selectedNodeId, isNull);
      await h.dispose(t);
    });

    testWidgets('keeps ReactFlow and node data selection in sync when selecting another node', (t) async {
      final h = await Harness.start(t, [
        node('knowledge-retrieval-node', type: 'knowledge-retrieval'),
        node('answer-node', type: 'answer', x: 100),
      ]);
      h.actions().selectNode('knowledge-retrieval-node');
      h.actions().selectNode('answer-node');
      // The canvas selection and the panel's node agree.
      expect([for (final s in h.canvas.selection.nodes) h.graph.slots[s]!.id], ['answer-node']);
      expect(h.controller.selectedNodeId, 'answer-node');
      await h.dispose(t);
    });

    testWidgets('reads collaborative nodes when dragging/selecting/connecting nodes', (t) async {
      final h = await EditorHarness.start(t, [
        node('drag-node-1', x: 100, y: 100),
        node('drag-node-2', x: 500, y: 300),
      ]);
      await h.drag(t, h.nodeCenter('drag-node-1'), h.nodeCenter('drag-node-1') + const Offset(0, 40));
      await EditorHarness.settle(t);
      expect(h.doc.nodes['drag-node-1']!.y, 140);
      await t.tapAt(h.nodeCenter('drag-node-2'), kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      expect(h.controller.selectedNodeId, 'drag-node-2');
      await h.drag(t, h.outPort('drag-node-1'), h.nodeCenter('drag-node-2'));
      await EditorHarness.settle(t);
      expect(h.doc.edges.values.single, isA<Edge>().having((e) => e.target, 'target', 'drag-node-2'));
      await h.dispose(t);
    });
  });
}
