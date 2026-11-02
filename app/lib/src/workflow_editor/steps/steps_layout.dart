/// The Steps view's layout: the workflow graph as a flat list of rows read top to bottom (dify-sf's phone editing
/// surface; Dify has no counterpart). A pure function of the document ([computeStepsLayout]), memoised per document
/// revision ([StepsLayoutCache]).
///
/// The rules, for a graph of nodes and edges (notes are not steps and never appear):
///
/// 1. **Order.** The flow starts at the entry nodes (Start, triggers, data sources; by position, top to bottom) and
///    follows the edges. A document without an entry node starts at the nodes nothing leads to.
/// 2. **Branches.** A node whose outgoing edges leave from several handles (IF/ELSE cases and ELSE, question
///    classifier classes, human-input actions and the timeout) or from one handle to several nodes (parallel
///    branches) is a branch: each handle's edge becomes a lane ([StepRowKind.laneHeader] then the lane's steps, one
///    level deeper). A declared handle without an edge is an empty lane ([StepRowKind.addStep]). The lanes end where
///    they meet again, at the branch's immediate post-dominator (the first node every path from the branch to the
///    end goes through); the flow then continues there ([StepRowKind.connector] with a join insert, then the node).
///    When no such node exists (a lane ends in its own End or Answer), each lane runs to its end.
/// 3. **Fail branches.** A node with a `source` handle and an error-handling fail branch keeps its normal path in
///    the flow below it; the fail branch is a lane under the node. Its steps are placed after the normal path, so a
///    fail branch that rejoins the normal path shows a link to it. Fail-branch edges do not count when finding where
///    branches meet (an error path that ends on its own does not keep a classifier's lanes from joining).
/// 4. **Nodes that do not nest.** Every node is placed once, where the flow first reaches it in this order (a lane
///    before the next lane, the normal path before a fail branch). Every other edge into it (from another lane, a
///    second incoming edge, a cycle) ends in a [StepRowKind.link] row ("continues at") instead of a second card.
/// 5. **Containers.** An iteration's or loop's card is followed by its body, one level deeper: from its inner start
///    node (a [StepRowKind.bodyStart] row stands for it) by the same rules, then the children nothing reaches.
/// 6. **Not connected.** Nodes no entry reaches come last, under [StepRowKind.section], by the same rules.
///
/// Inserting: every [StepRowKind.connector] and [StepRowKind.addStep] row carries the [StepInsert] its "+" uses:
/// on the edge it stands for ([InsertOnEdge]), after a node's handle where nothing follows ([InsertAfter]), or, at a
/// join, on one of the edges into the join with the others moved onto the new node ([StepInsert.retarget]).
///
/// Cost: O(n + e) to collect the graph and emit the rows, plus the post-dominators (Cooper, Harvey and Kennedy's
/// iterative algorithm on the reversed graph, near linear for workflow graphs).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import '../../canvas/canvas_graph.dart';
import '../../cards/node_extras.dart';
import '../../workflow/dify_json.dart';
import '../context_menu/clipboard.dart' show isNoteNode;
import '../node_insertion/insert_block.dart';

/// What a row of the Steps list shows.
enum StepRowKind {
  /// A step's card ([StepRow.nodeId]).
  card,

  /// The line between steps, with a "+" at [StepRow.insert] (no "+" without one).
  connector,

  /// The label of a lane of branch [StepRow.nodeId] ([StepRow.handle], [StepRow.lane], [StepRow.laneIndex]).
  laneHeader,

  /// "Continues at" step [StepRow.nodeId]: the flow goes on at a step shown elsewhere.
  link,

  /// "Add step" in an empty lane or body, inserting at [StepRow.insert].
  addStep,

  /// The start of a container's body: stands for its inner start node [StepRow.nodeId]; a "+" at [StepRow.insert]
  /// (on its edge, or after it when the body is empty: [StepRow.emptyBody]).
  bodyStart,

  /// The "Not connected" heading (top level, or inside a container's body).
  section,

  /// Space between two separate flows (a second entry node, another unconnected group).
  gap,
}

/// The kind of a lane, which decides its label and colour.
enum StepLaneKind {
  /// An IF/ELSE case (IF, ELIF).
  ifCase,

  /// The IF/ELSE's ELSE (`false`).
  elseCase,

