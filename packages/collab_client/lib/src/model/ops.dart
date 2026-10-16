import 'package:collection/collection.dart';

import 'value.dart';

Never _bad(String what, Object? json) => throw FormatException('bad $what: $json');

Map<String, Object?> _obj(Object? json, String what) => json is Map<String, Object?> ? json : _bad(what, json);

String _str(Map<String, Object?> m, String key, String what) =>
    m[key] is String ? m[key]! as String : _bad('$what.$key', m);

int _int(Map<String, Object?> m, String key, String what) => m[key] is int ? m[key]! as int : _bad('$what.$key', m);

List<String> _path(Map<String, Object?> m, String key, String what) {
  final v = m[key];
  if (v is List<Object?> && v.every((e) => e is String)) return List.unmodifiable(v.cast<String>());
  return _bad('$what.$key', m);
}

// ---- graph elements ------------------------------------------------------------------------------

final class Node {
  const Node({
    required this.id,
    required this.type,
    this.title = '',
    this.x = 0,
    this.y = 0,
    this.config = const {},
  });

  factory Node.fromJson(Object? json) {
    final m = _obj(json, 'node');
    final cfg = _obj(m['config'] ?? <String, Object?>{}, 'node.config');
    return Node(
      id: _str(m, 'id', 'node'),
      type: _str(m, 'type', 'node'),
      title: m['title'] == null ? '' : _str(m, 'title', 'node'),
      x: m['x'] == null ? 0 : _int(m, 'x', 'node'),
      y: m['y'] == null ? 0 : _int(m, 'y', 'node'),
      config: Map.unmodifiable({
        for (final e in cfg.entries) e.key: Value.fromJson(e.value),
      }),
    );
  }

  final String id;
  final String type;
  final String title;
  final int x;
  final int y;
  final Map<String, Value> config;

  Node copyWith({String? title, int? x, int? y, Map<String, Value>? config}) => Node(
    id: id,
    type: type,
    title: title ?? this.title,
    x: x ?? this.x,
    y: y ?? this.y,
    config: config ?? this.config,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'x': x,
    'y': y,
    'config': {for (final k in config.keys.toList()..sort()) k: config[k]!.toJson()},
  };

  @override
  bool operator ==(Object other) =>
      other is Node &&
      other.id == id &&
      other.type == type &&
      other.title == title &&
      other.x == x &&
      other.y == y &&
      const MapEquality<String, Value>().equals(other.config, config);

  @override
  int get hashCode => Object.hash(id, type, title, x, y, const MapEquality<String, Value>().hash(config));

  @override
  String toString() => 'Node($id $type "$title" @$x,$y)';
}

final class Edge {
  const Edge({
    required this.id,
    required this.source,
    this.sourceHandle = 'out',
    required this.target,
    this.targetHandle = 'in',
  });

  factory Edge.fromJson(Object? json) {
    final m = _obj(json, 'edge');
    return Edge(
      id: _str(m, 'id', 'edge'),
      source: _str(m, 'source', 'edge'),
      sourceHandle: _str(m, 'sourceHandle', 'edge'),
      target: _str(m, 'target', 'edge'),
      targetHandle: _str(m, 'targetHandle', 'edge'),
    );
  }

  final String id;
  final String source;
  final String sourceHandle;
  final String target;
  final String targetHandle;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source,
    'sourceHandle': sourceHandle,
    'target': target,
    'targetHandle': targetHandle,
  };

  bool sameConnection(Edge o) =>
      source == o.source && sourceHandle == o.sourceHandle && target == o.target && targetHandle == o.targetHandle;

  @override
  bool operator ==(Object other) => other is Edge && other.id == id && sameConnection(other);

  @override
  int get hashCode => Object.hash(id, source, sourceHandle, target, targetHandle);

  @override
  String toString() => 'Edge($id $source.$sourceHandle -> $target.$targetHandle)';
}

/// Server version stamp: which committed op (global sequence) last wrote something, and who.
final class Stamp {
  const Stamp(this.seq, this.client);

