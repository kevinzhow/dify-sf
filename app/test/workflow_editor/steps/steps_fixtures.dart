// Shared by the Steps view tests: a small graph builder, the layout as an outline, and the layout's invariants.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/steps_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Config of a node whose errors take the fail branch.
const failBranch = {'error_strategy': VString('fail-branch')};

/// A graph built node by node: nodes go down the canvas in the order they are added (unless [add] gets a `y`).
class Graph {
  final nodes = <Node>[];
  final edges = <Edge>[];
  var _y = 0;

  Document get doc => Document(nodes: nodes, edges: edges);

  void add(
    String id,
    String type, {
    String? title,
    String? parent,
    int? y,
    String? rfType,
    Map<String, Value> config = const {},
  }) {
    _y += 100;
    nodes.add(
      Node(
        id: id,
        type: type,
        title: title ?? id,
        x: 0,
        y: y ?? _y,
        config: {
          ...config,
          if (parent != null || rfType != null)
            '_dify_node': VMap({
              'type': VString(rfType ?? 'custom'),
              if (parent != null) 'parentId': VString(parent),
            }),
        },
      ),
    );
  }

  /// An IF/ELSE with [cases] (each `variable > 0` on a Start variable).
  void ifElse(String id, List<String> cases, {String? title}) => add(
    id,
    'if-else',
    title: title,
    config: {
      'cases': VList([
        for (final c in cases)
          VMap({
            'case_id': VString(c),
            'logical_operator': const VString('and'),
            'conditions': VList([
              VMap({
                'id': VString('$c-1'),
                'variable_selector': const VList([VString('s'), VString('words')]),
                'comparison_operator': const VString('>'),
                'value': const VString('0'),
              }),
            ]),
          }),
      ]),
    },
  );

  /// A question classifier with [classes] (named "Topic `id`").
  void classifier(String id, List<String> classes) => add(
    id,
    'question-classifier',
    config: {
      'classes': VList([
        for (final c in classes) VMap({'id': VString(c), 'name': VString('Topic $c')}),
      ]),
    },
  );

  void link(String a, String b, [String handle = 'source']) =>
      edges.add(Edge(id: '$a-$handle-$b', source: a, sourceHandle: handle, target: b, targetHandle: 'target'));

  void chain(List<String> ids) {
    for (var i = 0; i + 1 < ids.length; i++) {
      link(ids[i], ids[i + 1]);
    }
  }
}

/// The rows as text, two spaces per level: a card is its node id, `+` a connector (`+join` at a join, `+end`
/// after a last step), `[handle]` a lane, `→ id` a link, `add` an empty lane, `start` a body start, `~` a gap.
List<String> outline(StepsLayout layout) => [
  for (final r in layout.rows)
    '${'  ' * r.depth}${switch (r.kind) {
      StepRowKind.card => r.nodeId!,
      StepRowKind.connector => r.insert == null
          ? '|'
          : r.insert!.isJoin
          ? '+join'
          : r.insert!.at is InsertAfter
          ? '+end'
          : '+',
      StepRowKind.laneHeader => '[${r.handle}]',
      StepRowKind.link => '→ ${r.nodeId}',
      StepRowKind.addStep => 'add',
      StepRowKind.bodyStart => r.emptyBody ? 'start(empty)' : 'start',
      StepRowKind.section => '-- not connected',
      StepRowKind.gap => '~',
    }}',
];

/// Every step node (not notes) stands for exactly one row, keys are unique, rows refer to nodes that exist, and
/// every insert point names nodes and edges of the document.
void expectWellFormed(Document doc, StepsLayout layout) {
  final steps = [
    for (final n in doc.nodes.values)
      if (!isNoteNode(n)) n.id,
  ];
  final shown = [for (final r in layout.rows) ?r.representedNode];
  expect(shown.toSet().length, shown.length, reason: 'a node shown twice: $shown');
  expect(shown.toSet(), steps.toSet(), reason: outline(layout).join('\n'));
  final keys = [for (final r in layout.rows) r.key];
  expect(keys.toSet().length, keys.length, reason: 'duplicate keys');
  for (final (i, r) in layout.rows.indexed) {
    if (r.nodeId != null) expect(doc.nodes.containsKey(r.nodeId), isTrue, reason: '$r');
    expect(layout.rowOfKey(r.key), i);
    for (final rail in r.rails) {
      expect(doc.nodes.containsKey(rail.ownerId), isTrue, reason: '$r');
    }
    if (r.insert case final ins?) {
      switch (ins.at) {
        case InsertAfter(:final nodeId) || InsertBefore(:final nodeId):
          expect(doc.nodes.containsKey(nodeId), isTrue, reason: '$r');
        case InsertOnEdge(:final edgeId):
          expect(doc.edges.containsKey(edgeId), isTrue, reason: '$r');
      }
      for (final e in ins.retarget) {
        expect(doc.edges[e]?.target, doc.edges[(ins.at as InsertOnEdge).edgeId]!.target, reason: '$r');
      }
    }
  }
}

/// A synthetic workflow of at least [n] steps: a chain of blocks of five (a code step, an IF/ELSE whose two lanes
/// meet again, an iteration with two steps inside), each block joining the next.
Graph bigGraph(int n) {
  final g = Graph()..add('start', 'start');
  var last = 'start';
  for (var i = 0; g.nodes.length < n; i++) {
    final code = 'code$i', branch = 'if$i', a = 'a$i', b = 'b$i', it = 'it$i';
    g
      ..add(code, 'code', title: 'Code $i')
      ..ifElse(branch, ['c$i'], title: 'Check $i')
      ..add(a, 'llm', title: 'Ask $i')
      ..add(b, 'template-transform', title: 'Format $i')
      ..add(it, 'iteration', title: 'Each $i')
      ..add('is$i', 'iteration-start', parent: it)
      ..add('in$i', 'code', parent: it, title: 'Inner $i')
      ..link(last, code)
      ..link(code, branch)
      ..link(branch, a, 'c$i')
      ..link(branch, b, 'false')
      ..link(a, it)
      ..link(b, it)
      ..link('is$i', 'in$i');
    last = it;
  }
  g
    ..add('end', 'end')
    ..link(last, 'end');
  return g;
}