  /// A question classifier's class.
  classifierClass,

  /// A human-input user action.
  humanAction,

  /// A human-input timeout (`__timeout`).
  timeout,

  /// An error-handling fail branch (`fail-branch`).
  failBranch,

  /// One of several edges leaving one handle.
  parallel,

  /// A container's body.
  body,

  /// A handle the node does not declare (an edge left from a removed case).
  other,
}

/// One nesting level a row sits in: a lane of branch [ownerId] ([handle]) or a container's body.
@immutable
class StepRail {
  const StepRail(this.ownerId, this.handle, this.kind);
  final String ownerId;
  final String? handle;
  final StepLaneKind kind;

  @override
  bool operator ==(Object other) =>
      other is StepRail && other.ownerId == ownerId && other.handle == handle && other.kind == kind;

  @override
  int get hashCode => Object.hash(ownerId, handle, kind);

  @override
  String toString() => 'StepRail($ownerId, $handle, ${kind.name})';
}

/// Where a "+" inserts: [at], and at a join the other edges into the join, which move onto the new node.
@immutable
class StepInsert {
  const StepInsert(this.at, [this.retarget = const []]);
  final InsertPoint at;

  /// Edge ids that end at [at]'s target too and are moved onto the inserted node (a join's other incoming edges).
  final List<String> retarget;

  bool get isJoin => retarget.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is StepInsert && _samePoint(other.at, at) && listEquals(other.retarget, retarget);

  @override
  int get hashCode => Object.hash(_pointKey(at), Object.hashAll(retarget));

  @override
  String toString() => 'StepInsert(${_pointKey(at)}${retarget.isEmpty ? '' : ' +$retarget'})';
}

String _pointKey(InsertPoint p) => switch (p) {
  InsertAfter(:final nodeId, :final sourceHandle) => 'after:$nodeId:$sourceHandle',
  InsertBefore(:final nodeId, :final targetHandle) => 'before:$nodeId:$targetHandle',
  InsertOnEdge(:final edgeId) => 'edge:$edgeId',
};

bool _samePoint(InsertPoint a, InsertPoint b) => _pointKey(a) == _pointKey(b);

/// One row of the Steps list. [key] is stable across rebuilds of the same graph and unique in a layout.
@immutable
class StepRow {
  const StepRow({
    required this.kind,
    required this.key,
    this.rails = const [],
    this.nodeId,
    this.handle,
    this.lane,
    this.laneIndex = 0,
    this.insert,
    this.emptyBody = false,
  });

  final StepRowKind kind;
  final String key;

  /// The lanes and bodies the row is in, outermost first.
  final List<StepRail> rails;

  /// The card's step, the link's target, the lane's branch node, the body start's start node.
  final String? nodeId;

  /// A lane header's handle.
  final String? handle;
  final StepLaneKind? lane;

  /// A lane header's position: the case or class number for declared handles, the parallel number for parallel
  /// lanes.
  final int laneIndex;

  /// Where the row's "+" inserts (connectors, add rows, body starts), or what a card's "Add step after" uses.
  final StepInsert? insert;

  /// A body start of an empty body (drawn as an "Add step" row).
  final bool emptyBody;

  int get depth => rails.length;

  /// The node this row stands for in the list (each step node has exactly one such row).
  String? get representedNode => kind == StepRowKind.card || kind == StepRowKind.bodyStart ? nodeId : null;

  StepRow _withInsert(StepInsert? insert) => StepRow(
    kind: kind,
    key: key,
    rails: rails,
    nodeId: nodeId,
    handle: handle,
    lane: lane,
    laneIndex: laneIndex,
    insert: insert,
    emptyBody: emptyBody,
  );

  @override
  String toString() =>
      'StepRow(${kind.name} $key d$depth${nodeId == null ? '' : ' $nodeId'}'
      '${handle == null ? '' : ' [$handle]'}${insert == null ? '' : ' $insert'})';
}

/// The rows, and where each step's row is.
@immutable
class StepsLayout {
  StepsLayout(this.rows)
    : _rowOfNode = {for (final (i, r) in rows.indexed) ?r.representedNode: i},
      _rowOfKey = {for (final (i, r) in rows.indexed) r.key: i};

  static final empty = StepsLayout(const []);

  final List<StepRow> rows;
  final Map<String, int> _rowOfNode, _rowOfKey;

