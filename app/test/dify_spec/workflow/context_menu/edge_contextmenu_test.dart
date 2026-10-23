// dify-spec: web/app/components/workflow/__tests__/edge-contextmenu.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _edges = [
  Edge(id: 'e1', source: 'n1', sourceHandle: 'branch-a', target: 'n2', targetHandle: 'target'),
  Edge(id: 'e2', source: 'n1', sourceHandle: 'branch-b', target: 'n3', targetHandle: 'target'),
];

Future<Harness> _start(WidgetTester t) async {
  final h = await Harness.start(t, [
    node('n1', y: 200),
    node('n2', x: 300),
    node('n3', x: 300, y: 400),
  ], edges: _edges);
  await t.pumpWidget(h.app());
  return h;
}

void main() {
  setUp(() => DifyI18n.current = NsKeyTranslator());

  group('EdgeContextmenu', () {
    testWidgets('should not render when edge context menu target is absent', (t) async {
      final h = await _start(t);
      expect(h.menuOpen, isFalse);
      await h.dispose(t);
    });

    testWidgets('should delete the menu edge and close the menu when another edge is selected', (t) async {
      final h = await _start(t);
      await h.rightClick(t, h.edgePoint('e2'));
      h.canvas.selection.selectEdge('e1');
      await h.tapText(t, 'common.operation.delete');
      expect(h.doc.edges.keys, ['e1']);
      expect(h.canvas.selection.edge, 'e1');
      expect(h.store.contextMenuTarget.value, isNull);
      expect(h.menuOpen, isFalse);
      expect(h.controller.undo.past.last.event, HistoryEvent.edgeDelete);
      await h.dispose(t);
    });

    testWidgets('should not render the menu when the referenced edge no longer exists', (t) async {
      final h = await _start(t);
      await h.rightClick(t, h.edgePoint('e1'));
      expect(h.menuOpen, isTrue);
      h.controller.deleteEdge('e1');
      await Harness.settle(t);
      expect(h.menuOpen, isFalse);
      await h.dispose(t);
    });

    testWidgets('should open the edge menu for the right-clicked edge', (t) async {
      final h = await _start(t);
      await h.rightClick(t, h.edgePoint('e2'));
      expect(h.menuOpen, isTrue);
      expect(find.text('common.operation.delete'), findsOneWidget);
      expect(h.store.contextMenuTarget.value, const EdgeContextMenuTarget('e2'));
      await h.dispose(t);
    });

    testWidgets('should delete the right-clicked edge and close the menu when delete is clicked', (t) async {
      final h = await _start(t);
      await h.rightClick(t, h.edgePoint('e2'));
      await h.tapText(t, 'common.operation.delete');
      expect(h.menuOpen, isFalse);
      expect(h.doc.edges.keys, ['e1']);
      expect(h.controller.undo.past.last.event, HistoryEvent.edgeDelete);
      await h.dispose(t);
    });

    testWidgets('should delete the right-clicked edge with %s after switching from a selected node', (t) async {
      for (final key in [LogicalKeyboardKey.delete, LogicalKeyboardKey.backspace]) {
        final h = await _start(t);
        h.select(['n1']);
        h.controller.selectNode('n1');
        await h.rightClick(t, h.edgePoint('e2'));
        expect(h.menuOpen, isTrue);
        await h.key(t, key);
        expect(h.menuOpen, isFalse);
        expect(h.doc.edges.keys, ['e1']);
        expect(h.doc.nodes.keys.toSet(), {'n1', 'n2', 'n3'});
        expect(h.canvas.selection.nodes, isEmpty);
        expect(h.controller.selectedNodeId, isNull);
        await h.dispose(t);
      }
    });

    testWidgets('should keep bundled multi-selection nodes intact when delete runs after right-clicking an edge', (
      t,
    ) async {
      final h = await _start(t);
      h.select(['n2', 'n3']);
      await h.rightClick(t, h.edgePoint('e1', at: 0.2));
      expect(h.menuOpen, isTrue);
      await h.key(t, LogicalKeyboardKey.delete);
      expect(h.menuOpen, isFalse);
      expect(h.doc.edges.keys, ['e2']);
      expect(h.doc.nodes, hasLength(3));
      expect(h.canvas.selection.nodes, isEmpty);
      await h.dispose(t);
    });

    testWidgets('should retarget the menu and selected edge when right-clicking a different edge', (t) async {
      final h = await _start(t);
      await h.rightClick(t, h.edgePoint('e1'));
      expect(h.menuOpen, isTrue);
      await h.rightClick(t, h.edgePoint('e2'));
      expect(find.text('common.operation.delete'), findsOneWidget);
      expect(h.canvas.selection.edge, 'e2');
      expect(h.store.contextMenuTarget.value, const EdgeContextMenuTarget('e2'));
      await h.dispose(t);
    });

    testWidgets('should hide the menu when the target edge disappears after opening it', (t) async {
      final h = await _start(t);
      await h.rightClick(t, h.edgePoint('e1'));
      expect(h.menuOpen, isTrue);
      h.opened.session.edit(const RemoveEdge('e1'));
      await Harness.settle(t);
      expect(h.menuOpen, isFalse);
      await h.dispose(t);
    });
  });
}
