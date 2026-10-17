/// Dart port of CollabCore's document model (Value, Op, Document.validate/apply).
/// Same rules as the Swift server: both sides must run identical validate/apply logic.
library;

/// Config values are plain JSON-like Dart objects (null, bool, int, String, List, Map<String, Object?>)
/// plus [Ref] / [BrokenRef]. Broken refs are written by the server only.
class Ref {
  final String node, output;
  const Ref(this.node, this.output);
  @override
  bool operator ==(Object o) => o is Ref && o.node == node && o.output == output;
  @override
  int get hashCode => Object.hash(node, output);
  @override
  String toString() => 'Ref($node.$output)';
}

class BrokenRef extends Ref {
  const BrokenRef(super.node, super.output);
  @override
  bool operator ==(Object o) => o is BrokenRef && o.node == node && o.output == output;
  @override
  int get hashCode => Object.hash('broken', node, output);
  @override
  String toString() => 'BrokenRef($node.$output)';
}

bool deepEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && deepEq(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length && List.generate(a.length, (i) => deepEq(a[i], b[i])).every((x) => x);
  }
  return a == b;
}

Object? deepCopy(Object? v) => v is Map
    ? {for (final e in v.entries) e.key as String: deepCopy(e.value)}
    : v is List
        ? v.map(deepCopy).toList()
        : v;

Iterable<Ref> liveRefs(Object? v) sync* {
  if (v is BrokenRef) return;
  if (v is Ref) yield v;
  if (v is List) for (final i in v) yield* liveRefs(i);
  if (v is Map) for (final k in (v.keys.cast<String>().toList()..sort())) yield* liveRefs(v[k]);
}

bool containsBroken(Object? v) =>
    v is BrokenRef || (v is List && v.any(containsBroken)) || (v is Map && v.values.any(containsBroken));

Object? breaking(Object? v, String node) {
  if (v is Ref && v is! BrokenRef && v.node == node) return BrokenRef(v.node, v.output);
  if (v is List) return v.map((i) => breaking(i, node)).toList();
  if (v is Map) return {for (final e in v.entries) e.key as String: breaking(e.value, node)};
  return v;
}

/// Marks refs to [node] broken in-place; returns changed map-key paths (lists are atomic leaves).
List<List<String>> breakRefs(Map<String, Object?> cfg, String node, [List<String> prefix = const []]) {
  final changed = <List<String>>[];
  for (final key in (cfg.keys.toList()..sort())) {
    final v = cfg[key];
    final path = [...prefix, key];
    if (v is Map) {
      final sub = breakRefs(v.cast<String, Object?>(), node, path);
      changed.addAll(sub);
    } else if ((v is Ref || v is List) && liveRefs(v).any((r) => r.node == node)) {
      cfg[key] = breaking(v, node);
      changed.add(path);
    }
  }
  return changed;
}

bool canSet(Map<String, Object?> cfg, List<String> path) {
  if (path.isEmpty) return false;
  var cur = cfg;
  for (final k in path.take(path.length - 1)) {
    final next = cur[k];
    if (next == null) return true;
    if (next is! Map) return false;
    cur = next.cast<String, Object?>();
  }
  return true;
}

void setPath(Map<String, Object?> cfg, List<String> path, Object? value) {
  if (path.length == 1) {
    cfg[path[0]] = value;
    return;
  }
  final child = cfg[path[0]] is Map ? (cfg[path[0]] as Map).cast<String, Object?>() : <String, Object?>{};
  setPath(child, path.sublist(1), value);
  cfg[path[0]] = child;
}

class Node {
  final String id, type;
  String title;
  int x, y;
  Map<String, Object?> config;
  Node(this.id, this.type, {this.title = '', this.x = 0, this.y = 0, Map<String, Object?>? config})
      : config = config ?? {};
  Node copy() => Node(id, type, title: title, x: x, y: y, config: deepCopy(config) as Map<String, Object?>);
  @override
  bool operator ==(Object o) =>
      o is Node && o.id == id && o.type == type && o.title == title && o.x == x && o.y == y && deepEq(o.config, config);
  @override
  int get hashCode => Object.hash(id, type, title, x, y);
}

class Edge {
  final String id, source, sourceHandle, target, targetHandle;
  const Edge(this.id, this.source, this.target, {this.sourceHandle = 'out', this.targetHandle = 'in'});
  @override
  bool operator ==(Object o) =>
      o is Edge &&
      o.id == id &&
      o.source == source &&
      o.target == target &&
      o.sourceHandle == sourceHandle &&
      o.targetHandle == targetHandle;
  @override
  int get hashCode => Object.hash(id, source, target, sourceHandle, targetHandle);
}

class Stamp {
  final int seq;
  final String client;
  const Stamp(this.seq, this.client);
}

