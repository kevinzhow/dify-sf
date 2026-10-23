// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions.spec.ts
//
// The handleNodeAdd / handleNodeChange cases (the paste cases are in ../context_menu). Dify's `nodesMetaDataMap`
// defaults are what the block selector hands over; a missing entry is a null default.
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';

Map<String, Object?> _meta(String type, String title) => {'type': type, 'title': title, 'desc': ''};

void main() {
  group('useNodesInteractions', () {
    testWidgets('returns early for node add/change when metadata for node type is missing', (t) async {
      final h = await Harness.start(t, [node('node-1', x: 10, y: 20, title: 'Code')]);
      final before = h.doc.toJson();
      h.actions()
        ..addNodeAt(const InsertAfter('node-1'), 'code', null)
        ..changeNode('node-1', 'answer', null, 'source');
      expect(h.doc.toJson(), before);
      expect(h.controller.session.pending, isEmpty);
      expect(h.controller.undo.canUndo, isFalse);
      await h.dispose(t);
    });

    testWidgets('uses metadata defaults during add/change/paste and reads collaborative nodes on resize', (t) async {
      final h = await Harness.start(t, [node('meta-node-1', title: 'Meta')]);
      final a = h.actions();
      a.addNodeAt(const InsertAfter('meta-node-1'), 'code', _meta('code', 'Code'));
      final added = h.doc.nodes.values.singleWhere((n) => n.id != 'meta-node-1');
      expect(added.title, 'Code 2', reason: 'numbered after the code node already there');

      a.changeNode('meta-node-1', 'answer', _meta('answer', 'Answer'), 'source');
      expect(h['meta-node-1'], isNull);
      final answer = h.doc.nodes.values.singleWhere((n) => n.type == 'answer');
      expect(answer.title, 'Answer');
      expect(h.doc.edges.values.single.source, answer.id, reason: 'the kept edge leaves the new node');

      h.store
        ..setClipboardData(
          nodes: [difyNodeOf(node('clipboard-node', title: 'Clipboard'))],
          edges: const [],
        )
        ..setMousePosition((pageX: 60, pageY: 80, elementX: 60, elementY: 80));
      await a.pasteNodes();
      expect(h.doc.nodes.values.where((n) => n.title == 'Clipboard'), hasLength(1));
      // dify-sf has no node resize yet (handleNodeResize), so the resize part has nothing to read.
      await h.dispose(t);
    });
  });
}
