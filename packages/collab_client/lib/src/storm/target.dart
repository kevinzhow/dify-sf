import 'dart:convert';

/// How [doc] (a server snapshot's JSON) differs from [target] (make_plan.py's target.json, or a test's): nodes by id with their type,
/// title, position and description, and edges by id with their ends. Empty = exactly the planned workflow.
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
    final got = {'type': n['type'], 'title': n['title'], 'x': n['x'], 'y': n['y'], 'desc': config['desc'] ?? ''};
    for (final k in t.keys) {
      if (got[k] != t[k]) problems.add('node $id $k: ${jsonEncode(got[k])} instead of ${jsonEncode(t[k])}');
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