/// A versioned register inside a node: title, position, or a config path.
class FieldKey {
  final String kind; // 'title' | 'position' | 'config'
  final List<String> path;
  const FieldKey.title() : kind = 'title', path = const [];
  const FieldKey.position() : kind = 'position', path = const [];
  const FieldKey.config(this.path) : kind = 'config';
  String get id => '$kind:${path.join('/')}';
  bool overlaps(FieldKey o) {
    if (kind != o.kind) return false;
    if (kind != 'config') return true;
    final n = path.length < o.path.length ? path.length : o.path.length;
    for (var i = 0; i < n; i++) {
      if (path[i] != o.path[i]) return false;
    }
    return true;
  }
}

sealed class Op {
  const Op();
}

class AddNode extends Op {
  final Node node;
  const AddNode(this.node);
}

class RemoveNode extends Op {
  final String id;
  const RemoveNode(this.id);
}

class MoveNode extends Op {
  final String id;
  final int x, y;
  const MoveNode(this.id, this.x, this.y);
}

class SetField extends Op {
  final String id;
  final FieldKey key;
  final Object? value;
  const SetField(this.id, this.key, this.value);
}

class AddEdge extends Op {
  final Edge edge;
  const AddEdge(this.edge);
}

class RemoveEdge extends Op {
  final String id;
  const RemoveEdge(this.id);
}

/// Why an op was refused. [staleBased] reasons are certain to repeat on the server.
class RejectReason implements Exception {
  final String kind; // conflict, nodeDeleted, nodeNotFound, nodeExists, edgeNotFound, ...
  final String detail;
  final int? conflictSeq;
  final String? conflictBy;
  const RejectReason(this.kind, [this.detail = '', this.conflictSeq, this.conflictBy]);
  bool get staleBased => kind == 'conflict' || kind == 'nodeDeleted' || kind == 'danglingReference';
  @override
  String toString() => 'RejectReason($kind $detail)';
}

class Document {
  final Map<String, Node> nodes = {};
  final Map<String, Edge> edges = {};
  final Map<String, Stamp> deletedNodes = {};
  final Map<String, Stamp> deletedEdges = {};
  final Map<String, Map<String, (FieldKey, Stamp)>> _fieldStamps = {};
  final Map<String, Map<String, int>> _touches = {};

  Document([Iterable<Node> initialNodes = const []]) {
    for (final n in initialNodes) {
      nodes[n.id] = n;
    }
  }

  Document clone() {
    final d = Document();
    nodes.forEach((k, v) => d.nodes[k] = v.copy());
    d.edges.addAll(edges);
    d.deletedNodes.addAll(deletedNodes);
    d.deletedEdges.addAll(deletedEdges);
    _fieldStamps.forEach((k, v) => d._fieldStamps[k] = Map.of(v));
    _touches.forEach((k, v) => d._touches[k] = Map.of(v));
    return d;
  }

  List<String> get integrityProblems {
    final out = <String>[];
    for (final n in nodes.values) {
      for (final v in n.config.values) {
        for (final r in liveRefs(v)) {
          if (!nodes.containsKey(r.node)) out.add('${n.id} has dangling ref to ${r.node}');
        }
      }
    }
    for (final e in edges.values) {
      if (!nodes.containsKey(e.source) || !nodes.containsKey(e.target)) out.add('edge ${e.id} missing endpoint');
    }
    return out;
  }

  /// Throws [RejectReason]. Stale-write rule: refuse if another client wrote an overlapping field
  /// after [base]. Delete also conflicts with unseen writes to the node or to fields it would rewrite.
  void validate(Op op, {required int base, required String by, bool checkConflicts = true}) {
    switch (op) {
      case AddNode(:final node):
        if (node.id.isEmpty) throw const RejectReason('invalid', 'empty node id');
        if (nodes.containsKey(node.id) || deletedNodes.containsKey(node.id)) throw RejectReason('nodeExists', node.id);
        for (final v in node.config.values) {
          _checkValue(v, selfNode: node.id);
        }
      case RemoveNode(:final id):
        _requireLive(id);
        if (checkConflicts) {
          final c = _nodeConflict(id, base, by);
          if (c != null) throw c;
          for (final other in nodes.keys.toList()..sort()) {
            if (other == id) continue;
            final cfg = deepCopy(nodes[other]!.config) as Map<String, Object?>;
            for (final path in breakRefs(cfg, id)) {
              final c2 = _fieldConflict(other, FieldKey.config(path), base, by);
              if (c2 != null) throw c2;
            }
          }
        }
      case MoveNode(:final id):
        _requireLive(id);
        if (checkConflicts) {
          final c = _fieldConflict(id, const FieldKey.position(), base, by);
          if (c != null) throw c;
        }
      case SetField(:final id, :final key, :final value):
        _requireLive(id);
        switch (key.kind) {
          case 'position':
            throw const RejectReason('invalid', 'position is written with moveNode');
          case 'title':
            if (value is! String) throw const RejectReason('invalid', 'title must be a string');
          default:
            if (!canSet(nodes[id]!.config, key.path)) throw RejectReason('invalid', 'bad path ${key.path}');
            _checkValue(value);
        }
        if (checkConflicts) {
          final c = _fieldConflict(id, key, base, by);
          if (c != null) throw c;
        }
      case AddEdge(:final edge):
        if (edges.containsKey(edge.id) || deletedEdges.containsKey(edge.id)) throw RejectReason('edgeExists', edge.id);
        _requireLive(edge.source);
        _requireLive(edge.target);
        for (final o in edges.values) {
          if (o.source == edge.source &&
              o.sourceHandle == edge.sourceHandle &&
              o.target == edge.target &&
              o.targetHandle == edge.targetHandle) {
            throw RejectReason('duplicateEdge', o.id);
          }
        }
      case RemoveEdge(:final id):
        if (!edges.containsKey(id)) throw RejectReason('edgeNotFound', id);
    }
  }

