// handleNodeAdd / handleNodeChange (hooks/use-nodes-interactions.ts): the pure functions over React Flow's JSON, their
// application to the collaborative document as one undo step, and the node panel's Next step "+".
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/context_menu/harness.dart' as h;
import 'support/app_fonts.dart';

typedef Json = Map<String, Object?>;

Json _n(
  String id,
  String type, {
  num x = 0,
  num y = 0,
  num w = 240,
  num h = 50,
  String? parent,
  Json data = const {},
}) => {
  'id': id,
  'type': 'custom',
  'position': {'x': x, 'y': y},
  'width': w,
  'height': h,
  'parentId': ?parent,
  'data': {'type': type, 'title': type, 'desc': '', ...data},
};

Json _e(String source, String target, {String sh = 'source', String th = 'target'}) => {
  'id': '$source-$sh-$target-$th',
  'type': 'custom',
  'source': source,
  'sourceHandle': sh,
  'target': target,
  'targetHandle': th,
  'data': <String, Object?>{},
};

Json _defaults(String type, [String? title]) => {'type': type, 'title': title ?? type, 'desc': ''};

Json _data(Json n) => (n['data']! as Map).cast<String, Object?>();
Object? _pos(Json n) => n['position'];

void main() {
  group('handleNodeAdd', () {
    test('after a node without outgoers: to its right, connected from the handle, numbered, selected', () {
      final nodes = [
        _n('a', 'code', x: 100, y: 50, w: 200),
        _n('b', 'llm', x: 900),
      ];
      final c = handleNodeAdd(
        nodes,
        const [],
        nodeType: 'code',
        defaultValue: _defaults('code', 'Code'),
        prevNodeId: 'a',
        prevNodeSourceHandle: 'source',
        id: 'new',
      )!;
      expect(c.event, HistoryEvent.nodeAdd);
      expect(c.nodeId, 'new');
      expect(c.selectNodeId, 'new');
      final node = c.newNode!;
      expect(_pos(node), {'x': 100 + 200 + xOffset, 'y': 50});
      expect(_data(node)['title'], 'Code 2');
      expect(node.containsKey('parentId'), isFalse);
      expect(c.addEdges.single, containsPair('id', 'a-source-new-target'));
      expect(c.addEdges.single['sourceHandle'], 'source');
      expect(c.addEdges.single['targetHandle'], 'target');
      expect(c.addEdges.single['zIndex'], 0);
      expect(c.moveNodes, isEmpty);
      expect(c.removeEdges, isEmpty);
    });

    test('after a node with outgoers: below the lowest one', () {
      final nodes = [
        _n('a', 'start'),
        _n('b', 'llm', x: 300, y: 0, h: 80),
        _n('c', 'llm', x: 320, y: 200, h: 60),
      ];
      final c = handleNodeAdd(
        nodes,
        [_e('a', 'c'), _e('a', 'b', sh: 'other')],
        nodeType: 'code',
        defaultValue: _defaults('code'),
        prevNodeId: 'a',
        prevNodeSourceHandle: 'source',
        id: 'new',
      )!;
      expect(_pos(c.newNode!), {'x': 320, 'y': 200 + 60 + yOffset});
    });

    test('inside an iteration: the new node and its edge are nested', () {
      final nodes = [
        _n('it', 'iteration', w: 600, h: 300),
        _n('child', 'code', x: 30, y: 70, parent: 'it', data: {'isInIteration': true, 'iteration_id': 'it'}),
      ];
      final c = handleNodeAdd(
        nodes,
        const [],
        nodeType: 'template-transform',
        defaultValue: _defaults('template-transform'),
        prevNodeId: 'child',
        prevNodeSourceHandle: 'source',
        id: 'new',
      )!;
      final node = c.newNode!;
      expect(node['parentId'], 'it');
      expect(node['zIndex'], 1001);
      expect(_data(node), containsPair('isInIteration', true));
      expect(_data(node), containsPair('isInLoop', false));
      expect(_data(node), containsPair('iteration_id', 'it'));
      final edge = c.addEdges.single;
      expect(edge['zIndex'], 1001);
      expect(edge['data'], containsPair('isInIteration', true));
      expect(edge['data'], containsPair('iteration_id', 'it'));
    });

    test('a container comes with its start node', () {
      final c = handleNodeAdd(
        [_n('a', 'start')],
        const [],
        nodeType: 'loop',
        defaultValue: _defaults('loop'),
        prevNodeId: 'a',
        prevNodeSourceHandle: 'source',
        id: 'L',
      )!;
      expect([for (final n in c.addNodes) n['id']], ['L', 'Lstart']);
      expect(_data(c.newNode!)['start_node_id'], 'Lstart');
      expect(c.addNodes.last['parentId'], 'L');
    });

    test('a data source takes no incoming edge', () {
      final c = handleNodeAdd(
        [_n('a', 'start')],
        const [],
        nodeType: 'datasource',
        defaultValue: _defaults('datasource'),
        prevNodeId: 'a',
        prevNodeSourceHandle: 'source',
        id: 'new',
      )!;
      expect(c.addEdges, isEmpty);
    });

    test('before a node: at its place, it and its downstream move right; a container starts with it', () {
      final nodes = [
        _n('it', 'iteration', data: {'start_node_id': 'b'}),
        _n('b', 'code', x: 100, y: 10),
        _n('c', 'code', x: 400, y: 10),
        _n('d', 'code', x: 900, y: 500),
      ];
      final c = handleNodeAdd(
        nodes,
        [_e('b', 'c')],
        nodeType: 'llm',
        defaultValue: _defaults('llm'),
        sourceHandle: 'source',
        nextNodeId: 'b',
        nextNodeTargetHandle: 'target',
        id: 'new',
      )!;
      expect(_pos(c.newNode!), {'x': 100, 'y': 10});
      expect(c.moveNodes, {'b': (x: 100 + nodeWidthXOffset, y: 10.0), 'c': (x: 400 + nodeWidthXOffset, y: 10.0)});
      expect(c.addEdges.single['id'], 'new-source-b-target');
      expect(c.updateData, {
        'it': {'start_node_id': 'new', 'startNodeType': 'llm'},
      });
    });

    test('before a node, a branching node or a loop end takes no outgoing edge', () {
      for (final type in ['if-else', 'question-classifier', 'human-input', 'loop-end']) {
        final c = handleNodeAdd(
          [_n('b', 'code')],
          const [],
          nodeType: type,
          defaultValue: _defaults(type),
          nextNodeId: 'b',
          nextNodeTargetHandle: 'target',
          id: 'new',
        )!;
        expect(c.addEdges, isEmpty, reason: type);
      }
    });

    test('between two nodes: the edge is replaced by two, the downstream moves right', () {
      final nodes = [
        _n('a', 'start'),
        _n('b', 'code', x: 300),
        _n('c', 'end', x: 600),
      ];
      final c = handleNodeAdd(
        nodes,
        [_e('a', 'b'), _e('b', 'c')],
        nodeType: 'llm',
        defaultValue: _defaults('llm'),
        prevNodeId: 'a',
        prevNodeSourceHandle: 'source',
        nextNodeId: 'b',
        nextNodeTargetHandle: 'target',
        id: 'new',
      )!;
      expect(_pos(c.newNode!), {'x': 300, 'y': 0});
      expect(c.removeEdges, ['a-source-b-target']);
      expect([for (final e in c.addEdges) e['id']], ['a-source-new-target', 'new-source-b-target']);
      expect(c.moveNodes.keys, ['b', 'c']);
    });

    test('nothing without the block\'s defaults or the nodes to insert at', () {
      expect(
        handleNodeAdd([_n('a', 'start')], const [], nodeType: 'code', defaultValue: null, prevNodeId: 'a'),
        isNull,
      );
      expect(handleNodeAdd(const [], const [], nodeType: 'code', defaultValue: _defaults('code')), isNull);
      expect(
        handleNodeAdd(const [], const [], nodeType: 'code', defaultValue: _defaults('code'), prevNodeId: 'x'),
        isNull,
      );
    });
  });

  group('handleNodeChange', () {
    final nodes = [
      _n('a', 'start'),
      _n('b', 'code', x: 300, y: 40, data: {'selected': true}),
      _n('c', 'end', x: 600),
      _n('d', 'end', x: 600, y: 200),
    ];
    final edges = [_e('a', 'b'), _e('b', 'c'), _e('b', 'd', sh: 'fail-branch')];

    test('a new node at the old one\'s place, its incoming and kept outgoing edges re-pointed', () {
      final c = handleNodeChange(
        nodes,
        edges,
        currentNodeId: 'b',
        nodeType: 'llm',
        sourceHandle: 'source',
        defaultValue: _defaults('llm', 'LLM'),
        id: 'new',
      )!;
      expect(c.event, HistoryEvent.nodeChange);
      expect(c.nodeId, 'b');
      expect(c.removeNodes, ['b']);
      expect(c.removeEdges, ['a-source-b-target', 'b-source-c-target', 'b-fail-branch-d-target']);
      final node = c.newNode!;
      expect(node['id'], 'new');
      expect(_pos(node), {'x': 300, 'y': 40});
      expect(_data(node)['title'], 'LLM');
      expect(c.selectNodeId, 'new', reason: 'the replaced node was selected');
      expect([for (final e in c.addEdges) e['id']], ['a-source-new-target', 'new-source-c-target']);
    });

    test('a branching node keeps the outgoing edges from its first branch', () {
      final c = handleNodeChange(
        nodes,
        edges,
        currentNodeId: 'b',
        nodeType: 'if-else',
        sourceHandle: 'source',
        defaultValue: blockDefaults('if-else'),
        id: 'new',
      )!;
      expect([for (final e in c.addEdges) e['id']], ['a-source-new-target', 'new-true-c-target']);
    });

    test('without edges from the given handle, the ones from source are kept', () {
      final c = handleNodeChange(
        nodes,
        edges,
        currentNodeId: 'b',
        nodeType: 'llm',
        sourceHandle: 'missing',
        defaultValue: _defaults('llm'),
        id: 'new',
      )!;
      expect(c.addEdges.map((e) => e['target']), ['new', 'c']);
    });

    test('an unselected node\'s replacement leaves nothing selected', () {
      final c = handleNodeChange(
        nodes,
        edges,
        currentNodeId: 'c',
        nodeType: 'answer',
        sourceHandle: 'source',
        defaultValue: _defaults('answer'),
        id: 'new',
      )!;
      expect(c.selectNodeId, isNull);
    });
  });

  group('on the document', () {
    Future<h.Harness> start(WidgetTester t) => h.Harness.start(
      t,
      [
        h.node('a', type: 'start', x: 0, y: 0, w: 240, h: 90),
        h.node('b', type: 'code', x: 300, y: 0, w: 240, h: 90),
        h.node('c', type: 'end', x: 600, y: 0, w: 240, h: 90),
      ],
      edges: const [
        Edge(id: 'e1', source: 'a', target: 'b'),
        Edge(id: 'e2', source: 'b', target: 'c'),
      ],
    );

    testWidgets('inserting on an edge is one undo step', (t) async {
      final s = await start(t);
      final a = s.actions();
      a.addNodeAt(const InsertOnEdge('e1'), 'llm', _defaults('llm', 'LLM'));
      final added = s.doc.nodes.values.singleWhere((n) => n.type == 'llm');
      expect((added.x, added.y), (300, 0));
      expect((s['b']!.x, s['c']!.x), (600, 900));
      expect(s.doc.edges.containsKey('e1'), isFalse);
      expect(
        {for (final e in s.doc.edges.values) (e.source, e.sourceHandle, e.target, e.targetHandle)},
        // Dify's handle names on the new edges; dify-sf's own `out` / `in` on the edge that stays.
        {('a', 'source', added.id, 'target'), (added.id, 'source', 'b', 'target'), ('b', 'out', 'c', 'in')},
      );
      expect(s.controller.selectedNodeId, added.id);
      expect(s.controller.undo.past.single.event, HistoryEvent.nodeAdd);
      expect(s.controller.undo.past.single.nodeTitle, 'LLM');

      s.controller.undo.undo();
      expect(s.doc.nodes.keys, unorderedEquals(['a', 'b', 'c']));
      expect((s['b']!.x, s['c']!.x), (300, 600));
      expect({for (final e in s.doc.edges.values) (e.source, e.target)}, {('a', 'b'), ('b', 'c')});
      await s.dispose(t);
    });

    testWidgets('changing a node replaces it (a new id) and re-points its edges; undo brings it back', (t) async {
      final s = await start(t);
      final a = s.actions();
      a.changeNode('b', 'llm', _defaults('llm', 'LLM'), 'source');
      expect(s['b'], isNull);
      final added = s.doc.nodes.values.singleWhere((n) => n.type == 'llm');
      expect((added.x, added.y), (300, 0));
      expect({for (final e in s.doc.edges.values) (e.source, e.target)}, {('a', added.id), (added.id, 'c')});
      expect(s.controller.undo.past.single.event, HistoryEvent.nodeChange);

      s.controller.undo.undo();
      expect(s['b']?.type, 'code');
      expect(s.doc.nodes.values.where((n) => n.type == 'llm'), isEmpty);
      expect({for (final e in s.doc.edges.values) (e.source, e.target)}, {('a', 'b'), ('b', 'c')});
      await s.dispose(t);
    });

    testWidgets('nothing while the canvas is read-only', (t) async {
      final s = await start(t);
      s.store.canvasReadOnly.value = true;
      s.actions().addNodeAt(const InsertAfter('c'), 'llm', _defaults('llm'));
      s.actions().changeNode('b', 'llm', _defaults('llm'), 'source');
      expect(s.doc.nodes.keys, unorderedEquals(['a', 'b', 'c']));
      await s.dispose(t);
    });
  });

  testWidgets('Next step "+": pick a block, the new node is connected, and it is one undo step', (t) async {
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
    Future<void> settle([int ms = 1500]) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await settle(2000);
    final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    await t.tap(find.byKey(const ValueKey('node-llm')), warnIfMissed: false);
    await settle(300);
    expect(c.selectedNodeId, 'llm');

    // The llm node already leads to the code node: its add button is "Add parallel node".
    final add = find.text(DifyI18n.tr('workflow', 'common.addParallelNode').toUpperCase());
    await t.ensureVisible(add);
    await t.tap(add);
    await settle(400);
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(BlockSelectorCard), matching: find.text(_title('template-transform'))));
    await settle();

    final added = c.doc.nodes.values.singleWhere((n) => n.type == 'template-transform');
    expect(c.doc.edges.values.where((e) => e.source == 'llm' && e.target == added.id), hasLength(1));
    final code = c.doc.nodes['code']!;
    expect(added.x, code.x, reason: 'below the existing next step');
    expect(added.y, greaterThan(code.y));
    expect(demo.server.doc.nodes.containsKey(added.id), isTrue);
    expect(c.selectedNodeId, added.id, reason: 'the panel moves to the new node');
    expect(c.undo.past.length, 1);
    expect(c.undo.past.single.event, HistoryEvent.nodeAdd);

    c.undo.undo();
    await settle();
    expect(c.doc.nodes.containsKey(added.id), isFalse);
    expect(c.doc.edges.values.where((e) => e.target == added.id), isEmpty);
    expect(demo.server.doc.nodes.containsKey(added.id), isFalse);

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}

String _title(String type) => DifyI18n.tr('workflow', 'blocks.$type');
