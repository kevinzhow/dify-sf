// dify-spec: web/app/components/workflow/hooks/__tests__/use-edges-interactions.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _edges = [
  Edge(id: 'e1', source: 'n1', sourceHandle: 'branch-a', target: 'n2', targetHandle: 'target'),
  Edge(id: 'e2', source: 'n1', sourceHandle: 'branch-b', target: 'n2', targetHandle: 'target'),
];

Future<Harness> _start(WidgetTester t, {bool readOnly = false}) async {
  final h = await Harness.start(t, [node('n1'), node('n2', x: 300)], edges: _edges);
  h.store.setCanvasReadOnly(readOnly);
  return h;
}

void main() {
  group('useEdgesInteractions', () {
    testWidgets('handleEdgeContextMenu should select the clicked edge and set the edge context menu target', (t) async {
      final h = await _start(t);
      h.select(['n1']);
      expect(h.actions().handleEdgeContextMenu('e2'), isTrue);
      expect(h.canvas.selection.edge, 'e2');
      expect(h.canvas.selection.nodes, isEmpty);
      expect(h.store.contextMenuTarget.value, const EdgeContextMenuTarget('e2'));
      await h.dispose(t);
    });

    testWidgets('handleEdgeDelete should remove selected edge and trigger sync + history', (t) async {
      final h = await _start(t);
      h.canvas.selection.selectEdge('e1');
      h.actions().deleteSelection();
      expect(h.doc.edges.keys, ['e2']);
      expect(h.controller.undo.past.last.event, HistoryEvent.edgeDelete);
      await h.dispose(t);
    });

    testWidgets('handleEdgeDelete should do nothing when no edge is selected', (t) async {
      final h = await _start(t);
      h.actions().deleteSelection();
      expect(h.doc.edges, hasLength(2));
      expect(h.controller.undo.past, isEmpty);
      await h.dispose(t);
    });

    testWidgets('handleEdgeDeleteById should remove the requested edge even when another edge is selected', (t) async {
      final h = await _start(t);
      h.canvas.selection.selectEdge('e1');
      h.store.setContextMenuTarget(const EdgeContextMenuTarget('e2'));
      h.actions().deleteEdge('e2');
      expect(h.doc.edges.keys, ['e1']);
      expect(h.canvas.selection.edge, 'e1');
      expect(h.store.contextMenuTarget.value, isNull);
      await h.dispose(t);
    });

    testWidgets('handleEdgeDeleteById should ignore unknown edge ids', (t) async {
      final h = await _start(t);
      h.actions().deleteEdge('missing');
      expect(h.doc.edges, hasLength(2));
      expect(h.controller.undo.past, isEmpty);
      await h.dispose(t);
    });

    testWidgets('handleEdgeDeleteByDeleteBranch should remove edges for the given branch', (t) async {
      final h = await _start(t);
      h.actions().deleteBranch('n1', 'branch-a');
      expect(h.doc.edges.keys, ['e2']);
      expect(h.controller.undo.past.single.event, HistoryEvent.edgeDeleteByDeleteBranch);
      await h.dispose(t);
    });

    group('read-only mode', () {
      testWidgets('handleEdgeDelete should do nothing', (t) async {
        final h = await _start(t, readOnly: true);
        h.canvas.selection.selectEdge('e1');
        h.actions().deleteSelection();
        expect(h.doc.edges, hasLength(2));
        await h.dispose(t);
      });

      testWidgets('handleEdgeDeleteById should do nothing', (t) async {
        final h = await _start(t, readOnly: true);
        h.actions().deleteEdge('e1');
        expect(h.doc.edges, hasLength(2));
        await h.dispose(t);
      });

      testWidgets('handleEdgeContextMenu should do nothing', (t) async {
        final h = await _start(t, readOnly: true);
        expect(h.actions().handleEdgeContextMenu('e1'), isFalse);
        expect(h.canvas.selection.edge, isNull);
        expect(h.store.contextMenuTarget.value, isNull);
        await h.dispose(t);
      });

      testWidgets('handleEdgeDeleteByDeleteBranch should do nothing', (t) async {
        final h = await _start(t, readOnly: true);
        h.actions().deleteBranch('n1', 'branch-a');
        expect(h.doc.edges, hasLength(2));
        await h.dispose(t);
      });
    });
  });
}