  void _requireLive(String id) {
    if (nodes.containsKey(id)) return;
    throw RejectReason(deletedNodes.containsKey(id) ? 'nodeDeleted' : 'nodeNotFound', id);
  }

  void _checkValue(Object? v, {String? selfNode}) {
    if (containsBroken(v)) throw const RejectReason('invalid', 'brokenRef is server-written only');
    for (final r in liveRefs(v)) {
      if (!nodes.containsKey(r.node) && r.node != selfNode) throw RejectReason('danglingReference', r.node);
    }
  }

  RejectReason? _fieldConflict(String node, FieldKey field, int base, String client) {
    RejectReason? worst;
    for (final (k, s) in (_fieldStamps[node] ?? {}).values) {
      if (k.overlaps(field) && s.seq > base && s.client != client && (worst == null || s.seq > worst.conflictSeq!)) {
        worst = RejectReason('conflict', '$node ${k.id}', s.seq, s.client);
      }
    }
    return worst;
  }

  RejectReason? _nodeConflict(String node, int base, String client) {
    RejectReason? worst;
    (_touches[node] ?? {}).forEach((c, seq) {
      if (c != client && seq > base && (worst == null || seq > worst!.conflictSeq!)) {
        worst = RejectReason('conflict', '$node (whole)', seq, c);
      }
    });
    return worst;
  }

  /// Applies a validated op; ignores invalid input instead of throwing (clients feed it committed entries).
  void apply(Op op, Stamp stamp, {bool breakMarkers = true}) {
    switch (op) {
      case AddNode(:final node):
        if (nodes.containsKey(node.id) || deletedNodes.containsKey(node.id)) return;
        nodes[node.id] = node.copy();
        _touch(node.id, stamp);
      case RemoveNode(:final id):
        if (!nodes.containsKey(id)) return;
        nodes.remove(id);
        _fieldStamps.remove(id);
        _touches.remove(id);
        deletedNodes[id] = stamp;
        for (final eid in edges.keys.toList()..sort()) {
          if (edges[eid]!.source == id || edges[eid]!.target == id) {
            edges.remove(eid);
            deletedEdges[eid] = stamp;
          }
        }
        if (breakMarkers) {
          for (final other in nodes.keys.toList()..sort()) {
            final changed = breakRefs(nodes[other]!.config, id);
            if (changed.isEmpty) continue;
            for (final p in changed) {
              _stamp(other, FieldKey.config(p), stamp);
            }
            _touch(other, stamp);
          }
        }
      case MoveNode(:final id, :final x, :final y):
        final n = nodes[id];
        if (n == null) return;
        n.x = x;
        n.y = y;
        _stamp(id, const FieldKey.position(), stamp);
        _touch(id, stamp);
      case SetField(:final id, :final key, :final value):
        final n = nodes[id];
        if (n == null) return;
        if (key.kind == 'title' && value is String) {
          n.title = value;
        } else if (key.kind == 'config' && canSet(n.config, key.path)) {
          setPath(n.config, key.path, deepCopy(value));
        } else {
          return;
        }
        _stamp(id, key, stamp);
        _touch(id, stamp);
      case AddEdge(:final edge):
        if (edges.containsKey(edge.id) || deletedEdges.containsKey(edge.id)) return;
        if (!nodes.containsKey(edge.source) || !nodes.containsKey(edge.target)) return;
        edges[edge.id] = edge;
        _touch(edge.source, stamp);
        _touch(edge.target, stamp);
      case RemoveEdge(:final id):
        if (edges.remove(id) != null) deletedEdges[id] = stamp;
    }
  }

  void _touch(String node, Stamp s) => (_touches[node] ??= {})[s.client] = s.seq;

  void _stamp(String node, FieldKey key, Stamp s) {
    final m = _fieldStamps[node] ??= {};
    if (key.kind == 'config') {
      m.removeWhere((_, e) =>
          e.$1.kind == 'config' &&
          e.$1.path.length > key.path.length &&
          List.generate(key.path.length, (i) => e.$1.path[i] == key.path[i]).every((x) => x));
    }
    m[key.id] = (key, s);
  }

  @override
  bool operator ==(Object o) =>
      o is Document &&
      _mapEq(nodes, o.nodes) &&
      _mapEq(edges, o.edges) &&
      deletedNodes.keys.toSet().difference(o.deletedNodes.keys.toSet()).isEmpty &&
      deletedNodes.length == o.deletedNodes.length;
  @override
  int get hashCode => nodes.length;
}

bool _mapEq<V>(Map<String, V> a, Map<String, V> b) =>
    a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);
