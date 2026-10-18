// dify-spec: web/app/components/workflow/__tests__/workflow-edge-events.spec.tsx
//
// The editor's event wiring on the real canvas (EditorHarness): context menus for nodes and the pane, edge
// selection, Delete through the workflow shortcuts, and the store's showConfirm dialog (WorkflowConfirm). The
// comment overlay case is in comment/workflow_comment_overlays_test.dart.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';
import 'hooks/editor_harness.dart';

const _edges = [Edge(id: 'edge-1', source: 'node-1', sourceHandle: 'source', target: 'node-2', targetHandle: 'target')];

Future<EditorHarness> _start(WidgetTester t) =>
    EditorHarness.start(t, [node('node-1', x: 100, y: 100), node('node-2', x: 500, y: 100)], edges: _edges);

Offset _edgeMiddle(EditorHarness h) {
  final g = h.canvas.graph!;
  final pts = edgeCurve(g['node-1']!.outPortFor('source'), g['node-2']!.inPort);
  return h.screen(pts[pts.length ~/ 2]);
}

void main() {
  setUp(useDifyTestTranslator);

  group('Workflow edge event wiring', () {
    testWidgets('should forward pane, node and edge-change events to workflow handlers when emitted by the canvas', (
      t,
    ) async {
      final h = await _start(t);
      await t.tapAt(h.nodeCenter('node-1'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      expect(h.store.contextMenuTarget.value, const NodeContextMenuTarget('node-1'));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await EditorHarness.settle(t);
      await t.tapAt(const Offset(900, 600), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      expect(h.store.contextMenuTarget.value, const PanelContextMenuTarget());
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await EditorHarness.settle(t);
      await t.tapAt(_edgeMiddle(h), kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      expect(h.canvas.selection.edge, 'edge-1');
      await h.dispose(t);
    });

    testWidgets('should keep edge deletion delegated to workflow shortcuts instead of React Flow defaults', (t) async {
      final h = await _start(t);
      await t.tapAt(_edgeMiddle(h), kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await EditorHarness.settle(t);
      expect(h.doc.edges, isEmpty);
      expect(h.doc.nodes.keys, containsAll(['node-1', 'node-2']));
      // One step, by the workflow's handleEdgeDelete.
      expect(h.controller.undo.past.single.event, HistoryEvent.edgeDelete);
      await h.dispose(t);
    });

    testWidgets('should render confirm description and clear showConfirm when cancelled', (t) async {
      final h = await _start(t);
      var confirmed = 0;
      h.store.setShowConfirm((title: 'Confirm title', desc: 'Confirm description', onConfirm: () => confirmed++));
      await EditorHarness.settle(t);
      expect(find.text('Confirm title'), findsOneWidget);
      expect(find.text('Confirm description'), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await EditorHarness.settle(t);
      expect(find.text('Confirm title'), findsNothing);
      expect(h.store.showConfirm.value, isNull);
      expect(confirmed, 0);
      await h.dispose(t);
    });

    testWidgets('should call showConfirm.onConfirm when confirm is clicked', (t) async {
      final h = await _start(t);
      var confirmed = 0;
      h.store.setShowConfirm((title: 'Confirm title', desc: null, onConfirm: () => confirmed++));
      await EditorHarness.settle(t);
      await t.tap(find.text('common.operation.confirm'));
      await EditorHarness.settle(t);
      expect(confirmed, 1);
      await h.dispose(t);
    });
  });

  group('deleting a container with children (showConfirm in use)', () {
    testWidgets('asks, and deletes the container with its children once confirmed', (t) async {
      final h = await EditorHarness.start(t, [
        node('iter', type: 'iteration', x: 100, y: 100, w: 600, h: 400),
        node('iter-start', type: 'iteration-start', x: 24, y: 68, parent: 'iter'),
        node('child', x: 120, y: 120, parent: 'iter'),
      ]);
      await t.tapAt(h.screen(const Offset(400, 110)), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await EditorHarness.settle(t);
      await t.tap(find.text('common.operation.delete'));
      await EditorHarness.settle(t);
      expect(find.text('workflow.nodes.iteration.deleteTitle'), findsOneWidget);
      expect(h.doc.nodes, hasLength(3));
      await t.tap(find.text('common.operation.confirm'));
      await EditorHarness.settle(t);
      expect(h.doc.nodes, isEmpty);
      expect(find.text('workflow.nodes.iteration.deleteTitle'), findsNothing);
      await h.dispose(t);
    });
  });
}