  factory Stamp.fromJson(Object? json) {
    final m = _obj(json, 'stamp');
    return Stamp(_int(m, 'seq', 'stamp'), _str(m, 'client', 'stamp'));
  }

  final int seq;
  final String client;

  Map<String, Object?> toJson() => {'seq': seq, 'client': client};

  @override
  bool operator ==(Object other) => other is Stamp && other.seq == seq && other.client == client;

  @override
  int get hashCode => Object.hash(seq, client);

  @override
  String toString() => '$client@$seq';
}

// ---- field keys ----------------------------------------------------------------------------------

/// A versioned content location inside a node: a register guarded by the stale-write rule.
/// Node position is deliberately NOT a register: layout is last-writer-wins.
sealed class FieldKey {
  const FieldKey();

  factory FieldKey.fromJson(Object? json) {
    final m = _obj(json, 'field');
    return switch (m['k']) {
      'title' => const TitleKey(),
      'config' => ConfigKey(_path(m, 'path', 'field')),
      'item' => ItemKey(_path(m, 'path', 'field'), _str(m, 'id', 'field')),
      _ => _bad('field kind', json),
    };
  }

  Map<String, Object?> toJson();

  /// Two registers overlap when writing one can change the other: config paths overlap when one is a prefix
  /// of the other (`model` vs `model.name`); a config path overlaps every item of a list located at or below
  /// it; items overlap only when identical.
  bool overlaps(FieldKey other) => switch ((this, other)) {
    (TitleKey(), TitleKey()) => true,
    (ConfigKey(path: final a), ConfigKey(path: final b)) => _prefixRelated(a, b),
    (ConfigKey(path: final a), ItemKey(path: final b)) => _prefixRelated(a, b),
    (ItemKey(path: final a), ConfigKey(path: final b)) => _prefixRelated(a, b),
    (ItemKey(path: final p, id: final i), ItemKey(path: final q, id: final j)) =>
      i == j && const ListEquality<String>().equals(p, q),
    _ => false,
  };

  /// Human readable label: `title`, `model.name`, `outputs[<id>]`.
  String get label;

