import 'package:collection/collection.dart';

/// A reference to another node's output variable (`{"$ref": {"node": ..., "output": ...}}`).
final class OutputRef {
  const OutputRef(this.node, this.output);

  factory OutputRef.fromJson(Object? json) {
    if (json is Map<String, Object?> && json['node'] is String && json['output'] is String) {
      return OutputRef(json['node']! as String, json['output']! as String);
    }
    throw FormatException('bad output reference: $json');
  }

  final String node;
  final String output;

  Map<String, Object?> toJson() => {'node': node, 'output': output};

  @override
  bool operator ==(Object other) => other is OutputRef && other.node == node && other.output == output;

  @override
  int get hashCode => Object.hash(node, output);

  @override
  String toString() => '$node.$output';
}

/// One element of a keyed list. The [id] is stable for the life of the item, which is what lets two users
/// insert/remove/edit *different* items of the same list without ever conflicting.
final class Item {
  const Item(this.id, this.value);

  factory Item.fromJson(Object? json) {
    if (json is Map<String, Object?> && json['id'] is String) {
      return Item(json['id']! as String, Value.fromJson(json['value']));
    }
    throw FormatException('bad list item: $json');
  }

  final String id;
  final Value value;

  Map<String, Object?> toJson() => {'id': id, 'value': value.toJson()};

  @override
  bool operator ==(Object other) => other is Item && other.id == id && other.value == value;

  @override
  int get hashCode => Object.hash(id, value);

  @override
  String toString() => 'Item($id: $value)';
}

const _deepList = ListEquality<Value>();
const _deepItems = ListEquality<Item>();
const _deepMap = MapEquality<String, Value>();

/// A node config value. Plain JSON maps onto it directly (see docs/protocol.md section 3). Numbers are
/// 64-bit integers only. Values are immutable: never mutate a list or map you passed in.
sealed class Value {
  const Value();

  /// Decodes natural JSON: `null`, bool, int, string, list (atomic), map (config subtree), or the
  /// single-key forms `$ref`, `$broken`, `$items`.
  factory Value.fromJson(Object? json) {
    switch (json) {
      case null:
        return const VNull();
      case final bool b:
        return VBool(b);
      case final int i:
        return VInt(i);
      case final String s:
        return VString(s);
      case final List<Object?> xs:
        return VList(List.unmodifiable(xs.map(Value.fromJson)));
      case final Map<String, Object?> m:
        if (m.length == 1) {
          switch (m.keys.single) {
            case r'$ref':
              return VRef(OutputRef.fromJson(m.values.single));
            case r'$broken':
              return VBroken(OutputRef.fromJson(m.values.single));
            case r'$items':
              final raw = m.values.single;
              if (raw is! List<Object?>) throw const FormatException(r'$items must be a list');
              return VItems(List.unmodifiable(raw.map(Item.fromJson)));
          }
        }
        final out = <String, Value>{};
        for (final MapEntry(:key, :value) in m.entries) {
          if (key.startsWith(r'$')) throw FormatException('reserved map key $key');
          out[key] = Value.fromJson(value);
        }
        return VMap(Map.unmodifiable(out));
      default:
        throw FormatException('unsupported value (numbers must be integers): $json');
    }
  }

  /// Convenience constructor from plain Dart data (same rules as [Value.fromJson]).
  factory Value.of(Object? plain) => plain is Value ? plain : Value.fromJson(plain);

  Object? toJson();

  /// Every live (non-broken) reference contained in this value, recursively.
  Iterable<OutputRef> get liveRefs => const [];

  /// Every broken marker contained in this value, recursively.
  Iterable<OutputRef> get brokenRefs => const [];

  bool get containsBrokenRef => brokenRefs.isNotEmpty;

  bool hasRefTo(String node) => liveRefs.any((r) => r.node == node);

  /// Replaces every live reference to [node] with an explicit broken marker.
  Value breakingRefsTo(String node) => this;

  /// Structural problems that make a value unwritable: duplicate/empty item ids, reserved map keys.
  String? get structuralProblem => null;
}

final class VNull extends Value {
  const VNull();
  @override
  Object? toJson() => null;
  @override
  bool operator ==(Object other) => other is VNull;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'null';
}

final class VBool extends Value {
  const VBool(this.value);
  final bool value;
  @override
  Object? toJson() => value;
  @override
  bool operator ==(Object other) => other is VBool && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '$value';
}

final class VInt extends Value {
  const VInt(this.value);
  final int value;
  @override
  Object? toJson() => value;
  @override
  bool operator ==(Object other) => other is VInt && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '$value';
}

final class VString extends Value {
  const VString(this.value);
  final String value;
  @override
  Object? toJson() => value;
  @override
  bool operator ==(Object other) => other is VString && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '"$value"';
}

final class VRef extends Value {
  const VRef(this.ref);
  final OutputRef ref;
  @override
  Object? toJson() => {r'$ref': ref.toJson()};
  @override
  Iterable<OutputRef> get liveRefs => [ref];
  @override
  Value breakingRefsTo(String node) => ref.node == node ? VBroken(ref) : this;
  @override
  bool operator ==(Object other) => other is VRef && other.ref == ref;
  @override
  int get hashCode => Object.hash('ref', ref);
  @override
  String toString() => '{{$ref}}';
}

