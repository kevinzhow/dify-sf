import 'package:collection/collection.dart';

import 'ops.dart';
import 'value.dart';

/// The workflow graph plus the version metadata needed to enforce the conflict rules.
///
/// Server and clients run the *same* [validate]/[apply] code, so a committed op has the same effect
/// everywhere (including cascades), and convergence is plain structural equality ([==]).
///
/// Conflict policy (docs/protocol.md section 6):
/// - content registers (title, config paths, list items, node/edge existence) are stale-write protected;
/// - a stale write whose value equals the current value is a success and a no-op (same-value rule);
/// - layout ([MoveNode]) is last-writer-wins in server order and is never rejected for staleness.
///
/// A [Document] is mutable through [apply] only. Elements ([Node], [Edge], [Value], [Stamp]) are immutable,
/// so [clone] is a cheap shallow copy.
class Document {
  Document({Iterable<Node> nodes = const [], Iterable<Edge> edges = const []})
    : nodes = {for (final n in nodes) n.id: n},
      edges = {for (final e in edges) e.id: e},
      deletedNodes = {},
      deletedEdges = {},
      deletedItems = {},
      fieldStamps = {},
      touches = {};

  Document._(
    this.nodes,
    this.edges,
    this.deletedNodes,
    this.deletedEdges,
    this.deletedItems,
    this.fieldStamps,
    this.touches,
  );

  factory Document.fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw FormatException('bad document: $json');
    List<Object?> list(String key) => json[key] is List<Object?> ? json[key]! as List<Object?> : const [];
    Map<String, Stamp> stamps(String key) {
      final raw = json[key];
      if (raw == null) return {};
      if (raw is! Map<String, Object?>) throw FormatException('bad $key');
      return {for (final e in raw.entries) e.key: Stamp.fromJson(e.value)};
    }

