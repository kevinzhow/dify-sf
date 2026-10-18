// The canvas's connections and drags in the Dify workflow editor: useWorkflow().isValidConnection with
// handleNodeConnect's checks, and handleNodeDrag's helplines (use-helpline.ts) with the snap onto them.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/hooks/use_helpline.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';

void main() {
  group('connecting on the canvas', () {
    Future<int> connect(WidgetTester t, EditorHarness h, String from, String to) async {
      final before = h.doc.edges.length;
      await h.drag(t, h.outPort(from), h.nodeCenter(to));
      await EditorHarness.settle(t);
      return h.doc.edges.length - before;
    }

    testWidgets('connects two top-level nodes', (t) async {
      final h = await EditorHarness.start(t, [node('a', x: 100, y: 100), node('b', x: 500, y: 300)]);
      expect(await connect(t, h, 'a', 'b'), 1);
      expect(h.doc.edges.values.single.target, 'b');
      await h.dispose(t);
    });

    testWidgets('does not connect a node that would close a cycle', (t) async {
      final h = await EditorHarness.start(
        t,
        [node('a', x: 100, y: 100), node('b', x: 500, y: 300)],
        edges: const [Edge(id: 'ab', source: 'a', sourceHandle: 'source', target: 'b', targetHandle: 'target')],
      );
      expect(await connect(t, h, 'b', 'a'), 0);
      await h.dispose(t);
    });

    testWidgets('does not connect the same handles twice', (t) async {
      final h = await EditorHarness.start(
        t,
        [node('a', x: 100, y: 100), node('b', x: 500, y: 300)],
        edges: const [Edge(id: 'ab', source: 'a', sourceHandle: 'source', target: 'b', targetHandle: 'target')],
      );
      expect(await connect(t, h, 'a', 'b'), 0);
      await h.dispose(t);
    });

    testWidgets('does not connect into a Start node or across containers', (t) async {
      final h = await EditorHarness.start(t, [
        node('a', x: 100, y: 100),
        node('start', type: 'start', x: 500, y: 100),
        node('loop', type: 'loop', x: 100, y: 300, w: 600, h: 300),
        node('inner', x: 120, y: 120, parent: 'loop'),
      ]);
      expect(await connect(t, h, 'a', 'start'), 0);
      expect(await connect(t, h, 'a', 'inner'), 0);
      await h.dispose(t);
    });
  });

  group('dragging on the canvas', () {
    testWidgets('shows a helpline while the node is within 5 px of another, snaps onto it, and clears it on drop', (
      t,
    ) async {
      final h = await EditorHarness.start(t, [node('a', x: 100, y: 100), node('b', x: 500, y: 300)]);
      final from = h.nodeCenter('b');
      final g = await t.startGesture(from, kind: PointerDeviceKind.mouse);
      // 197 px up: b's top would be at y = 103, 3 px below a's.
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(from + Offset(0, -197 * i / 8));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(h.store.helpLineHorizontal.value, isNotNull);
      expect(h.store.helpLineHorizontal.value!.top, 100);
      expect(find.byKey(const ValueKey('help-line-horizontal')), findsOneWidget);
      expect(h.canvas.graph!['b']!.y, 100);
      await g.up();
      await EditorHarness.settle(t);
      expect(h.doc.nodes['b']!.y, 100);
      expect(h.store.helpLineHorizontal.value, isNull);
      expect(find.byType(HelpLine), findsOneWidget);
      expect(find.byKey(const ValueKey('help-line-horizontal')), findsNothing);
      await h.dispose(t);
    });

    testWidgets('a node dragged away from the alignment leaves it', (t) async {
      final h = await EditorHarness.start(t, [node('a', x: 100, y: 100), node('b', x: 500, y: 300)]);
      final from = h.nodeCenter('b');
      await h.drag(t, from, from + const Offset(0, -150));
      await EditorHarness.settle(t);
      expect(h.doc.nodes['b']!.y, 150);
      expect(h.store.helpLineHorizontal.value, isNull);
      await h.dispose(t);
    });
  });
}