  /// The index of the row that stands for node [id] (its card, or its container's body start).
  int? rowOfNode(String id) => _rowOfNode[id];

  /// The index of the row with [key].
  int? rowOfKey(String key) => _rowOfKey[key];
}

// ---- the graph ----------------------------------------------------------------------------------------------------

/// Entry nodes: where a flow starts (utils/workflow-entry.ts, and a pipeline's data sources).
const stepEntryTypes = {
  'start',
  'start-placeholder',
  'trigger-schedule',
  'trigger-webhook',
  'trigger-plugin',
  'datasource',
  'datasource-empty',
};

const _containerTypes = {'iteration', 'loop'};
const _containerStartTypes = {'iteration-start', 'loop-start'};

/// Node types whose card has no source handle (their bodies' `sources` are empty).
const _noSourceTypes = {'datasource-empty', 'start-placeholder', 'loop-end'};

/// The source handles a node's card draws, in the card's order (Dify's names): the IF/ELSE cases then `false`, the
/// question classifier's classes, the human input's actions then `__timeout`, otherwise `source`; then
/// `fail-branch` when errors take the fail branch. As the canvas cards' `sources` (cards/bodies, [NodeExtras]).
List<String> stepHandlesOf(Node n) {
  List<Object?> list(String key) => jsList(plainOf(n.config[key]));
  String id(Object? item, String key) => '${jsGet(item, key) ?? ''}';
  final own = switch (n.type) {
    'if-else' => [for (final c in list('cases')) id(c, 'case_id'), 'false'],
    'question-classifier' => [for (final c in list('classes')) id(c, 'id')],
    'human-input' => [for (final a in list('user_actions')) id(a, 'id'), '__timeout'],
    _ when _noSourceTypes.contains(n.type) => const <String>[],
    _ => const ['source'],
  };
  return [...own, if (hasFailBranch(n)) NodeExtras.failBranch];
}

/// utils/workflow.ts hasErrorHandleNode with `error_strategy: fail-branch`: the node's errors take its fail branch
/// (the card's "On Failure" row with the `fail-branch` handle, [NodeExtras]). Without the card's geometry, so it
/// needs no binding.
bool hasFailBranch(Node n) =>
    const {'llm', 'tool', 'http-request', 'code', 'agent', 'agent-v2'}.contains(n.type) &&
    n.config['error_strategy'] == const VString(NodeExtras.failBranch);

/// The kind of [n]'s lane from [handle].
StepLaneKind laneKindOf(Node n, String handle) => switch ((n.type, handle)) {
  (_, NodeExtras.failBranch) => StepLaneKind.failBranch,
  ('if-else', 'false') => StepLaneKind.elseCase,
  ('if-else', _) => StepLaneKind.ifCase,
  ('question-classifier', _) => StepLaneKind.classifierClass,
  ('human-input', '__timeout') => StepLaneKind.timeout,
  ('human-input', _) => StepLaneKind.humanAction,
  _ => StepLaneKind.other,
};

/// The node a container's body starts at: its iteration-start or loop-start child, else the child its
/// `start_node_id` names.
String? _innerStartOf(Node container, List<Node> children) {
  for (final c in children) {
    if (_containerStartTypes.contains(c.type)) return c.id;
  }
  final named = jsStr(plainOf(container.config['start_node_id']));
  return children.any((c) => c.id == named) ? named : null;
}

int _byPosition(Node a, Node b) {
  final y = a.y.compareTo(b.y);
  if (y != 0) return y;
  final x = a.x.compareTo(b.x);
  return x != 0 ? x : a.id.compareTo(b.id);
}

