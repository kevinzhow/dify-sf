import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart' show reactFlowGraphOf;
import 'package:dify_sf_app/src/workflow_editor/organize/workflow_organize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/context_menu/harness.dart';
import '../support/app_fonts.dart';

/// Start → if-else (case `a`, else) → one code node per branch → end, scattered over the canvas.
List<Node> _branching() => [
  node('start', type: 'start', x: 700, y: 400, w: 244, h: 90),
  node(
    'if',
    type: 'if-else',
    x: 30,
    y: 500,
    w: 244,
    h: 130,
    config: {
      'cases': VList([
        VMap({'case_id': const VString('a')}),
      ]),
    },
  ),
  node('code-else', x: 900, y: 20, w: 244, h: 54),
  node('code-a', x: 300, y: 900, w: 244, h: 54),
  node('end', type: 'end', x: 0, y: 0, w: 244, h: 90),
];

const _branchingEdges = [
  Edge(id: 'e1', source: 'start', target: 'if'),
  Edge(id: 'e2', source: 'if', sourceHandle: 'false', target: 'code-else'),
  Edge(id: 'e3', source: 'if', sourceHandle: 'a', target: 'code-a'),
  Edge(id: 'e4', source: 'code-a', target: 'end'),
  Edge(id: 'e5', source: 'code-else', target: 'end'),
];

Map<String, (int, int)> _positions(Document doc) => {for (final n in doc.nodes.values) n.id: (n.x, n.y)};

WorkflowOrganize _organize(Harness h) => WorkflowOrganize(controller: h.controller, canvas: h.canvas, store: h.store);

/// Where Dify's handleLayout puts every node of [h]'s document, rounded to the document's integers.
Map<String, (int, int)> _expected(Harness h) {
  final g = reactFlowGraphOf(h.doc, sizeOf: (n) => reactFlowSizeOf(h.canvas, n));
  return {
    for (final n in organizeNodes(g.nodes, g.edges))
      n['id']! as String: (
        ((n['position']! as Map)['x'] as num).round(),
        ((n['position']! as Map)['y'] as num).round(),
      ),
  };
}