/// The explicit marker the server writes when the referenced node is deleted. Clients can never write it.
final class VBroken extends Value {
  const VBroken(this.ref);
  final OutputRef ref;
  @override
  Object? toJson() => {r'$broken': ref.toJson()};
  @override
  Iterable<OutputRef> get brokenRefs => [ref];
  @override
  bool operator ==(Object other) => other is VBroken && other.ref == ref;
  @override
  int get hashCode => Object.hash('broken', ref);
  @override
  String toString() => '{{broken $ref}}';
}

/// Atomic list: replaced as a whole, so concurrent edits to it conflict. Use [VItems] for lists whose
/// elements are edited independently.
final class VList extends Value {
  const VList(this.items);
  final List<Value> items;
  @override
  Object? toJson() => [for (final v in items) v.toJson()];
  @override
  Iterable<OutputRef> get liveRefs => items.expand((v) => v.liveRefs);
  @override
  Iterable<OutputRef> get brokenRefs => items.expand((v) => v.brokenRefs);
  @override
  Value breakingRefsTo(String node) => VList([for (final v in items) v.breakingRefsTo(node)]);
  @override
  String? get structuralProblem => items.map((v) => v.structuralProblem).nonNulls.firstOrNull;
  @override
  bool operator ==(Object other) => other is VList && _deepList.equals(other.items, items);
  @override
  int get hashCode => _deepList.hash(items);
  @override
  String toString() => '$items';
}

/// Keyed list: an ordered list of items with stable ids, edited with item-level ops.
final class VItems extends Value {
  const VItems(this.items);
  final List<Item> items;
  @override
  Object? toJson() => {r'$items': [for (final i in items) i.toJson()]};
  @override
  Iterable<OutputRef> get liveRefs => items.expand((i) => i.value.liveRefs);
  @override
  Iterable<OutputRef> get brokenRefs => items.expand((i) => i.value.brokenRefs);
  @override
  Value breakingRefsTo(String node) => VItems([for (final i in items) Item(i.id, i.value.breakingRefsTo(node))]);
  @override
  String? get structuralProblem {
    final seen = <String>{};
    for (final i in items) {
      if (i.id.isEmpty) return 'empty item id';
      if (!seen.add(i.id)) return 'duplicate item id ${i.id}';
      final p = i.value.structuralProblem;
      if (p != null) return p;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is VItems && _deepItems.equals(other.items, items);
  @override
  int get hashCode => _deepItems.hash(items);
  @override
  String toString() => 'items$items';
}

/// A config subtree.
final class VMap extends Value {
  const VMap(this.entries);
  final Map<String, Value> entries;
  @override
  Object? toJson() => {for (final k in _sortedKeys(entries)) k: entries[k]!.toJson()}; // canonical: sorted
  @override
  Iterable<OutputRef> get liveRefs => _sortedKeys(entries).expand((k) => entries[k]!.liveRefs);
  @override
  Iterable<OutputRef> get brokenRefs => _sortedKeys(entries).expand((k) => entries[k]!.brokenRefs);
  @override
  Value breakingRefsTo(String node) => VMap({for (final e in entries.entries) e.key: e.value.breakingRefsTo(node)});
  @override
  String? get structuralProblem {
    for (final MapEntry(:key, :value) in entries.entries) {
      if (key.startsWith(r'$')) return 'map key $key is reserved (keys starting with \$)';
      final p = value.structuralProblem;
      if (p != null) return p;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is VMap && _deepMap.equals(other.entries, entries);
  @override
  int get hashCode => _deepMap.hash(entries);
  @override
  String toString() => '$entries';
}

List<String> _sortedKeys(Map<String, Object?> m) => m.keys.toList()..sort();

/// Operations on the nested `config` tree of a node. Only maps are traversable; lists are leaves.
/// All functions are non-mutating: they return new maps.
abstract final class ConfigTree {
  static Value? get(Map<String, Value> cfg, List<String> path) {
    Value cur = VMap(cfg);
    for (final key in path) {
      if (cur is! VMap) return null;
      final next = cur.entries[key];
      if (next == null) return null;
      cur = next;
    }
    return cur;
  }

  /// True when [path] can be written: every existing intermediate is a map (absent ones get created).
  static bool canSet(Map<String, Value> cfg, List<String> path) {
    if (path.isEmpty) return false;
    var cur = cfg;
    for (final key in path.take(path.length - 1)) {
      final next = cur[key];
      if (next == null) return true;
      if (next is! VMap) return false;
      cur = next.entries;
    }
    return true;
  }

  static Map<String, Value> set(Map<String, Value> cfg, List<String> path, Value value) {
    final out = Map<String, Value>.of(cfg);
    final head = path.first;
    if (path.length == 1) {
      out[head] = value;
    } else {
      final child = switch (cfg[head]) {
        VMap(:final entries) => entries,
        _ => const <String, Value>{},
      };
      out[head] = VMap(set(child, path.sublist(1), value));
    }
    return out;
  }

  /// The keyed list at [path]: null if absent; `notAList` if something else lives there.
  static ListLookup list(Map<String, Value> cfg, List<String> path) => switch (get(cfg, path)) {
        null => const ListAbsent(),
        VItems(:final items) => ListFound(items),
        _ => const ListNotAList(),
      };
}

sealed class ListLookup {
  const ListLookup();
}

final class ListAbsent extends ListLookup {
  const ListAbsent();
}

final class ListNotAList extends ListLookup {
  const ListNotAList();
}

final class ListFound extends ListLookup {
  const ListFound(this.items);
  final List<Item> items;
}