/// The graph the rows are made from: step nodes (no notes) by scope (null: the top level, else the container's id),
/// in-scope edges by source and handle.
class _Graph {
  _Graph(Document doc) {
    for (final n in doc.nodes.values) {
      if (n.id.startsWith(r'$') || isNoteNode(n)) continue;
      nodes[n.id] = n;
    }
    for (final n in nodes.values) {
      final parent = CanvasGraph.parentOf(n);
      scopeOf[n.id] = parent != null && _containerTypes.contains(nodes[parent]?.type) ? parent : null;
    }
    for (final n in nodes.values) {
      (members[scopeOf[n.id]] ??= []).add(n);
    }
    for (final list in members.values) {
      list.sort(_byPosition);
    }
    for (final e in doc.edges.values) {
      final s = nodes[e.source], t = nodes[e.target];
      if (s == null || t == null || scopeOf[s.id] != scopeOf[t.id]) continue;
      ((out[s.id] ??= {})[difyHandle(e.sourceHandle)] ??= []).add(e);
      (incoming[t.id] ??= []).add(e);
    }
    for (final byHandle in out.values) {
      for (final edges in byHandle.values) {
        edges.sort((a, b) {
          final c = _byPosition(nodes[a.target]!, nodes[b.target]!);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      }
    }
  }

  final nodes = <String, Node>{};
  final scopeOf = <String, String?>{};
  final members = <String?, List<Node>>{};
  final out = <String, Map<String, List<Edge>>>{};
  final incoming = <String, List<Edge>>{};

  Map<String, List<Edge>> outOf(String id) => out[id] ?? const {};
  List<Edge> inOf(String id) => incoming[id] ?? const [];

  final _declared = <String, List<String>>{}, _handles = <String, List<String>>{};

  /// [id]'s declared handles ([stepHandlesOf]).
  List<String> declaredOf(String id) => _declared[id] ??= stepHandlesOf(nodes[id]!);

  /// [id]'s handles: the declared ones in the card's order, then any other handle an edge leaves from.
  List<String> handlesOf(String id) => _handles[id] ??= () {
    final declared = declaredOf(id);
    final extra = [
      for (final h in outOf(id).keys)
        if (!declared.contains(h)) h,
    ]..sort();
    return [...declared, ...extra];
  }();

  Iterable<Edge> outEdges(String id) sync* {
    for (final h in handlesOf(id)) {
      yield* outOf(id)[h] ?? const <Edge>[];
    }
  }
}

/// Immediate post-dominators of the nodes of one scope: the first node every path to the end goes through, or null
/// for the end itself. Nodes that never reach an end (a cycle without a way out) are treated as ends. Fail-branch
/// edges are left out: an error path is an excursion under its node and does not keep the branches around it from
/// meeting again.
Map<String, String?> _postDominators(List<Node> scope, _Graph g) {
  final n = scope.length, exit = n;
  final index = {for (final (i, node) in scope.indexed) node.id: i};
  final succ = List.generate(n, (_) => <int>[]), pred = List.generate(n, (_) => <int>[]);
  for (final (i, node) in scope.indexed) {
    final seen = <int>{};
    for (final e in g.outEdges(node.id)) {
      if (difyHandle(e.sourceHandle) == NodeExtras.failBranch) continue;
      final j = index[e.target];
      if (j != null && seen.add(j)) {
        succ[i].add(j);
        pred[j].add(i);
      }
    }
  }
  // The reversed graph from the exit: the exit leads to the ends, each node to its predecessors. A decision's handle
  // without an edge (an IF/ELSE case, a class, an action: a node without a `source` handle) ends the run there: an
  // edge to the exit.
  bool endsUnconnected(Node node) {
    final declared = g.declaredOf(node.id);
    if (declared.contains('source')) return false;
    final out = g.outOf(node.id);
    return declared.any((h) => (out[h] ?? const []).isEmpty);
  }

  final toExit = <int>[
    for (var i = 0; i < n; i++)
      if (succ[i].isEmpty || endsUnconnected(scope[i])) i,
  ];
  final reached = List.filled(n + 1, false)..[exit] = true;
  void reach(List<int> from) {
    final todo = [...from];
    for (final i in from) {
      reached[i] = true;
    }
    while (todo.isNotEmpty) {
      for (final p in pred[todo.removeLast()]) {
        if (!reached[p]) {
          reached[p] = true;
          todo.add(p);
        }
      }
    }
  }

  reach(toExit);
  for (var i = 0; i < n; i++) {
    if (!reached[i]) {
      toExit.add(i);
      reach([i]);
    }
  }
  final exitSet = toExit.toSet();
  List<int> reversedSuccessors(int v) => v == exit ? toExit : pred[v];

  // Post-order of the reversed graph (iterative DFS).
  final order = List.filled(n + 1, -1);
  final postorder = <int>[];
  final visited = List.filled(n + 1, false)..[exit] = true;
  final stack = <(int, int)>[(exit, 0)];
  while (stack.isNotEmpty) {
    final (v, next) = stack.removeLast();
    final children = reversedSuccessors(v);
    if (next < children.length) {
      stack.add((v, next + 1));
      final c = children[next];
      if (!visited[c]) {
        visited[c] = true;
        stack.add((c, 0));
      }
    } else {
      order[v] = postorder.length;
      postorder.add(v);
    }
  }
  // Cooper, Harvey, Kennedy: the predecessors of v in the reversed graph are its successors (and the exit for ends).
  final idom = List<int?>.filled(n + 1, null)..[exit] = exit;
  int intersect(int a, int b) {
    while (a != b) {
      while (order[a] < order[b]) {
        a = idom[a]!;
      }
      while (order[b] < order[a]) {
        b = idom[b]!;
      }
    }
    return a;
  }

  var changed = true;
  while (changed) {
    changed = false;
    for (final v in postorder.reversed) {
      if (v == exit) continue;
      int? next;
      for (final p in [...succ[v], if (exitSet.contains(v)) exit]) {
        if (idom[p] == null) continue;
        next = next == null ? p : intersect(p, next);
      }
      if (next != null && idom[v] != next) {
        idom[v] = next;
        changed = true;
      }
    }
  }
  return {
    for (var i = 0; i < n; i++) scope[i].id: idom[i] == null || idom[i] == exit ? null : scope[idom[i]!].id,
  };
}

// ---- the rows -----------------------------------------------------------------------------------------------------

/// The lanes of a branch: one per edge, and one per declared handle without an edge (`edge` null).
typedef _Lane = ({String handle, StepLaneKind kind, int index, Edge? edge});

class _Builder {
  _Builder(this.g);

  final _Graph g;
  final placed = <String>{};
  final _order = <String, int>{};
  final _keys = <String>{};
  final _postDom = <String?, Map<String, String?>>{};

  String _key(String base) {
    var k = base;
    for (var i = 2; !_keys.add(k); i++) {
      k = '$base#$i';
    }
    return k;
  }

  void _place(String id) {
    placed.add(id);
    _order[id] = _order.length;
  }

  String? _ipdom(String id) {
    final scope = g.scopeOf[id];
    final map = _postDom[scope] ??= _postDominators(g.members[scope] ?? const [], g);
    return map[id];
  }

  bool _isContainerStart(String id) => _containerStartTypes.contains(g.nodes[id]!.type);

  /// The flow from [start] until it reaches one of [stops] (an enclosing join), an end, or a step already shown.
  /// Fail-branch lanes are filled in after the flow, into slots kept right after their node's card.
  void flow(String start, Set<String> stops, List<StepRail> rails, List<Object> out) {
    final later = <void Function()>[];
    String? at = start;
    while (at != null) {
      final id = at;
      at = null;
      if (stops.contains(id)) break;
      if (placed.contains(id)) {
        out.add(StepRow(kind: StepRowKind.link, key: _key('k:$id'), rails: rails, nodeId: id));
        break;
      }
      _place(id);
      final isStart = _isContainerStart(id);
      final cardAt = out.length;
      if (!isStart) {
        out.add(StepRow(kind: StepRowKind.card, key: _key('n:$id'), rails: rails, nodeId: id));
        if (_containerTypes.contains(g.nodes[id]!.type)) {
          body(id, [...rails, StepRail(id, null, StepLaneKind.body)], out);
        }
      }
      void addAfter(StepInsert? insert) {
        if (!isStart) out[cardAt] = (out[cardAt] as StepRow)._withInsert(insert);
      }

      // A container start is drawn as its body's first "+" (or "Add step" when nothing follows it).
      StepRow startRow(StepInsert insert, {bool empty = false}) => StepRow(
        kind: StepRowKind.bodyStart,
        key: _key('b:$id'),
        rails: rails,
        nodeId: id,
        insert: insert,
        emptyBody: empty,
      );

      final handles = g.handlesOf(id);
      final byHandle = g.outOf(id);
      final source = byHandle['source'] ?? const <Edge>[];
      final sides = [
        for (final h in handles)
          if (h != 'source') h,
      ];
      final hasSource = handles.contains('source');
      if (hasSource && source.length <= 1) {
        // The flow continues on the normal path; other handles (the fail branch) hang under the card as lanes.
        if (sides.isNotEmpty) {
          final slot = <Object>[];
          out.add(slot);
          final laneRailsStops = stops;
          later.add(() => lanes(id, [for (final h in sides) ..._lanesOf(id, h)], laneRailsStops, rails, slot));
        }
        if (source.isEmpty) {
          final insert = StepInsert(InsertAfter(id, 'source'));
          addAfter(insert);
          out.add(
            isStart
                ? startRow(insert, empty: true)
                : StepRow(kind: StepRowKind.connector, key: _key('a:$id'), rails: rails, insert: insert),
          );
        } else {
          final e = source.single;
          final insert = StepInsert(InsertOnEdge(e.id));
          addAfter(insert);
          out.add(
            isStart
                ? startRow(insert)
                : StepRow(kind: StepRowKind.connector, key: _key('c:${e.id}'), rails: rails, insert: insert),
          );
          at = e.target;
        }
        continue;
      }
      if (handles.isEmpty) break; // no source handle at all (Exit Loop, an empty data source)
      // A branch: lanes until they meet again.
      if (isStart) out.add(startRow(StepInsert(InsertAfter(id, 'source'))));
      final join = _ipdom(id);
      final inner = join == null ? stops : {...stops, join};
      final mark = _order.length;
      lanes(id, [for (final h in handles) ..._lanesOf(id, h)], inner, rails, out);
      if (join == null || stops.contains(join)) {
        addAfter(null);
        break;
      }
      if (placed.contains(join)) {
        out.add(StepRow(kind: StepRowKind.link, key: _key('k:$join'), rails: rails, nodeId: join));
        break;
      }
      // The edges into the join from this branch's lanes (or straight from the branch node).
      final into = [
        for (final e in g.inOf(join))
          if (e.source == id || (_order[e.source] ?? -1) >= mark) e.id,
      ];
      final insert = into.isEmpty ? null : StepInsert(InsertOnEdge(into.first), into.sublist(1));
      addAfter(insert);
      out.add(StepRow(kind: StepRowKind.connector, key: _key('j:$join'), rails: rails, insert: insert));
      at = join;
    }
    for (final fill in later) {
      fill();
    }
  }

  List<_Lane> _lanesOf(String id, String handle) {
    final node = g.nodes[id]!;
    final edges = g.outOf(id)[handle] ?? const <Edge>[];
    final declared = g.declaredOf(id);
    final kind = laneKindOf(node, handle);
    final index = declared.indexOf(handle);
    if (edges.isEmpty) {
      // Only a declared branch handle is an empty lane (a plain `source` without edges is the end of the flow).
      return [
        if (index >= 0 && (handle != 'source' || declared.length > 1))
          (handle: handle, kind: kind, index: index, edge: null),
      ];
    }
    if (edges.length == 1) return [(handle: handle, kind: kind, index: index, edge: edges.single)];
    return [
      for (final (i, e) in edges.indexed)
        (handle: handle, kind: kind == StepLaneKind.other ? StepLaneKind.parallel : kind, index: i, edge: e),
    ];
  }

  void lanes(String owner, List<_Lane> list, Set<String> stops, List<StepRail> rails, List<Object> out) {
    for (final lane in list) {
      final laneRails = [...rails, StepRail(owner, lane.handle, lane.kind)];
      out.add(
        StepRow(
          kind: StepRowKind.laneHeader,
          key: _key('l:$owner:${lane.handle}${lane.edge == null ? '' : ':${lane.edge!.id}'}'),
          rails: laneRails,
          nodeId: owner,
          handle: lane.handle,
          lane: lane.kind,
          laneIndex: lane.index,
        ),
      );
      final e = lane.edge;
      if (e == null) {
        out.add(
          StepRow(
            kind: StepRowKind.addStep,
            key: _key('p:$owner:${lane.handle}'),
            rails: laneRails,
            insert: StepInsert(InsertAfter(owner, lane.handle)),
          ),
        );
        continue;
      }
      if (stops.contains(e.target) || placed.contains(e.target)) {
        // Straight to where the lanes meet (or to a step shown elsewhere): an empty lane on that edge.
        out.add(
          StepRow(
            kind: StepRowKind.addStep,
            key: _key('p:${e.id}'),
            rails: laneRails,
            insert: StepInsert(InsertOnEdge(e.id)),
          ),
        );
        if (!stops.contains(e.target)) {
          out.add(StepRow(kind: StepRowKind.link, key: _key('k:${e.target}'), rails: laneRails, nodeId: e.target));
        }
        continue;
      }
      flow(e.target, stops, laneRails, out);
    }
  }

  /// A container's body: from its inner start, then the children nothing there reaches.
  void body(String container, List<StepRail> rails, List<Object> out) {
    final children = g.members[container] ?? const <Node>[];
    final start = _innerStartOf(g.nodes[container]!, children);
    if (start != null) {
      flow(start, const {}, rails, out);
    } else if (children.isEmpty) {
      return;
    }
    rest(container, rails, out, entries: start == null);
  }

  /// The members of [scope] not placed yet: as flows from the nodes nothing in the scope leads to first. Under a
  /// "Not connected" heading unless they are the scope's [entries].
  void rest(String? scope, List<StepRail> rails, List<Object> out, {bool entries = false}) {
    final left = [
      for (final n in g.members[scope] ?? const <Node>[])
        if (!placed.contains(n.id)) n,
    ];
    if (left.isEmpty) return;
    if (!entries) out.add(StepRow(kind: StepRowKind.section, key: _key('s:${scope ?? ''}'), rails: rails));
    final heads = [
      for (final n in left)
        if (g.inOf(n.id).isEmpty) n,
      for (final n in left)
        if (g.inOf(n.id).isNotEmpty) n,
    ];
    var first = true;
    for (final n in heads) {
      if (placed.contains(n.id)) continue;
      if (!first) out.add(StepRow(kind: StepRowKind.gap, key: _key('g:${n.id}'), rails: rails));
      first = false;
      flow(n.id, const {}, rails, out);
    }
  }

  List<StepRow> build() {
    final out = <Object>[];
    final top = g.members[null] ?? const <Node>[];
    final entries = [
      for (final n in top)
        if (stepEntryTypes.contains(n.type)) n,
    ];
    if (entries.isEmpty) {
      rest(null, const [], out, entries: true);
    } else {
      for (final (i, n) in entries.indexed) {
        if (placed.contains(n.id)) continue;
        if (i > 0) out.add(StepRow(kind: StepRowKind.gap, key: _key('g:${n.id}'), rails: const []));
        flow(n.id, const {}, const [], out);
      }
      rest(null, const [], out);
    }
    // Flatten the slots (fail-branch lanes filled in after the flow that follows them).
    final rows = <StepRow>[];
    final stack = <(List<Object>, int)>[(out, 0)];
    while (stack.isNotEmpty) {
      final (list, i) = stack.removeLast();
      if (i >= list.length) continue;
      stack.add((list, i + 1));
      switch (list[i]) {
        case final StepRow r:
          rows.add(r);
        case final List<Object> slot:
          stack.add((slot, 0));
      }
    }
    return rows;
  }
}

/// The Steps rows of [doc] (see the library comment for the rules).
StepsLayout computeStepsLayout(Document doc) => StepsLayout(_Builder(_Graph(doc)).build());

/// [computeStepsLayout], computed again only when the graph changed: the nodes (their ids, types and configs, by
/// identity) or the edges (by identity). Moves and title edits, which change neither the order nor the lanes, reuse
/// the layout.
class StepsLayoutCache {
  StepsLayout? _layout;
  List<(String, String, Object)> _nodes = const [];
  List<Edge> _edges = const [];

  /// How many times the layout was computed (for tests).
  @visibleForTesting
  int computations = 0;

  StepsLayout layoutOf(Document doc) {
    final layout = _layout;
    if (layout != null && _same(doc)) return layout;
    _nodes = [for (final n in doc.nodes.values) (n.id, n.type, n.config)];
    _edges = doc.edges.values.toList();
    computations++;
    return _layout = computeStepsLayout(doc);
  }

  bool _same(Document doc) {
    if (doc.nodes.length != _nodes.length || doc.edges.length != _edges.length) return false;
    var i = 0;
    for (final n in doc.nodes.values) {
      final (id, type, config) = _nodes[i++];
      if (n.id != id || n.type != type || !identical(n.config, config)) return false;
    }
    i = 0;
    for (final e in doc.edges.values) {
      if (!identical(e, _edges[i++])) return false;
    }
    return true;
  }
}