  static bool _prefixRelated(List<String> a, List<String> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final class TitleKey extends FieldKey {
  const TitleKey();
  @override
  Map<String, Object?> toJson() => {'k': 'title'};
  @override
  String get label => 'title';
  @override
  bool operator ==(Object other) => other is TitleKey;
  @override
  int get hashCode => 1;
  @override
  String toString() => 'title';
}

final class ConfigKey extends FieldKey {
  const ConfigKey(this.path);
  final List<String> path;
  @override
  Map<String, Object?> toJson() => {'k': 'config', 'path': path};
  @override
  String get label => path.join('.');
  @override
  bool operator ==(Object other) => other is ConfigKey && const ListEquality<String>().equals(other.path, path);
  @override
  int get hashCode => Object.hash(2, const ListEquality<String>().hash(path));
  @override
  String toString() => 'config(${path.join('.')})';
}

final class ItemKey extends FieldKey {
  const ItemKey(this.path, this.id);
  final List<String> path;
  final String id;
  @override
  Map<String, Object?> toJson() => {'k': 'item', 'path': path, 'id': id};
  @override
  String get label => '${path.join('.')}[$id]';
  @override
  bool operator ==(Object other) =>
      other is ItemKey && other.id == id && const ListEquality<String>().equals(other.path, path);
  @override
  int get hashCode => Object.hash(3, id, const ListEquality<String>().hash(path));
  @override
  String toString() => 'item(${path.join('.')}, $id)';
}

// ---- ops -----------------------------------------------------------------------------------------

/// The small edit vocabulary. Clients never send graph snapshots.
sealed class Op {
  const Op();

  factory Op.fromJson(Object? json) {
    final m = _obj(json, 'op');
    switch (m['t']) {
      case 'addNode':
        return AddNode(Node.fromJson(m['node']));
      case 'removeNode':
        return RemoveNode(_str(m, 'node', 'op'));
      case 'moveNode':
        return MoveNode(_str(m, 'node', 'op'), _int(m, 'x', 'op'), _int(m, 'y', 'op'));
      case 'setField':
        return SetField(_str(m, 'node', 'op'), FieldKey.fromJson(m['field']), Value.fromJson(m['value']));
      case 'addEdge':
        return AddEdge(Edge.fromJson(m['edge']));
      case 'removeEdge':
        return RemoveEdge(_str(m, 'edge', 'op'));
      case 'insertItem':
        return InsertItem(
          _str(m, 'node', 'op'),
          _path(m, 'path', 'op'),
          Item.fromJson(m['item']),
          m['after'] == null ? null : _str(m, 'after', 'op'),
        );
      case 'removeItem':
        return RemoveItem(_str(m, 'node', 'op'), _path(m, 'path', 'op'), _str(m, 'itemId', 'op'));
      case 'updateItem':
        return UpdateItem(
          _str(m, 'node', 'op'),
          _path(m, 'path', 'op'),
          _str(m, 'itemId', 'op'),
          Value.fromJson(m['value']),
        );
      default:
        return _bad('op type', json);
    }
  }

  Map<String, Object?> toJson();

  /// The node this op writes to, if any (for UI notices).
  String? get nodeId;
}

final class AddNode extends Op {
  const AddNode(this.node);
  final Node node;
  @override
  Map<String, Object?> toJson() => {'t': 'addNode', 'node': node.toJson()};
  @override
  String? get nodeId => node.id;
  @override
  bool operator ==(Object other) => other is AddNode && other.node == node;
  @override
  int get hashCode => node.hashCode;
  @override
  String toString() => 'addNode($node)';
}

final class RemoveNode extends Op {
  const RemoveNode(this.node);
  final String node;
  @override
  Map<String, Object?> toJson() => {'t': 'removeNode', 'node': node};
  @override
  String? get nodeId => node;
  @override
  bool operator ==(Object other) => other is RemoveNode && other.node == node;
  @override
  int get hashCode => node.hashCode;
  @override
  String toString() => 'removeNode($node)';
}

/// Layout: last writer wins, applied in server order, never rejected for staleness.
final class MoveNode extends Op {
  const MoveNode(this.node, this.x, this.y);
  final String node;
  final int x;
  final int y;
  @override
  Map<String, Object?> toJson() => {'t': 'moveNode', 'node': node, 'x': x, 'y': y};
  @override
  String? get nodeId => node;
  @override
  bool operator ==(Object other) => other is MoveNode && other.node == node && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(node, x, y);
  @override
  String toString() => 'moveNode($node, $x, $y)';
}

/// [field] is [TitleKey] or [ConfigKey]; list items go through the item ops, position through [MoveNode].
final class SetField extends Op {
  const SetField(this.node, this.field, this.value);
  final String node;
  final FieldKey field;
  final Value value;
  @override
  Map<String, Object?> toJson() => {'t': 'setField', 'node': node, 'field': field.toJson(), 'value': value.toJson()};
  @override
  String? get nodeId => node;
  @override
  bool operator ==(Object other) =>
      other is SetField && other.node == node && other.field == field && other.value == value;
  @override
  int get hashCode => Object.hash(node, field, value);
  @override
  String toString() => 'setField($node, $field, $value)';
}

final class AddEdge extends Op {
  const AddEdge(this.edge);
  final Edge edge;
  @override
  Map<String, Object?> toJson() => {'t': 'addEdge', 'edge': edge.toJson()};
  @override
  String? get nodeId => edge.source;
  @override
  bool operator ==(Object other) => other is AddEdge && other.edge == edge;
  @override
  int get hashCode => edge.hashCode;
  @override
  String toString() => 'addEdge($edge)';
}

final class RemoveEdge extends Op {
  const RemoveEdge(this.edge);
  final String edge;
  @override
  Map<String, Object?> toJson() => {'t': 'removeEdge', 'edge': edge};
  @override
  String? get nodeId => null;
  @override
  bool operator ==(Object other) => other is RemoveEdge && other.edge == edge;
  @override
  int get hashCode => edge.hashCode;
  @override
  String toString() => 'removeEdge($edge)';
}

/// Inserts [item] into the keyed list at [path] right after item [after] (null = at the front). If [after]
/// no longer exists the item is appended. Creates the list if absent.
final class InsertItem extends Op {
  const InsertItem(this.node, this.path, this.item, this.after);
  final String node;
  final List<String> path;
  final Item item;
  final String? after;
  @override
  Map<String, Object?> toJson() => {
    't': 'insertItem',
    'node': node,
    'path': path,
    'item': item.toJson(),
    'after': after,
  };
  @override
  String? get nodeId => node;
  @override
  bool operator ==(Object other) =>
      other is InsertItem &&
      other.node == node &&
      const ListEquality<String>().equals(other.path, path) &&
      other.item == item &&
      other.after == after;
  @override
  int get hashCode => Object.hash(node, const ListEquality<String>().hash(path), item, after);
  @override
  String toString() => 'insertItem($node, ${path.join('.')}, $item, after: $after)';
}

final class RemoveItem extends Op {
  const RemoveItem(this.node, this.path, this.itemId);
  final String node;
  final List<String> path;
  final String itemId;
  @override
  Map<String, Object?> toJson() => {'t': 'removeItem', 'node': node, 'path': path, 'itemId': itemId};
  @override
  String? get nodeId => node;
  @override
  bool operator ==(Object other) =>
      other is RemoveItem &&
      other.node == node &&
      const ListEquality<String>().equals(other.path, path) &&
      other.itemId == itemId;
  @override
  int get hashCode => Object.hash(node, const ListEquality<String>().hash(path), itemId);
  @override
  String toString() => 'removeItem($node, ${path.join('.')}, $itemId)';
}

/// Replaces the value of one item.
final class UpdateItem extends Op {
  const UpdateItem(this.node, this.path, this.itemId, this.value);
  final String node;
  final List<String> path;
  final String itemId;
  final Value value;
  @override
  Map<String, Object?> toJson() => {
    't': 'updateItem',
    'node': node,
    'path': path,
    'itemId': itemId,
    'value': value.toJson(),
  };
  @override
  String? get nodeId => node;
  @override
  bool operator ==(Object other) =>
      other is UpdateItem &&
      other.node == node &&
      const ListEquality<String>().equals(other.path, path) &&
      other.itemId == itemId &&
      other.value == value;
  @override
  int get hashCode => Object.hash(node, const ListEquality<String>().hash(path), itemId, value);
  @override
  String toString() => 'updateItem($node, ${path.join('.')}, $itemId, $value)';
}

// ---- reject reasons ------------------------------------------------------------------------------

/// Why the server (or a client's local pre-check) refused an op. Always delivered to the sender.
sealed class RejectReason {
  const RejectReason();

  factory RejectReason.fromJson(Object? json) {
    final m = _obj(json, 'reason');
    switch (m['type']) {
      case 'conflict':
        return Conflict(
          node: _str(m, 'node', 'reason'),
          field: m['field'] == null ? null : FieldKey.fromJson(m['field']),
          seq: _int(m, 'seq', 'reason'),
          by: _str(m, 'by', 'reason'),
        );
      case 'nodeDeleted':
        return NodeDeleted(_str(m, 'node', 'reason'));
      case 'nodeNotFound':
        return NodeNotFound(_str(m, 'node', 'reason'));
      case 'nodeExists':
        return NodeExists(_str(m, 'node', 'reason'));
      case 'edgeNotFound':
        return EdgeNotFound(_str(m, 'edge', 'reason'));
      case 'edgeExists':
        return EdgeExists(_str(m, 'edge', 'reason'));
      case 'duplicateEdge':
        return DuplicateEdge(_str(m, 'edge', 'reason'));
      case 'danglingReference':
        return DanglingReference(_str(m, 'node', 'reason'));
      case 'itemNotFound':
        return ItemNotFound(_str(m, 'item', 'reason'));
      case 'itemDeleted':
        return ItemDeleted(_str(m, 'item', 'reason'));
      case 'itemExists':
        return ItemExists(_str(m, 'item', 'reason'));
      case 'invalid':
        return Invalid(m['message'] is String ? m['message']! as String : '');
      case 'notCommitted':
        return const NotCommitted();
      default:
        // Forward compatible: an unknown reason is still a rejection.
        return Invalid('unknown reject reason: ${m['type']}');
    }
  }

  /// Stable machine-readable name (the wire `type`).
  String get name;

  Map<String, Object?> toJson();

  /// Reasons that are certain to repeat on the server, so a client may warn the user early.
  bool get isStaleBased => switch (this) {
    Conflict() || NodeDeleted() || DanglingReference() || ItemDeleted() => true,
    _ => false,
  };

  @override
  bool operator ==(Object other) =>
      other is RejectReason &&
      other.runtimeType == runtimeType &&
      const DeepCollectionEquality().equals(other.toJson(), toJson());

  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());

  @override
  String toString() => '$name${toJson()..remove('type')}';
}

/// Someone else wrote this field/node after the op's base version (with a different value); the newer value
/// is kept. [field] null = the whole node (delete vs. any modification).
final class Conflict extends RejectReason {
  const Conflict({required this.node, required this.field, required this.seq, required this.by});
  final String node;
  final FieldKey? field;
  final int seq;
  final String by;
  @override
  String get name => 'conflict';
  @override
  Map<String, Object?> toJson() => {'type': name, 'node': node, 'field': field?.toJson(), 'seq': seq, 'by': by};
}

final class NodeDeleted extends RejectReason {
  const NodeDeleted(this.node);
  final String node;
  @override
  String get name => 'nodeDeleted';
  @override
  Map<String, Object?> toJson() => {'type': name, 'node': node};
}

final class NodeNotFound extends RejectReason {
  const NodeNotFound(this.node);
  final String node;
  @override
  String get name => 'nodeNotFound';
  @override
  Map<String, Object?> toJson() => {'type': name, 'node': node};
}

final class NodeExists extends RejectReason {
  const NodeExists(this.node);
  final String node;
  @override
  String get name => 'nodeExists';
  @override
  Map<String, Object?> toJson() => {'type': name, 'node': node};
}

final class DanglingReference extends RejectReason {
  const DanglingReference(this.node);
  final String node;
  @override
  String get name => 'danglingReference';
  @override
  Map<String, Object?> toJson() => {'type': name, 'node': node};
}

final class EdgeNotFound extends RejectReason {
  const EdgeNotFound(this.edge);
  final String edge;
  @override
  String get name => 'edgeNotFound';
  @override
  Map<String, Object?> toJson() => {'type': name, 'edge': edge};
}

final class EdgeExists extends RejectReason {
  const EdgeExists(this.edge);
  final String edge;
  @override
  String get name => 'edgeExists';
  @override
  Map<String, Object?> toJson() => {'type': name, 'edge': edge};
}

/// [edge] is the id of the existing edge that makes the new one a duplicate.
final class DuplicateEdge extends RejectReason {
  const DuplicateEdge(this.edge);
  final String edge;
  @override
  String get name => 'duplicateEdge';
  @override
  Map<String, Object?> toJson() => {'type': name, 'edge': edge};
}

final class ItemNotFound extends RejectReason {
  const ItemNotFound(this.item);
  final String item;
  @override
  String get name => 'itemNotFound';
  @override
  Map<String, Object?> toJson() => {'type': name, 'item': item};
}

final class ItemDeleted extends RejectReason {
  const ItemDeleted(this.item);
  final String item;
  @override
  String get name => 'itemDeleted';
  @override
  Map<String, Object?> toJson() => {'type': name, 'item': item};
}

final class ItemExists extends RejectReason {
  const ItemExists(this.item);
  final String item;
  @override
  String get name => 'itemExists';
  @override
  Map<String, Object?> toJson() => {'type': name, 'item': item};
}

final class Invalid extends RejectReason {
  const Invalid(this.message);
  final String message;
  @override
  String get name => 'invalid';
  @override
  Map<String, Object?> toJson() => {'type': name, 'message': message};
}

/// The cseq was handled (abandoned below a client's `floor`) but never committed.
final class NotCommitted extends RejectReason {
  const NotCommitted();
  @override
  String get name => 'notCommitted';
  @override
  Map<String, Object?> toJson() => {'type': name};
}