    final fieldStamps = <String, Map<FieldKey, Stamp>>{};
    for (final row in list('fieldStamps')) {
      final m = row! as Map<String, Object?>;
      (fieldStamps[m['node']! as String] ??= {})[FieldKey.fromJson(m['field'])] = Stamp.fromJson(m);
    }
    final touches = <String, Map<String, int>>{};
    for (final row in list('touches')) {
      final m = row! as Map<String, Object?>;
      (touches[m['node']! as String] ??= {})[m['client']! as String] = m['seq']! as int;
    }
    return Document._(
      {for (final n in list('nodes').map(Node.fromJson)) n.id: n},
      {for (final e in list('edges').map(Edge.fromJson)) e.id: e},
      stamps('deletedNodes'),
      stamps('deletedEdges'),
      stamps('deletedItems'),
      fieldStamps,
      touches,
    );
  }

  final Map<String, Node> nodes;
  final Map<String, Edge> edges;

  /// Tombstones. Ids are never reused, so an edit to a deleted node is always recognisable.
  final Map<String, Stamp> deletedNodes;
  final Map<String, Stamp> deletedEdges;
  final Map<String, Stamp> deletedItems;

  /// Last write per content register. Inner maps are treated as immutable (replaced, never mutated), which
  /// is what makes [clone] cheap.
  final Map<String, Map<FieldKey, Stamp>> fieldStamps;

  /// Last seq at which each client changed a node's content in any way (used for delete-vs-edit).
  final Map<String, Map<String, int>> touches;

  Document clone() => Document._(
    Map.of(nodes),
    Map.of(edges),
    Map.of(deletedNodes),
    Map.of(deletedEdges),
    Map.of(deletedItems),
    Map.of(fieldStamps),
    Map.of(touches),
  );

  /// Canonical JSON (sorted), identical to the server's snapshot encoding.
  Map<String, Object?> toJson() {
    final stampRows = <Map<String, Object?>>[];
    for (final n in fieldStamps.keys.toList()..sort()) {
      final entries = fieldStamps[n]!.entries.toList()..sort((a, b) => _keyOrder(a.key).compareTo(_keyOrder(b.key)));
      for (final e in entries) {
        stampRows.add({'node': n, 'field': e.key.toJson(), 'seq': e.value.seq, 'client': e.value.client});
      }
    }
    final touchRows = <Map<String, Object?>>[];
    for (final n in touches.keys.toList()..sort()) {
      for (final c in touches[n]!.keys.toList()..sort()) {
        touchRows.add({'node': n, 'client': c, 'seq': touches[n]![c]});
      }
    }
    Map<String, Object?> stamps(Map<String, Stamp> m) => {
      for (final k in m.keys.toList()..sort()) k: m[k]!.toJson(),
    };
    return {
      'nodes': [for (final k in nodes.keys.toList()..sort()) nodes[k]!.toJson()],
      'edges': [for (final k in edges.keys.toList()..sort()) edges[k]!.toJson()],
      'deletedNodes': stamps(deletedNodes),
      'deletedEdges': stamps(deletedEdges),
      'deletedItems': stamps(deletedItems),
      'fieldStamps': stampRows,
      'touches': touchRows,
    };
  }

  static String _keyOrder(FieldKey k) => switch (k) {
    TitleKey() => '0',
    ConfigKey(:final path) => '1/${path.join('\u0001')}',
    ItemKey(:final path, :final id) => '2/${path.join('\u0001')}\u0002$id',
  };

  @override
  bool operator ==(Object other) {
    if (other is! Document) return false;
    const deepStamps = MapEquality<String, Stamp>();
    return const MapEquality<String, Node>().equals(nodes, other.nodes) &&
        const MapEquality<String, Edge>().equals(edges, other.edges) &&
        deepStamps.equals(deletedNodes, other.deletedNodes) &&
        deepStamps.equals(deletedEdges, other.deletedEdges) &&
        deepStamps.equals(deletedItems, other.deletedItems) &&
        const MapEquality<String, Map<FieldKey, Stamp>>(values: MapEquality<FieldKey, Stamp>())
            .equals(fieldStamps, other.fieldStamps) &&
        const MapEquality<String, Map<String, int>>(values: MapEquality<String, int>()).equals(touches, other.touches);
  }

  @override
  int get hashCode => Object.hash(nodes.length, edges.length, deletedNodes.length, fieldStamps.length);

  // ---- queries -----------------------------------------------------------------------------------

  /// The config key of a node's declared outputs (protocol 1.4).
  static const outputsKey = 'outputs';

  /// A node's declared outputs: the names of the items of its `outputs` keyed list (an item's `name`, or its id when it
  /// has none), or null if it has no such list (then any output name is accepted, e.g. the fixed outputs of an LLM
  /// node). References to a node with declared outputs must name one of them.
  static Set<String>? declaredOutputs(Node node) => switch (node.config[outputsKey]) {
    VItems(:final items) => {for (final i in items) _outputName(i)},
    _ => null,
  };

  static String _outputName(Item i) => switch (i.value) {
    VMap(:final entries) when entries['name'] is VString => (entries['name']! as VString).value,
    _ => i.id,
  };

  /// The output name that [op] takes away from its node (removing or renaming an output item), if no other item of
  /// the list still declares it. References to that name break, like references to a deleted node.
  ({String node, String name})? _outputNameRemoved(Op op) {
    final (String node, String itemId, Value? newValue) = switch (op) {
      RemoveItem(:final node, :final path, :final itemId) when _isOutputs(path) => (node, itemId, null),
      UpdateItem(:final node, :final path, :final itemId, :final value) when _isOutputs(path) => (node, itemId, value),
      _ => ('', '', null),
    };
    if (node.isEmpty) return null;
    final n = nodes[node];
    if (n == null) return null;
    if (n.config[outputsKey] case VItems(:final items)) {
      final at = items.indexWhere((i) => i.id == itemId);
      if (at < 0) return null;
      final old = _outputName(items[at]);
      if (newValue != null && _outputName(Item(itemId, newValue)) == old) return null;
      if (items.any((i) => i.id != itemId && _outputName(i) == old)) return null;
      return (node: node, name: old);
    }
    return null;
  }

  static bool _isOutputs(List<String> path) => path.length == 1 && path[0] == outputsKey;

  /// Human-readable integrity problems: dangling live refs (to a missing node or a missing declared output), edges to
  /// missing nodes (invariant I4).
  List<String> get integrityProblems {
    final problems = <String>[];
    for (final id in nodes.keys.toList()..sort()) {
      final cfg = nodes[id]!.config;
      for (final key in cfg.keys.toList()..sort()) {
        for (final r in cfg[key]!.liveRefs) {
          final target = nodes[r.node];
          if (target == null) {
            problems.add('node $id.$key has dangling ref to ${r.node}');
          } else if (declaredOutputs(target) case final outs? when !outs.contains(r.output)) {
            problems.add('node $id.$key has dangling ref to ${r.node}.${r.output} (no such output)');
          }
        }
      }
    }
    for (final id in edges.keys.toList()..sort()) {
      final e = edges[id]!;
      if (!nodes.containsKey(e.source) || !nodes.containsKey(e.target)) problems.add('edge $id has missing endpoint');
    }
    return problems;
  }

  /// Every config location (config path or item) holding a live or broken reference to [node].
  /// Used by the UI to explain what deleting a node will break.
  List<({String node, FieldKey field, OutputRef ref, bool broken})> referencesTo(String node) {
    final out = <({String node, FieldKey field, OutputRef ref, bool broken})>[];
    void walk(String owner, List<String> path, Value v) {
      switch (v) {
        case VRef(:final ref) when ref.node == node:
          out.add((node: owner, field: ConfigKey(path), ref: ref, broken: false));
        case VBroken(:final ref) when ref.node == node:
          out.add((node: owner, field: ConfigKey(path), ref: ref, broken: true));
        case VMap(:final entries):
          for (final k in entries.keys.toList()..sort()) {
            walk(owner, [...path, k], entries[k]!);
          }
        case VList(:final items):
          for (final i in items) {
            walk(owner, path, i);
          }
        case VItems(:final items):
          for (final i in items) {
            final before = out.length;
            walk(owner, path, i.value);
            for (var j = before; j < out.length; j++) {
              out[j] = (node: owner, field: ItemKey(path, i.id), ref: out[j].ref, broken: out[j].broken);
            }
          }
        default:
          break;
      }
    }

    for (final id in nodes.keys.toList()..sort()) {
      if (id == node) continue;
      for (final e in nodes[id]!.config.entries) {
        walk(id, [e.key], e.value);
      }
    }
    return out;
  }

  // ---- validation --------------------------------------------------------------------------------

  /// Decides whether [op], created by [client] against server version [base], may be applied now.
  /// Returns null when valid, otherwise the reason it must be rejected.
  ///
  /// Stale-write rule: a write to a content register is refused if another client wrote an overlapping
  /// register after [base] AND the new value differs from the current one. Writing the value that is already
  /// there is a success (no-op) even on a stale base. Writes by the same client never conflict with
  /// themselves. Deleting a node conflicts with any content modification of that node by someone else after
  /// [base], and with any such write to a field that references it.
  ///
  /// [checkConflicts] false is used by clients replaying committed entries (the server already decided).
  RejectReason? validate(Op op, {required int base, required String client, bool checkConflicts = true}) {
    switch (op) {
      case AddNode(:final node):
        if (node.id.isEmpty) return const Invalid('empty node id');
        if (nodes.containsKey(node.id) || deletedNodes.containsKey(node.id)) return NodeExists(node.id);
        for (final key in node.config.keys.toList()..sort()) {
          if (key.startsWith(r'$')) return Invalid('config key $key is reserved');
          final bad = _checkValue(node.config[key]!, selfNode: node.id);
          if (bad != null) return bad;
        }
        return null;

      case RemoveNode(:final node):
        final dead = _requireLive(node);
        if (dead != null) return dead;
        if (checkConflicts) {
          final c = _nodeConflict(node, base, client);
          if (c != null) return c;
          // The delete also rewrites every field that references this node (ref -> broken). Those are
          // writes too: refuse if someone else wrote one of them after `base`.
          for (final other in nodes.keys.toList()..sort()) {
            if (other == node) continue;
            for (final key in _breakRefs(nodes[other]!.config, node).changed) {
              final c = _fieldConflict(other, key, base, client);
              if (c != null) return c;
            }
          }
        }
        return null;

      case MoveNode(:final node):
        return _requireLive(node);

      case SetField(:final node, :final field, :final value):
        final dead = _requireLive(node);
        if (dead != null) return dead;
        final Value? current;
        switch (field) {
          case ItemKey():
            return const Invalid('list items are written with the item ops');
          case TitleKey():
            if (value is! VString) return const Invalid('title must be a string');
            current = VString(nodes[node]!.title);
          case ConfigKey(:final path):
            if (!ConfigTree.canSet(nodes[node]!.config, path)) return Invalid('bad path $path');
            if (path.any((p) => p.startsWith(r'$'))) return const Invalid('reserved key in path');
            final bad = _checkValue(value, selfNode: null);
            if (bad != null) return bad;
            current = ConfigTree.get(nodes[node]!.config, path);
        }
        return _checkStale(node, field, base, client, sameValue: current == value, enabled: checkConflicts);

      case AddEdge(:final edge):
        if (edge.id.isEmpty) return const Invalid('empty edge id');
        if (edges.containsKey(edge.id) || deletedEdges.containsKey(edge.id)) return EdgeExists(edge.id);
        final a = _requireLive(edge.source) ?? _requireLive(edge.target);
        if (a != null) return a;
        for (final other in edges.values) {
          if (other.sameConnection(edge)) return DuplicateEdge(other.id);
        }
        return null;

      case RemoveEdge(:final edge):
        return edges.containsKey(edge) ? null : EdgeNotFound(edge);

      case InsertItem(:final node, :final path, :final item):
        final dead = _requireLive(node);
        if (dead != null) return dead;
        if (path.isEmpty || !ConfigTree.canSet(nodes[node]!.config, path) || path.any((p) => p.startsWith(r'$'))) {
          return Invalid('bad list path $path');
        }
        if (item.id.isEmpty) return const Invalid('empty item id');
        switch (ConfigTree.list(nodes[node]!.config, path)) {
          case ListNotAList():
            return Invalid('$path is not a keyed list');
          case ListFound(:final items):
            if (items.any((i) => i.id == item.id)) return ItemExists(item.id);
          case ListAbsent():
            break;
        }
        if (deletedItems.containsKey(item.id)) return ItemExists(item.id);
        return _checkValue(item.value, selfNode: null);

      case RemoveItem(:final node, :final path, :final itemId):
        final dead = _requireLive(node);
        if (dead != null) return dead;
        final state = _lookupItem(node, path, itemId);
        return switch (state) {
          _ItemTombstoned() => null, // already gone: the intended end state holds (same-value rule)
          _ItemMissing(:final reason) => reason,
          _ItemPresent() =>
            checkConflicts
                ? (_fieldConflict(node, ItemKey(path, itemId), base, client) ??
                      _outputRemovalConflict(op, base, client))
                : null,
        };

      case UpdateItem(:final node, :final path, :final itemId, :final value):
        final dead = _requireLive(node);
        if (dead != null) return dead;
        switch (_lookupItem(node, path, itemId)) {
          case _ItemMissing(:final reason):
            return reason;
          case _ItemTombstoned():
            return ItemDeleted(itemId);
          case _ItemPresent(value: final existing):
            final bad = _checkValue(value, selfNode: null);
            if (bad != null) return bad;
            return _checkStale(
                  node,
                  ItemKey(path, itemId),
                  base,
                  client,
                  sameValue: existing == value,
                  enabled: checkConflicts,
                ) ??
                (checkConflicts ? _outputRemovalConflict(op, base, client) : null); // renaming an output
        }

      case RestoreNode(:final node, :final edges):
        return _validateRestore(node, edges, base, client, checkConflicts);
    }
  }

  /// Protocol 1.6 [RestoreNode] (undo of a delete). Undo is only of one's own operations: only the client whose delete
  /// made the tombstone may restore the node ([NotDeleter] otherwise, also when replaying committed entries). Like a
  /// delete, the restore rewrites fields of other nodes (broken -> ref); it conflicts with any other client's write,
  /// after [base], to one of those fields. Only a malformed edge list is refused: an edge that cannot come back is
  /// skipped by [apply].
  RejectReason? _validateRestore(Node n, List<Edge> restoredEdges, int base, String client, bool checkConflicts) {
    if (n.id.isEmpty) return const Invalid('empty node id');
    if (nodes.containsKey(n.id)) return NodeExists(n.id);
    final tomb = deletedNodes[n.id];
    if (tomb == null) return NodeNotFound(n.id);
    if (tomb.client != client) return NotDeleter(n.id, tomb.client);
    for (final key in n.config.keys.toList()..sort()) {
      if (key.startsWith(r'$')) return Invalid('config key $key is reserved');
      // Broken markers are allowed here (the node comes back as it was); references are normalised when applied.
      final problem = n.config[key]!.structuralProblem;
      if (problem != null) return Invalid(problem);
    }
    final ids = <String>{};
    for (final e in restoredEdges) {
      if (e.id.isEmpty) return const Invalid('empty edge id');
      if (!ids.add(e.id)) return Invalid('edge ${e.id} listed twice');
      if (e.source != n.id && e.target != n.id) return Invalid('edge ${e.id} does not touch node ${n.id}');
    }
    if (!checkConflicts) return null;
    final accepts = _acceptsOutput(n);
    for (final other in nodes.keys.toList()..sort()) {
      for (final key in _reviveRefsWhere(nodes[other]!.config, (r) => r.node == n.id && accepts(r.output)).changed) {
        final c = _fieldConflict(other, key, base, client);
        if (c != null) return c;
      }
    }
    return null;
  }

  /// Whether [node] can be referenced by output name: it declares it, or declares no outputs at all.
  static bool Function(String) _acceptsOutput(Node node) {
    final outs = declaredOutputs(node);
    return outs == null ? (_) => true : outs.contains;
  }

  /// Restore: the node comes back with its references normalised (live iff the target exists and declares the output);
  /// each listed edge comes back iff this delete removed it (same tombstone), both endpoints exist and no live edge has
  /// the same connection, otherwise it stays deleted; broken references to the node in other nodes whose output it
  /// declares become live again. The restore counts as a content write of the whole node (title + the whole config) by
  /// its author, so writes based on a version before it are stale.
  void _applyRestore(Node n, List<Edge> restoredEdges, Stamp stamp) {
    final tomb = deletedNodes[n.id];
    if (nodes.containsKey(n.id) || tomb == null) return;
    final accepts = _acceptsOutput(n);
    final config = <String, Value>{
      for (final e in n.config.entries)
        e.key: e.value.normalizingRefs((r, _) {
          if (r.node == n.id) return accepts(r.output);
          final target = nodes[r.node];
          return target != null && _acceptsOutput(target)(r.output);
        }),
    };
    deletedNodes.remove(n.id);
    nodes[n.id] = n.copyWith(config: Map.unmodifiable(config));
    _stampField(n.id, const TitleKey(), stamp);
    _stampField(n.id, const ConfigKey([]), stamp); // the empty path overlaps every config path and list item
    _touch(n.id, stamp);
    for (final e in restoredEdges) {
      if (e.source != n.id && e.target != n.id) continue;
      if (edges.containsKey(e.id) || deletedEdges[e.id] != tomb) continue;
      if (!nodes.containsKey(e.source) || !nodes.containsKey(e.target)) continue; // other endpoint deleted: skipped
      if (edges.values.any((o) => o.sameConnection(e))) continue;
      edges[e.id] = e;
      deletedEdges.remove(e.id);
      _touch(e.source, stamp);
      _touch(e.target, stamp);
    }
    for (final other in nodes.keys.toList()..sort()) {
      if (other == n.id) continue;
      final r = _reviveRefsWhere(nodes[other]!.config, (x) => x.node == n.id && accepts(x.output));
      if (r.changed.isEmpty) continue;
      nodes[other] = nodes[other]!.copyWith(config: r.config);
      for (final key in r.changed) {
        _stampField(other, key, stamp);
      }
      _touch(other, stamp);
    }
  }

  void _breakOutputRefs(({String node, String name})? removed, Stamp stamp) {
    if (removed == null) return;
    for (final other in nodes.keys.toList()..sort()) {
      final r = _breakRefsWhere(nodes[other]!.config, (x) => x.node == removed.node && x.output == removed.name);
      if (r.changed.isEmpty) continue;
      nodes[other] = nodes[other]!.copyWith(config: r.config);
      for (final key in r.changed) {
        _stampField(other, key, stamp);
      }
      _touch(other, stamp);
    }
  }

  _ItemState _lookupItem(String node, List<String> path, String id) {
    if (ConfigTree.list(nodes[node]!.config, path) case ListFound(:final items)) {
      final hit = items.firstWhereOrNull((i) => i.id == id);
      if (hit != null) return _ItemPresent(hit.value);
    }
    if (deletedItems.containsKey(id)) return const _ItemTombstoned();
    return _ItemMissing(ItemNotFound(id));
  }

  RejectReason? _checkStale(
    String node,
    FieldKey key,
    int base,
    String client, {
    required bool sameValue,
    required bool enabled,
  }) {
    if (!enabled) return null;
    final c = _fieldConflict(node, key, base, client);
    if (c == null || sameValue) return null;
    return c;
  }

  RejectReason? _requireLive(String id) {
    if (nodes.containsKey(id)) return null;
    return deletedNodes.containsKey(id) ? NodeDeleted(id) : NodeNotFound(id);
  }

  /// Removing a declared output rewrites every field that references it (ref -> brokenRef); like a node delete, it
  /// conflicts with someone else's write to one of those fields after [base].
  Conflict? _outputRemovalConflict(Op op, int base, String client) {
    final removed = _outputNameRemoved(op);
    if (removed == null) return null;
    for (final other in nodes.keys.toList()..sort()) {
      for (final key in _breakRefsWhere(
        nodes[other]!.config,
        (r) => r.node == removed.node && r.output == removed.name,
      ).changed) {
        final c = _fieldConflict(other, key, base, client);
        if (c != null) return c;
      }
    }
    return null;
  }

  /// Clients may only write live refs to existing nodes and existing declared outputs; broken markers are server-only.
  RejectReason? _checkValue(Value v, {required String? selfNode}) {
    final problem = v.structuralProblem;
    if (problem != null) return Invalid(problem);
    if (v.containsBrokenRef) return const Invalid('brokenRef is server-written only');
    for (final r in v.liveRefs) {
      if (r.node == selfNode) continue;
      final target = nodes[r.node];
      if (target == null) return DanglingReference(r.node);
      if (declaredOutputs(target) case final outs? when !outs.contains(r.output)) return DanglingReference(r.node);
    }
    return null;
  }

  Conflict? _fieldConflict(String node, FieldKey field, int base, String client) {
    Conflict? worst;
    final stamps = fieldStamps[node];
    if (stamps == null) return null;
    for (final MapEntry(key: k, value: s) in stamps.entries) {
      if (s.seq > base && s.client != client && k.overlaps(field)) {
        if (worst == null || s.seq > worst.seq) worst = Conflict(node: node, field: k, seq: s.seq, by: s.client);
      }
    }
    return worst;
  }

  Conflict? _nodeConflict(String node, int base, String client) {
    Conflict? worst;
    final t = touches[node];
    if (t == null) return null;
    for (final MapEntry(key: c, value: seq) in t.entries) {
      if (c != client && seq > base && (worst == null || seq > worst.seq)) {
        worst = Conflict(node: node, field: null, seq: seq, by: c);
      }
    }
    return worst;
  }

  // ---- apply -------------------------------------------------------------------------------------

  /// Applies a validated op. Never throws on invalid input (it just ignores it) because clients feed it with
  /// server-committed entries; callers that care re-validate first.
  void apply(Op op, Stamp stamp) {
    switch (op) {
      case AddNode(:final node):
        if (nodes.containsKey(node.id) || deletedNodes.containsKey(node.id)) return;
        nodes[node.id] = node;
        _touch(node.id, stamp);

      case RemoveNode(:final node):
        if (!nodes.containsKey(node)) return;
        nodes.remove(node);
        fieldStamps.remove(node);
        touches.remove(node);
        deletedNodes[node] = stamp;
        for (final eid in edges.keys.toList()..sort()) {
          final e = edges[eid]!;
          if (e.source == node || e.target == node) {
            edges.remove(eid);
            deletedEdges[eid] = stamp;
          }
        }
        for (final other in nodes.keys.toList()..sort()) {
          final r = _breakRefs(nodes[other]!.config, node);
          if (r.changed.isEmpty) continue;
          nodes[other] = nodes[other]!.copyWith(config: r.config);
          for (final key in r.changed) {
            _stampField(other, key, stamp);
          }
          _touch(other, stamp);
        }

      case MoveNode(:final node, :final x, :final y):
        // Layout is last-writer-wins: no stamp, no touch (a drag never blocks someone's delete).
        final n = nodes[node];
        if (n == null) return;
        nodes[node] = n.copyWith(x: x, y: y);

      case SetField(:final node, :final field, :final value):
        final n = nodes[node];
        if (n == null) return;
        switch (field) {
          case ItemKey():
            return;
          case TitleKey():
            if (value is! VString || n.title == value.value) return; // same value: no-op
            nodes[node] = n.copyWith(title: value.value);
          case ConfigKey(:final path):
            if (!ConfigTree.canSet(n.config, path)) return;
            if (ConfigTree.get(n.config, path) == value) return; // same value: no-op
            nodes[node] = n.copyWith(config: ConfigTree.set(n.config, path, value));
        }
        _stampField(node, field, stamp);
        _touch(node, stamp);

      case AddEdge(:final edge):
        if (edges.containsKey(edge.id) ||
            deletedEdges.containsKey(edge.id) ||
            !nodes.containsKey(edge.source) ||
            !nodes.containsKey(edge.target)) {
          return;
        }
        edges[edge.id] = edge;
        _touch(edge.source, stamp);
        _touch(edge.target, stamp);

      case RemoveEdge(:final edge):
        if (edges.remove(edge) == null) return;
        deletedEdges[edge] = stamp;

      case InsertItem(:final node, :final path, :final item, :final after):
        final n = nodes[node];
        if (n == null || !ConfigTree.canSet(n.config, path) || deletedItems.containsKey(item.id)) return;
        final List<Item> items;
        switch (ConfigTree.list(n.config, path)) {
          case ListNotAList():
            return;
          case ListAbsent():
            items = [];
          case ListFound(items: final xs):
            items = List.of(xs);
        }
        if (items.any((i) => i.id == item.id)) return;
        // Anchor gone (concurrently removed) => append. Deterministic: every replica applies in server order.
        final int at;
        if (after == null) {
          at = 0;
        } else {
          final idx = items.indexWhere((i) => i.id == after);
          at = idx < 0 ? items.length : idx + 1;
        }
        items.insert(at, item);
        nodes[node] = n.copyWith(config: ConfigTree.set(n.config, path, VItems(List.unmodifiable(items))));
        _stampField(node, ItemKey(path, item.id), stamp);
        _touch(node, stamp);

      case RemoveItem(:final node, :final path, :final itemId):
        final n = nodes[node];
        if (n == null) return;
        if (ConfigTree.list(n.config, path) case ListFound(:final items)) {
          final at = items.indexWhere((i) => i.id == itemId);
          if (at < 0) return;
          final removed = _outputNameRemoved(op);
          final next = List.of(items)..removeAt(at);
          nodes[node] = n.copyWith(config: ConfigTree.set(n.config, path, VItems(List.unmodifiable(next))));
          deletedItems[itemId] = stamp;
          _stampField(node, ItemKey(path, itemId), stamp);
          _touch(node, stamp);
          _breakOutputRefs(removed, stamp);
        }

      case UpdateItem(:final node, :final path, :final itemId, :final value):
        final n = nodes[node];
        if (n == null) return;
        if (ConfigTree.list(n.config, path) case ListFound(:final items)) {
          final at = items.indexWhere((i) => i.id == itemId);
          if (at < 0 || items[at].value == value) return;
          final removed = _outputNameRemoved(op);
          final next = List.of(items)..[at] = Item(itemId, value);
          nodes[node] = n.copyWith(config: ConfigTree.set(n.config, path, VItems(List.unmodifiable(next))));
          _stampField(node, ItemKey(path, itemId), stamp);
          _touch(node, stamp);
          _breakOutputRefs(removed, stamp);
        }

      case RestoreNode(:final node, :final edges):
        _applyRestore(node, edges, stamp);
    }
  }

  void _touch(String node, Stamp stamp) {
    final t = Map.of(touches[node] ?? const <String, int>{});
    t[stamp.client] = stamp.seq;
    touches[node] = t;
  }

  void _stampField(String node, FieldKey key, Stamp stamp) {
    final stamps = Map.of(fieldStamps[node] ?? const <FieldKey, Stamp>{});
    if (key is ConfigKey) {
      // Rewriting an ancestor subsumes (and makes redundant) the stamps of its descendants.
      final path = key.path;
      stamps.removeWhere(
        (k, _) => switch (k) {
          ConfigKey(path: final q) => q.length > path.length && _hasPrefix(q, path),
          ItemKey(path: final q) => q.length >= path.length && _hasPrefix(q, path),
          TitleKey() => false,
        },
      );
    }
    stamps[key] = stamp;
    fieldStamps[node] = stamps;
  }

  static bool _hasPrefix(List<String> list, List<String> prefix) {
    if (list.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (list[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Marks every reference to [node] as broken. Returns the new config and the registers that changed
  /// (nearest map-key path for atomic values; `(list path, item id)` for keyed lists) so the caller can
  /// version them.
  static ({Map<String, Value> config, List<FieldKey> changed}) _breakRefs(
    Map<String, Value> cfg,
    String node, [
    List<String> prefix = const [],
  ]) => _breakRefsWhere(cfg, (r) => r.node == node, prefix);

  /// Like [_breakRefs] for every reference that [matches] (protocol 1.4: a removed declared output).
  static ({Map<String, Value> config, List<FieldKey> changed}) _breakRefsWhere(
    Map<String, Value> cfg,
    bool Function(OutputRef) matches, [
    List<String> prefix = const [],
  ]) => _rewrite(cfg, prefix, (v) => v.hasRefWhere(matches), (v) => v.breakingRefsWhere(matches));

  /// Turns every broken marker that [matches] back into a live reference (protocol 1.6, restoring a node).
  static ({Map<String, Value> config, List<FieldKey> changed}) _reviveRefsWhere(
    Map<String, Value> cfg,
    bool Function(OutputRef) matches, [
    List<String> prefix = const [],
  ]) => _rewrite(cfg, prefix, (v) => v.hasBrokenRefWhere(matches), (v) => v.revivingRefsWhere(matches));

  /// Applies [transform] to every register (nearest map-key path for atomic values, `(list path, item id)` for items of
  /// keyed lists) whose value [affects] holds for; returns the new config and those registers.
  static ({Map<String, Value> config, List<FieldKey> changed}) _rewrite(
    Map<String, Value> cfg,
    List<String> prefix,
    bool Function(Value) affects,
    Value Function(Value) transform,
  ) {
    final changed = <FieldKey>[];
    final out = Map.of(cfg);
    for (final key in cfg.keys.toList()..sort()) {
      final v = cfg[key]!;
      final path = [...prefix, key];
      switch (v) {
        case VMap(:final entries):
          final sub = _rewrite(entries, path, affects, transform);
          if (sub.changed.isNotEmpty) {
            out[key] = VMap(sub.config);
            changed.addAll(sub.changed);
          }
        case VRef() || VBroken() || VList():
          if (affects(v)) {
            out[key] = transform(v);
            changed.add(ConfigKey(path));
          }
        case VItems(:final items):
          final next = <Item>[];
          var touched = false;
          for (final i in items) {
            if (affects(i.value)) {
              touched = true;
              changed.add(ItemKey(path, i.id));
              next.add(Item(i.id, transform(i.value)));
            } else {
              next.add(i);
            }
          }
          if (touched) out[key] = VItems(List.unmodifiable(next));
        default:
          break;
      }
    }
    return (config: out, changed: changed);
  }
}

sealed class _ItemState {
  const _ItemState();
}

final class _ItemPresent extends _ItemState {
  const _ItemPresent(this.value);
  final Value value;
}

final class _ItemTombstoned extends _ItemState {
  const _ItemTombstoned();
}

final class _ItemMissing extends _ItemState {
  const _ItemMissing(this.reason);
  final RejectReason reason;
}