void main() {
  group('organize on the shared document', () {
    testWidgets('lays the graph out as Dify does, as one undo step that undo and redo replay', (t) async {
      final h = await Harness.start(t, _branching(), edges: _branchingEdges);
      final before = _positions(h.doc);
      final expected = _expected(h);

      _organize(h).handleLayout();
      await Harness.settle(t);

      expect(_positions(h.doc), expected);
      final p = _positions(h.doc);
      // Left to right in DFS layers; the case branch above the else branch (port order), both in one layer.
      expect(p['start']!.$1, 0);
      expect(p['if']!.$1, greaterThan(p['start']!.$1));
      expect(p['code-a']!.$1, p['code-else']!.$1);
      expect(p['code-a']!.$2, lessThan(p['code-else']!.$2));
      expect(p['end']!.$1, greaterThan(p['code-a']!.$1));
      expect(h.controller.undo.past, hasLength(1));
      expect(h.controller.undo.past.single.event, HistoryEvent.layoutOrganize);
      expect(h.canvas.view.scale, 0.7);

      h.controller.undo.undo();
      await Harness.settle(t);
      expect(_positions(h.doc), before);
      h.controller.undo.redo();
      await Harness.settle(t);
      expect(_positions(h.doc), expected);
      expect(h.demo.server.doc.nodes.values.map((n) => (n.id, n.x, n.y)), [
        for (final n in h.doc.nodes.values) (n.id, n.x, n.y),
      ]);
      await h.dispose(t);
    });

    testWidgets('sends only the nodes whose position changed', (t) async {
      final h = await Harness.start(t, _branching(), edges: _branchingEdges);
      final expected = _expected(h);
      // Two nodes already where the layout puts them.
      h.controller
        ..moveNode('start', expected['start']!.$1, expected['start']!.$2)
        ..moveNode('end', expected['end']!.$1, expected['end']!.$2);
      await Harness.settle(t);

      _organize(h).handleLayout();
      await Harness.settle(t);
      final moved = {for (final op in h.controller.undo.past.single.inverse) (op as MoveNode).node};
      expect(moved, {'if', 'code-a', 'code-else'});

      // Organizing an organized workflow changes nothing: no ops, no history step.
      final seq = h.controller.status.lastSeq;
      _organize(h).handleLayout();
      await Harness.settle(t);
      expect(h.controller.undo.past, hasLength(1));
      expect(h.controller.status.lastSeq, seq);
      await h.dispose(t);
    });

    testWidgets('lays out container children relative to the container and grows it', (t) async {
      final h = await Harness.start(
        t,
        [
          node('start', type: 'start', x: 500, y: 300, w: 244, h: 90),
          node('iter', type: 'iteration', x: 0, y: 0, w: 300, h: 150),
          node(
            'iterstart',
            type: 'iteration-start',
            rfType: 'custom-iteration-start',
            parent: 'iter',
            x: 200,
            y: 90,
            w: 44,
            h: 48,
          ),
          node('inner-a', parent: 'iter', x: 5, y: 5, w: 244, h: 54),
          node('inner-b', parent: 'iter', x: 10, y: 100, w: 244, h: 54),
        ],
        edges: const [
          Edge(id: 'e1', source: 'start', target: 'iter'),
          Edge(id: 'e2', source: 'iterstart', target: 'inner-a'),
          Edge(id: 'e3', source: 'inner-a', target: 'inner-b'),
        ],
      );
      final expected = _expected(h);
      final doc = h.doc;

      _organize(h).handleLayout();
      await Harness.settle(t);

      expect(_positions(h.doc), expected);
      // getLayoutForChildNodes: the start marker 40 from the interior's left, everything inside the 60 px padding;
      // the positions are the container's own coordinates, as the document keeps them.
      final p = _positions(h.doc);
      expect(p['iterstart'], (60, 60));
      expect(p['inner-a']!.$1, greaterThan(60 + 44));
      expect(p['inner-b']!.$1, greaterThan(p['inner-a']!.$1 + 244));
      // The iteration grew to hold its children plus padding, in React Flow's size and Dify's data.
      final iter = h['iter']!;
      final width = p['inner-b']!.$1 + 244 + 60;
      expect(ConfigTree.get(iter.config, ['_dify_node', 'width']), VInt(width));
      expect(ConfigTree.get(iter.config, ['width']), VInt(width));
      expect(h.graph['iter']!.rect.width, width - 2);
      expect(h.controller.undo.past, hasLength(1));

      h.controller.undo.undo();
      await Harness.settle(t);
      expect(_positions(h.doc), _positions(doc));
      expect(ConfigTree.get(h['iter']!.config, ['_dify_node', 'width']), const VInt(300));
      await h.dispose(t);
    });

    testWidgets('does nothing while read-only', (t) async {
      final h = await Harness.start(t, _branching(), edges: _branchingEdges);
      final before = _positions(h.doc);
      for (final readOnly in [
        () => h.store.setCanvasReadOnly(true),
        () => h.store
          ..setCanvasReadOnly(false)
          ..workflowRunningData.value = {
            'result': {'status': 'running'},
          },
      ]) {
        readOnly();
        _organize(h).handleLayout();
        await Harness.settle(t);
        expect(_positions(h.doc), before);
        expect(h.controller.undo.past, isEmpty);
      }
      await h.dispose(t);
    });

    testWidgets('two clients: organize is last-writer-wins and both converge', (t) async {
      final h = await Harness.start(t, _branching(), edges: _branchingEdges);
      final bo = CollabSession(
        clientId: 'bo-1',
        transport: FakeTransport(h.demo.server, network: FakeNetwork(random: Random(5))),
        store: MemoryStore(),
        journaled: false,
        tickInterval: const Duration(milliseconds: 100),
      );
      await bo.start();
      final other = EditorController(session: bo, docId: 'demo', journaled: false);
      for (var i = 0; i < 30 && !other.ready; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final expected = _expected(h);

      // Bo drags a node while this client organizes: neither is rejected, and both end up with the same layout.
      _organize(h).handleLayout();
      other.moveNode('code-a', 999, 999);
      for (var i = 0; i < 4; i++) {
        await Harness.settle(t);
      }
      expect(_positions(other.doc), _positions(h.doc));
      expect(_positions(h.doc)['code-a'], anyOf(expected['code-a'], (999, 999)));
      expect(h.controller.notices, isEmpty);
      expect(other.notices, isEmpty);

      // A later organize wins over the earlier drag on both clients.
      other.moveNode('code-a', 5, 5);
      await Harness.settle(t);
      _organize(h).handleLayout();
      for (var i = 0; i < 4; i++) {
        await Harness.settle(t);
      }
      expect(_positions(h.doc), expected);
      expect(_positions(other.doc), expected);

      other.dispose();
      await bo.stop();
      await h.dispose(t);
    });
  });

  group('organize in the editor', () {
    testWidgets('the control bar button and Mod+O organize the workflow as one undo step each', (t) async {
      await useAppFonts();
      t.view.physicalSize = const Size(1600, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final demo = DemoBackend(withBo: false);
      await t.pumpWidget(
        MaterialApp(
          home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
      final before = _positions(c.doc);

      await t.tap(find.bySemanticsLabel(DifyI18n.tr('workflow', 'panel.organizeBlocks')).first);
      await t.pump(const Duration(milliseconds: 300));
      final organized = _positions(c.doc);
      expect(organized, isNot(before));
      expect(c.undo.past.map((s) => s.event), [HistoryEvent.layoutOrganize]);

      c.undo.undo();
      await t.pump(const Duration(milliseconds: 300));
      expect(_positions(c.doc), before);

      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyO);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump(const Duration(milliseconds: 300));
      expect(_positions(c.doc), organized);
      expect(c.undo.past.map((s) => s.event), [HistoryEvent.layoutOrganize]);

      await t.pumpWidget(const SizedBox());
      await demo.dispose();
      await t.pump(const Duration(seconds: 20));
    });
  });
}
