import 'dart:convert';

/// How [doc] (a server snapshot's JSON) differs from [target] (make_plan.py's target.json, or a test's): nodes by id with
/// their type, title, position, description and (when the target has it) whole configuration, and edges by id with their
/// ends. Empty = exactly the planned workflow.
List<String> targetMismatches(Map<String, Object?> doc, Map<String, Object?> target) {
  final problems = <String>[];
  final nodes = {
    for (final n in doc['nodes']! as List<Object?>) (n! as Map<String, Object?>)['id']! as String: n as Map,
  };
  final want = target['nodes']! as Map<String, Object?>;
  for (final MapEntry(key: id, value: w) in want.entries) {
    final n = nodes[id];
    if (n == null) {
      problems.add('node $id missing');
      continue;
    }
    final t = w! as Map<String, Object?>;
    final config = (n['config'] as Map?) ?? const {};
    final got = {
      'type': n['type'],
      'title': n['title'],
      'x': n['x'],
      'y': n['y'],
      'desc': config['desc'] ?? '',
      'config': config,
    };
    for (final k in t.keys) {
      if (!_same(got[k], t[k])) {
        problems.add(
          k == 'config'
              ? 'node $id config differs: ${_firstDifference(got[k], t[k], 'config')}'
              : 'node $id $k: ${jsonEncode(got[k])} instead of ${jsonEncode(t[k])}',
        );
      }
    }
  }
  for (final id in nodes.keys) {
    if (!want.containsKey(id)) problems.add('node $id not planned');
  }
  final edges = {
    for (final e in doc['edges']! as List<Object?>) (e! as Map<String, Object?>)['id']! as String: e as Map,
  };
  final wantEdges = target['edges']! as Map<String, Object?>;
  for (final MapEntry(key: id, value: w) in wantEdges.entries) {
    final e = edges[id];
    final t = w! as Map<String, Object?>;
    if (e == null) {
      problems.add('edge $id missing');
    } else if (t.keys.any((k) => e[k] != t[k])) {
      problems.add('edge $id connects ${e['source']}->${e['target']} instead of ${t['source']}->${t['target']}');
    }
  }
  for (final id in edges.keys) {
    if (!wantEdges.containsKey(id)) problems.add('edge $id not planned');
  }
  return problems;
}

/// JSON values equal, whatever the order of map keys.
bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length && Iterable<int>.generate(a.length).every((i) => _same(a[i], b[i]));
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Where [a] and [b] first differ, as a path (for the report).
String _firstDifference(Object? a, Object? b, String path) {
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      if (!_same(a[k], b[k])) return _firstDifference(a[k], b[k], '$path.$k');
    }
  }
  if (a is List && b is List && a.length == b.length) {
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return _firstDifference(a[i], b[i], '$path[$i]');
    }
  }
  String show(Object? v) => jsonEncode(v).length > 80 ? '${jsonEncode(v).substring(0, 80)}…' : jsonEncode(v);
  return '$path: ${show(a)} instead of ${show(b)}';
}
