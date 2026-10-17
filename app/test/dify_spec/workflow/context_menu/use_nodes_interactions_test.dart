// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Pastes [clipboard] (Dify's JSON of [Node]s) with the pointer at 60, 80; returns the new nodes.
Future<List<Node>> _paste(Harness h, List<Node> clipboard) async {
  final before = h.doc.nodes.keys.toSet();
  h.store
    ..setClipboardData(nodes: [for (final n in clipboard) difyNodeOf(n)], edges: const [])
    ..setMousePosition((pageX: 60, pageY: 80, elementX: 60, elementY: 80));
  await h.actions().pasteNodes();
  return [
    for (final n in h.doc.nodes.values)
      if (!before.contains(n.id)) n,
  ];
}

Map<String, Object?> _data(Node n) => (difyNodeOf(n)['data']! as Map).cast<String, Object?>();

void main() {
  group('useNodesInteractions', () {
    testWidgets('skips clipboard copy when bundled/selected nodes have no metadata', (t) async {
      final h = await Harness.start(t, [
        node('bundled-node', type: 'mystery'),
        node('selected-node', type: 'mystery', x: 100),
      ]);
      h.select(['bundled-node', 'selected-node']);
      h.actions().copyNodes();
      h.select(['selected-node']);
      h.actions().copyNodes();
      expect(h.store.clipboardElements.value, isEmpty);
      await h.dispose(t);
    });

    group('paste title handling', () {
      testWidgets('preserves the original title when the destination canvas has no conflict', (t) async {
        final h = await Harness.start(t, [node('existing-node', title: 'Existing')]);
        final pasted = await _paste(h, [node('clipboard-node', title: 'Clipboard')]);
        expect(pasted.single.title, 'Clipboard');
        expect((pasted.single.x, pasted.single.y), (60, 80), reason: 'top-left at the pointer');
        await h.dispose(t);
      });

      testWidgets('renames pasted nodes only when the destination canvas already uses the title', (t) async {
        final h = await Harness.start(t, [
          node('existing-node', title: 'Clipboard'),
          node('existing-node-2', title: 'Clipboard (1)'),
        ]);
        final pasted = await _paste(h, [node('clipboard-node', title: 'Clipboard')]);
        expect(pasted.single.title, 'Clipboard (2)');
        await h.dispose(t);
      });
    });

    group('container paste target detection', () {
      testWidgets('pastes a copied %s as a top-level node when the source container remains selected', (t) async {
        for (final type in ['iteration', 'loop']) {
          final id = '$type-source';
          final h = await Harness.start(t, [node(id, type: type, x: 20, y: 20)]);
          h.select([id]);
          final pasted = await _paste(h, [node(id, type: type, x: 120, y: 120)]);
          final container = pasted.singleWhere((n) => n.type == type);
          expect(parentIdOf(container), isNull);
          expect((difyNodeOf(container)['zIndex']), 0);
          expect(_data(container)['isInIteration'], isFalse);
          expect(_data(container)['isInLoop'], isFalse);
          final start = pasted.singleWhere((n) => n.type == '$type-start');
          expect(start.id, '${container.id}start');
          expect(parentIdOf(start), container.id);
          expect(_data(container)['start_node_id'], start.id);
          await h.dispose(t);
        }
      });
    });

    group('nested container paste behavior', () {
      testWidgets('should not paste %s into an iteration container', (t) async {
        for (final type in ['end', 'iteration', 'loop', 'datasource', 'knowledge-index']) {
          final h = await Harness.start(t, [node('iteration-container', type: 'iteration', x: 20, y: 20)]);
          h.select(['iteration-container']);
          final pasted = await _paste(h, [node('$type-clipboard-node', type: type, x: 100, y: 100)]);
          expect(pasted, isEmpty, reason: type);
          await h.dispose(t);
        }
      });

      testWidgets('should paste human-input into a %s container', (t) async {
        for (final type in ['iteration', 'loop']) {
          final containerId = '$type-container';
          final h = await Harness.start(t, [node(containerId, type: type, x: 20, y: 20)]);
          h.select([containerId]);
          final pasted = await _paste(h, [node('human', type: 'human-input', x: 100, y: 100)]);
          final human = pasted.single;
          final isIteration = type == 'iteration';
          expect(parentIdOf(human), containerId);
          expect(_data(human)['isInIteration'], isIteration);
          expect(_data(human)['iteration_id'], isIteration ? containerId : null);
          expect(_data(human)['isInLoop'], !isIteration);
          expect(_data(human)['loop_id'], isIteration ? null : containerId);
          expect((human.x, human.y), (40, 60), reason: 'relative to the container');
          await h.dispose(t);
        }
      });
    });
  });
}
