import 'package:collection/collection.dart';
import 'package:yaml/yaml.dart';

import '../model/app_registers.dart';
import '../model/document.dart';
import '../model/ops.dart';
import '../model/value.dart';

/// The reference server's Dify workflow-file mapping and document replacement (`POST /v1/docs/{doc}/replace`,
/// docs/protocol.md section 2, "Replacing a document"), for the fake servers: the same import (nodes, edges, keyed lists,
/// references, declared outputs, document-level registers, secrets), the same refusals, the same id rules and the same
/// op planning. Only what a replacement needs: no export, and the import metadata is reduced to the `app` section.
abstract final class FakeDifyDsl {
  /// Dify 1.17.1's `CURRENT_APP_DSL_VERSION`.
  static const currentDslVersion = '0.7.0';

  /// Reads a YAML (or JSON) document into plain Dart data (maps, lists, scalars).
  static Object? parseYaml(String text) => _plain(loadYaml(text));

  static Object? _plain(Object? v) => switch (v) {
    final YamlMap m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
    final YamlList l => [for (final x in l) _plain(x)],
    final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
    final List<Object?> l => [for (final x in l) _plain(x)],
    _ => v,
  };

  // ---- Dify's checks -----------------------------------------------------------------------------

  /// Dify's `check_version_compatibility`: `completed`, `completed-with-warnings`, `pending` or `failed`.
  static String versionStatus(String imported, {String current = currentDslVersion}) {
    final i = _release(imported), c = _release(current);
    if (i == null || c == null) return 'failed';
    int at(List<int> v, int k) => k < v.length ? v[k] : 0;
    for (var k = 0; k < (i.length > c.length ? i.length : c.length); k++) {
      if (at(i, k) != at(c, k)) {
        if (at(i, k) > at(c, k)) return 'pending';
        break;
      }
    }
    if (i[0] < c[0]) return 'pending';
    if (at(i, 1) < at(c, 1)) return 'completed-with-warnings';
    return 'completed';
  }

  static List<int>? _release(String s) {
    var t = s.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    final out = <int>[];
    for (final p in t.split('.')) {
      if (p.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(p)) return null;
      out.add(int.parse(p));
    }
    return out.isEmpty ? null : out;
  }

  /// Dify's checks of a file that overwrites an app, in Dify's order (see the reference server's
  /// `DifyDSL.checkReplacement`). Throws [FakeReplaceRefusal]; returns the file's version and status.
  static ({String version, String status}) checkReplacement(
    Object? root, {
    required String appMode,
    bool confirm = false,
  }) {
    if (root is! Map<String, Object?>) throw const FakeReplaceRefusal('Invalid YAML format: content must be a mapping');
    var version = '0.1.0';
    final v = root['version'];
    if (v is String) {
      if (v.isNotEmpty) version = v;
    } else if (v != null) {
      final type = switch (v) {
        bool() => 'bool',
        int() => 'int',
        double() => 'float',
        List() => 'list',
        Map() => 'dict',
        _ => 'str',
      };
      throw FakeReplaceRefusal("Invalid version type, expected str, got <class '$type'>");
    }
    final status = versionStatus(version);
    if (status == 'failed') throw FakeReplaceRefusal('Invalid DSL version: $version');
    final app = root['app'];
    if (app is! Map<String, Object?> || app.isEmpty) throw const FakeReplaceRefusal('Missing app data in YAML content');
    if (status == 'pending' && !confirm) {
      throw FakeReplaceRefusal(
        'The DSL version $version differs from the current version $currentDslVersion: confirm to import',
        pendingVersion: version,
      );
    }
    final mode = app['mode'];
    if (mode is! String || mode.isEmpty) throw const FakeReplaceRefusal('loss app mode');
    const known = ['completion', 'workflow', 'chat', 'advanced-chat', 'agent-chat', 'agent', 'channel', 'rag-pipeline'];
    if (!known.contains(mode)) throw FakeReplaceRefusal("'$mode' is not a valid AppMode");
    if (mode != 'workflow' && mode != 'advanced-chat') {
      throw FakeReplaceRefusal('Only workflow or advanced chat apps can be overwritten (the file is a $mode app)');
    }
    final workflow = root['workflow'];
    if (workflow is! Map<String, Object?>) {
      throw const FakeReplaceRefusal('Missing workflow data for workflow/advanced chat app');
    }
    final invalid = appMode == 'advanced-chat'
        ? const {'end', 'trigger-webhook', 'trigger-schedule', 'trigger-plugin'}
        : const {'answer'};
    final graph = workflow['graph'];
    if (graph is Map<String, Object?> && graph['nodes'] is List<Object?>) {
      final found = <String>{
        for (final n in graph['nodes']! as List<Object?>)
          if (n is Map<String, Object?> && n['data'] is Map<String, Object?>)
            if ((n['data']! as Map<String, Object?>)['type'] case final String t when invalid.contains(t)) t,
      };
      if (found.isNotEmpty) {
        final what = appMode == 'advanced-chat' ? 'a chatflow (advanced-chat)' : 'a workflow';
        throw FakeReplaceRefusal(
          'Import Failed: ${(found.toList()..sort()).join(', ')} nodes are not supported in $what app',
        );
      }
    }
    return (version: version, status: status);
  }

  // ---- import ------------------------------------------------------------------------------------

  static const _keyedLists = [
    ('*', 'variables', 'variable'),
    ('end', 'outputs', 'variable'),
    ('if-else', 'cases', 'case_id'),
    ('llm', 'prompt_template', 'id'),
    ('loop', 'loop_variables', 'id'),
    ('loop', 'break_conditions', 'id'),
  ];

  /// The reference server's `DifyDSL.importValue`: the document a file becomes, the plaintext of its secrets (by the
  /// `secret_ref` that replaced them) and its `app` section.
  static ({Document document, Map<String, String> secrets, Map<String, Object?> app}) importValue(
    Object? root, {
    required String Function() newSecretRef,
    required String Function() newId,
  }) {
    if (root is! Map<String, Object?> ||
        root['workflow'] is! Map<String, Object?> ||
        (root['workflow']! as Map<String, Object?>)['graph'] is! Map<String, Object?>) {
      throw const FormatException('not a Dify workflow DSL (workflow.graph missing)');
    }
    final workflow = root['workflow']! as Map<String, Object?>;
    final graph = workflow['graph']! as Map<String, Object?>;
    final rawNodes = graph['nodes'];
    if (rawNodes is! List<Object?>) throw const FormatException('workflow.graph.nodes missing');
    final rawEdges = graph['edges'] is List<Object?> ? graph['edges']! as List<Object?> : const <Object?>[];
    final ids = <String>{
      for (final n in rawNodes)
        if (n is Map<String, Object?> && n['id'] is String) n['id']! as String,
    };
    final nodes = <Node>[];
    for (final raw in rawNodes) {
      if (raw is! Map<String, Object?> || raw['id'] is! String || raw['data'] is! Map<String, Object?>) {
        throw const FormatException('node without id or data');
      }
      final n = Map<String, Object?>.of(raw);
      final id = n.remove('id')! as String;
      final data = Map<String, Object?>.of(n.remove('data')! as Map<String, Object?>);
      final type = data.remove('type');
      if (type is! String) throw FormatException('node $id has no data.type');
      final title = data.remove('title');
      data.remove('selected');
      n.remove('selected');
      final (x, y, exact) = _position(n.remove('position'));
      if (exact != null) n['position'] = exact;
      final config = <String, Value>{for (final e in data.entries) e.key: _value(e.value, ids)};
      for (final (t, key, itemKey) in _keyedLists) {
        if (t != '*' && t != type) continue;
        if (config[key] case VList(:final items)) {
          final keyed = _keyed(items, itemKey);
          if (keyed != null) config[key] = VItems(keyed);
        }
      }
      if (config['outputs'] case VMap(:final entries) when type == 'code') {
        config['outputs'] = VItems([
          for (final name in entries.keys.toList()..sort())
            Item(
              name,
              VMap({
                ...switch (entries[name]!) {
                  VMap(entries: final m) => m,
                  final other => {'value': other},
                },
                'name': VString(name),
              }),
            ),
        ]);
      }
      if (n.isNotEmpty) config['_dify_node'] = _value(n, const {});
      nodes.add(Node(id: id, type: type, title: title is String ? title : '', x: x, y: y, config: config));
    }
    final edges = <Edge>[];
    for (final raw in rawEdges) {
      if (raw is! Map<String, Object?> ||
          raw['id'] is! String ||
          raw['source'] is! String ||
          raw['target'] is! String) {
        throw const FormatException('edge without id/source/target');
      }
      edges.add(
        Edge(
          id: raw['id']! as String,
          source: raw['source']! as String,
          sourceHandle: raw['sourceHandle'] is String ? raw['sourceHandle']! as String : 'source',
          target: raw['target']! as String,
          targetHandle: raw['targetHandle'] is String ? raw['targetHandle']! as String : 'target',
        ),
      );
    }
    final app = <String, Value>{};
    final secrets = <String, String>{};
    for (final key in const [AppRegisters.environmentVariables, AppRegisters.conversationVariables]) {
      final xs = workflow[key];
      if (xs is! List<Object?>) continue;
      var items = _keyedById([for (final x in xs) _value(x, const {})], newId);
      if (key == AppRegisters.environmentVariables) {
        items = [
          for (final i in items)
            if (i.value case VMap(:final entries))
              () {
                final m = Map<String, Value>.of(entries)..remove(AppRegisters.secretRef);
                final plain = _secretText(m['value']);
                if (m['value_type'] == const VString('secret') && plain != null && plain.isNotEmpty) {
                  final ref = newSecretRef();
                  secrets[ref] = plain;
                  m['value'] = VString(AppRegisters.maskSecret(plain));
                  m[AppRegisters.secretRef] = VString(ref);
                }
                return Item(i.id, VMap(m));
              }()
            else
              i,
        ];
      }
      app[key] = VItems(items);
    }
    if (workflow[AppRegisters.features] is Map<String, Object?>) {
      app[AppRegisters.features] = _value(workflow[AppRegisters.features], const {});
    }
    // References to outputs the target does not declare are broken markers (as the reference server imports them).
    final declared = {for (final n in nodes) n.id: Document.declaredOutputs(n)};
    Value checked(Value v) => switch (v) {
      VRef(:final ref) when declared[ref.node] != null && !declared[ref.node]!.contains(ref.output) => VBroken(ref),
      VList(:final items) => VList([for (final x in items) checked(x)]),
      VItems(:final items) => VItems([for (final i in items) Item(i.id, checked(i.value))]),
      VMap(:final entries) => VMap({for (final e in entries.entries) e.key: checked(e.value)}),
      _ => v,
    };
    final doc = Document(
      nodes: [
        for (final n in nodes) n.copyWith(config: {for (final e in n.config.entries) e.key: checked(e.value)}),
      ],
      edges: edges,
      app: app,
    );
    final problems = doc.integrityProblems;
    if (problems.isNotEmpty) throw FormatException('imported workflow is inconsistent: ${problems.first}');
    return (
      document: doc,
      secrets: secrets,
      app: root['app'] is Map<String, Object?> ? Map.of(root['app']! as Map<String, Object?>) : <String, Object?>{},
    );
  }

  static (int, int, Object?) _position(Object? v) {
    if (v is! Map<String, Object?>) return (0, 0, null);
    double n(String k) => (v[k] is num) ? (v[k]! as num).toDouble() : 0;
    final x = n('x'), y = n('y');
    final exact = x == x.roundToDouble() && y == y.roundToDouble() ? null : v;
    return (x.round(), y.round(), exact);
  }

  /// Plain data -> [Value]; `[node, output]` with a node of the graph -> reference.
  static Value _value(Object? v, Set<String> nodes) => switch (v) {
    null => const VNull(),
    final bool b => VBool(b),
    final num n => Value.number(n),
    final String s => VString(s),
    final List<Object?> xs when xs.length == 2 && xs[0] is String && xs[1] is String && nodes.contains(xs[0]) => VRef(
      OutputRef(xs[0]! as String, xs[1]! as String),
    ),
    final List<Object?> xs => VList([for (final x in xs) _value(x, nodes)]),
    final Map<String, Object?> m => VMap({for (final e in m.entries) e.key: _value(e.value, nodes)}),
    _ => VString('$v'),
  };

  static List<Item>? _keyed(List<Value> xs, String key) {
    final seen = <String>{};
    final out = <Item>[];
    for (final x in xs) {
      if (x is! VMap || x.entries[key] is! VString) return null;
      final id = (x.entries[key]! as VString).value;
      if (id.isEmpty || !seen.add(id)) return null;
      out.add(Item(id, x));
    }
    return out;
  }

  static List<Item> _keyedById(List<Value> xs, String Function() newId) {
    final seen = <String>{
      for (final x in xs)
        if (x case VMap(entries: {'id': VString(:final value)}) when value.isNotEmpty) value,
    };
    final used = <String>{};
    return [
      for (final x in xs)
        if (x case VMap(entries: {'id': VString(:final value)}) when value.isNotEmpty && used.add(value))
          Item(value, x)
        else
          () {
            var id = newId();
            while (seen.contains(id) || used.contains(id)) {
              id = newId();
            }
            used.add(id);
            return x is VMap ? Item(id, VMap({...x.entries, 'id': VString(id)})) : Item(id, x);
          }(),
    ];
  }

  static String? _secretText(Value? v) => switch (v) {
    VString(:final value) => value,
    VInt(:final value) => '$value',
    VDouble(:final value) => '$value',
    VBool(:final value) => value ? 'true' : 'false',
    _ => null,
  };

  // ---- replacement -------------------------------------------------------------------------------

  /// The reference server's `DifyDSL.planReplacement`: the ops (and secrets to store, renamings, the file's `app`
  /// section) that replace [current] (the document at [base]) by the file [root], as ops of [client].
  static FakeReplacementPlan planReplacement(
    Object? root, {
    required Document current,
    required Map<String, String> storedSecrets,
    required String client,
    required int base,
    required String Function() newSecretRef,
    String Function()? newNodeId,
  }) {
    var idCounter = 0;
    String newId() => 'v-${++idCounter}-${DateTime.now().microsecondsSinceEpoch}';
    final nodeId = newNodeId ?? () => '${DateTime.now().millisecondsSinceEpoch}';
    final first = importValue(root, newSecretRef: newSecretRef, newId: newId);
    final fresh = FakeReplacement.freshIdsNeeded(current, first.document);
    final renamedNodes = <String, String>{};
    final renamedEdges = <String, String>{};
    var imported = first;
    if (fresh.nodes.isNotEmpty || fresh.edges.isNotEmpty) {
      final taken = <String>{};
      bool nodeTaken(String id) =>
          id.isEmpty ||
          id.startsWith(r'$') ||
          current.nodes.containsKey(id) ||
          current.deletedNodes.containsKey(id) ||
          first.document.nodes.containsKey(id) ||
          taken.contains(id);
      for (final id in fresh.nodes.toList()..sort()) {
        var n = nodeId();
        var bump = int.tryParse(n) ?? 0;
        while (nodeTaken(n)) {
          bump++;
          n = int.tryParse(n) != null ? '$bump' : '${nodeId()}_$bump';
        }
        taken.add(n);
        renamedNodes[id] = n;
      }
      final used = <String>{};
      bool edgeTaken(String id) =>
          id.isEmpty ||
          current.edges.containsKey(id) ||
          current.deletedEdges.containsKey(id) ||
          first.document.edges.containsKey(id) ||
          used.contains(id);
      for (final id in first.document.edges.keys.toList()..sort()) {
        final e = first.document.edges[id]!;
        if (!fresh.edges.contains(id) && !renamedNodes.containsKey(e.source) && !renamedNodes.containsKey(e.target)) {
          continue;
        }
        final stem =
            '${renamedNodes[e.source] ?? e.source}-${e.sourceHandle}-${renamedNodes[e.target] ?? e.target}-${e.targetHandle}';
        var candidate = stem;
        var k = 0;
        while (edgeTaken(candidate)) {
          candidate = '$stem-${++k}';
        }
        used.add(candidate);
        renamedEdges[id] = candidate;
      }
      imported = importValue(renaming(root, renamedNodes, renamedEdges), newSecretRef: newSecretRef, newId: newId);
    }
    var target = imported.document;
    final secrets = Map.of(imported.secrets);
    if (target.app[AppRegisters.environmentVariables] case VItems(:final items)) {
      final currentRefs = <String, String>{
        if (current.app[AppRegisters.environmentVariables] case VItems(items: final cur))
          for (final i in cur)
            if (i.value case VMap(:final entries))
              if (entries[AppRegisters.secretRef] case VString(:final value)) i.id: value,
      };
      final kept = [
        for (final i in items)
          if (i.value case VMap(:final entries))
            if (entries[AppRegisters.secretRef] case VString(value: final ref)
                when secrets[ref] != null &&
                    currentRefs[i.id] != null &&
                    storedSecrets[currentRefs[i.id]!] == secrets[ref])
              () {
                secrets.remove(ref);
                return Item(i.id, VMap({...entries, AppRegisters.secretRef: VString(currentRefs[i.id]!)}));
              }()
            else
              i
          else
            i,
      ];
      target = Document(
        nodes: target.nodes.values,
        edges: target.edges.values,
        app: {...target.app, AppRegisters.environmentVariables: VItems(kept)},
      );
    }
    final ops = FakeReplacement.ops(current, target, client: client, base: base);
    return FakeReplacementPlan(
      ops: ops,
      document: target,
      secrets: secrets,
      app: imported.app,
      renamedNodes: renamedNodes,
      renamedEdges: renamedEdges,
    );
  }

  static const _nodeIdFields = {'parentId', 'iteration_id', 'loop_id', 'start_node_id'};

  /// The file with node and edge ids renamed (the reference server's `DifyDSL.renaming`).
  static Object? renaming(Object? root, Map<String, String> nodes, Map<String, String> edges) {
    if (nodes.isEmpty && edges.isEmpty) return root;
    Object? walk(Object? v, String? key) {
      switch (v) {
        case final String s:
          if (key != null && _nodeIdFields.contains(key) && nodes[s] != null) return nodes[s];
          if (!s.contains('{{#')) return s;
          var out = s;
          for (final e in nodes.entries) {
            out = out.replaceAll('{{#${e.key}.', '{{#${e.value}.');
          }
          return out;
        case final List<Object?> xs:
          if (xs.length >= 2 && xs.every((x) => x is String) && nodes[xs[0]] != null) {
            return [nodes[xs[0]], ...xs.skip(1)];
          }
          return [for (final x in xs) walk(x, null)];
        case final Map<String, Object?> m:
          return {for (final e in m.entries) e.key: walk(e.value, e.key)};
        default:
          return v;
      }
    }

    if (root is! Map<String, Object?>) return root;
    final workflow = root['workflow'];
    if (workflow is! Map<String, Object?>) return root;
    final graph = workflow['graph'];
    if (graph is! Map<String, Object?>) return root;
    final g = Map<String, Object?>.of(graph);
    if (g['nodes'] case final List<Object?> ns) {
      g['nodes'] = [
        for (final raw in ns)
          if (walk(raw, null) case final Map<String, Object?> n)
            {...n, if (n['id'] case final String id when nodes[id] != null) 'id': nodes[id]}
          else
            raw,
      ];
    }
    if (g['edges'] case final List<Object?> es) {
      g['edges'] = [
        for (final raw in es)
          if (walk(raw, null) case final Map<String, Object?> e)
            {
              ...e,
              if (e['id'] case final String id when edges[id] != null) 'id': edges[id],
              if (e['source'] case final String s when nodes[s] != null) 'source': nodes[s],
              if (e['target'] case final String t when nodes[t] != null) 'target': nodes[t],
            }
          else
            raw,
      ];
    }
    return {
      ...root,
      'workflow': {...workflow, 'graph': g},
    };
  }
}

/// A refused `POST /replace` of a fake server: HTTP [status], error [code] and message; nothing was changed.
class FakeReplaceError implements Exception {
  const FakeReplaceError(this.status, this.code, this.message, {this.importedVersion});
  final int status;
  final String code;
  final String message;

  /// For `version_unconfirmed`: the file's DSL version.
  final String? importedVersion;
  @override
  String toString() => '$status $code: $message';
}

/// A file refused before anything was computed: Dify's message; [pendingVersion] when the user has to confirm.
class FakeReplaceRefusal implements Exception {
  const FakeReplaceRefusal(this.message, {this.pendingVersion});
  final String message;
  final String? pendingVersion;
  @override
  String toString() => message;
}

final class FakeReplacementPlan {
  const FakeReplacementPlan({
    required this.ops,
    required this.document,
    required this.secrets,
    required this.app,
    required this.renamedNodes,
    required this.renamedEdges,
  });
  final List<Op> ops;
  final Document document;
  final Map<String, String> secrets;
  final Map<String, Object?> app;
  final Map<String, String> renamedNodes;
  final Map<String, String> renamedEdges;
}

/// The reference server's `CollabCore.Replacement`: the ops that turn one document into another.
abstract final class FakeReplacement {
  static ({Set<String> nodes, Set<String> edges}) freshIdsNeeded(Document current, Document target) {
    final nodes = <String>{};
    for (final MapEntry(key: id, value: t) in target.nodes.entries) {
      if (current.deletedNodes.containsKey(id)) {
        nodes.add(id);
        continue;
      }
      final c = current.nodes[id];
      if (c == null) continue;
      if (c.type != t.type || !c.config.keys.every(t.config.containsKey)) nodes.add(id);
    }
    final edges = <String>{};
    for (final MapEntry(key: id, value: t) in target.edges.entries) {
      if (current.deletedEdges.containsKey(id)) {
        edges.add(id);
        continue;
      }
      if (nodes.contains(t.source) || nodes.contains(t.target)) {
        if (current.edges.containsKey(id)) edges.add(id);
        continue;
      }
      final c = current.edges[id];
      if (c != null && c != t) edges.add(id);
    }
    return (nodes: nodes, edges: edges);
  }

  /// Broken markers as the plain `[node, output]` pairs they stand for.
  static Value writable(Value v) => switch (v) {
    VBroken(:final ref) => VList([VString(ref.node), VString(ref.output)]),
    VList(:final items) => VList([for (final x in items) writable(x)]),
    VItems(:final items) => VItems([for (final i in items) Item(i.id, writable(i.value))]),
    VMap(:final entries) => VMap({for (final e in entries.entries) e.key: writable(e.value)}),
    _ => v,
  };

  static List<Op> ops(Document current, Document target, {required String client, required int base}) {
    final fresh = freshIdsNeeded(current, target);
    if (fresh.nodes.isNotEmpty || fresh.edges.isNotEmpty) {
      throw StateError('ids need fresh ids first: ${[...fresh.nodes, ...fresh.edges]}');
    }
    final p = _Planner(current.clone(), target, client, base);
    for (final id in current.edges.keys.toList()..sort()) {
      if (target.edges[id] != current.edges[id]) p.must([RemoveEdge(id)]);
    }
    for (final id in current.nodes.keys.toList()..sort()) {
      if (!target.nodes.containsKey(id)) p.must([RemoveNode(id)]);
    }
    final tasks = <(String, String, String?)>[]; // (kind, id, key)
    for (final key in {...current.app.keys, ...target.app.keys}.toList()..sort()) {
      tasks.add(('app', key, null));
    }
    final ids = target.nodes.keys.toList()..sort();
    for (final id in ids) {
      if (!current.nodes.containsKey(id)) tasks.add(('addNode', id, null));
    }
    for (final id in ids) {
      tasks
        ..add(('title', id, null))
        ..add(('move', id, null));
    }
    for (final id in ids) {
      if (target.nodes[id]!.config.containsKey(Document.outputsKey)) tasks.add(('config', id, Document.outputsKey));
    }
    for (final id in ids) {
      for (final key in target.nodes[id]!.config.keys.toList()..sort()) {
        if (key != Document.outputsKey) tasks.add(('config', id, key));
      }
    }
    for (final id in target.edges.keys.toList()..sort()) {
      if (!current.edges.containsKey(id)) tasks.add(('addEdge', id, null));
    }
    p.run(tasks);
    final d = difference(p.doc, target);
    if (d != null) throw StateError('the replacement does not reach the target: $d');
    return p.ops;
  }

  static String? difference(Document a, Document b) {
    const eq = SetEquality<String>();
    if (!eq.equals(a.nodes.keys.toSet(), b.nodes.keys.toSet())) return 'nodes';
    for (final id in a.nodes.keys) {
      final x = a.nodes[id]!, y = b.nodes[id]!;
      if (x.type != y.type || x.title != y.title || x.x != y.x || x.y != y.y) return 'node $id';
      for (final key in {...x.config.keys, ...y.config.keys}) {
        final xv = x.config[key], yv = y.config[key];
        if ((xv == null) != (yv == null) || (xv != null && writable(xv) != writable(yv!))) {
          return 'node $id config $key';
        }
      }
    }
    if (!const MapEquality<String, Edge>().equals(a.edges, b.edges)) return 'edges';
    for (final key in {...a.app.keys, ...b.app.keys}) {
      final x = a.app[key] == null ? null : writable(a.app[key]!);
      final y = b.app[key] == null ? null : writable(b.app[key]!);
      if (x != y && !(_isEmpty(x) && _isEmpty(y))) return '${Document.appNode}.$key';
    }
    return null;
  }

  static bool _isEmpty(Value? v) => switch (v) {
    null || VNull() => true,
    VItems(:final items) => items.isEmpty,
    VList(:final items) => items.isEmpty,
    VMap(:final entries) => entries.isEmpty,
    _ => false,
  };

  static Value _emptied(Value v) => switch (v) {
    VItems() => const VItems([]),
    VList() => const VList([]),
    VMap() => const VMap({}),
    VString() => const VString(''),
    _ => const VNull(),
  };
}

class _NotYet implements Exception {
  const _NotYet();
}

class _Planner {
  _Planner(this.doc, this.target, this.client, this.base);
  Document doc;
  final Document target;
  final String client;
  final int base;
  final List<Op> ops = [];

  /// Validates and applies [batch] on a copy; adopts it only if every op is valid. Returns the first refusal.
  RejectReason? tryApply(List<Op> batch) {
    if (batch.isEmpty) return null;
    final d = batch.length == 1 ? doc : doc.clone();
    for (final (i, op) in batch.indexed) {
      final bad = d.validate(op, base: base, client: client);
      if (bad != null) return bad;
      d.apply(op, Stamp(base + ops.length + i + 1, client));
    }
    doc = d;
    ops.addAll(batch);
    return null;
  }

  void must(List<Op> batch) {
    final bad = tryApply(batch);
    if (bad != null) throw StateError('${batch.first}: $bad');
  }

  void run(List<(String, String, String?)> tasks) {
    var pending = tasks;
    while (pending.isNotEmpty) {
      final left = <(String, String, String?)>[];
      String? problem;
      for (final t in pending) {
        try {
          final bad = tryApply(opsFor(t));
          if (bad != null) {
            left.add(t);
            problem ??= '$t: $bad';
          }
        } on _NotYet {
          left.add(t);
          problem ??= '$t: waits for its node';
        }
      }
      if (left.length == pending.length) throw StateError('cannot be written with ops: $problem');
      pending = left;
    }
  }

  List<Op> opsFor((String, String, String?) t) {
    final (kind, id, key) = t;
    switch (kind) {
      case 'app':
        final cur = doc.app[id];
        final tgt = target.app[id] ?? (cur == null ? null : FakeReplacement._emptied(cur));
        if (tgt == null) return const [];
        return register(Document.appNode, id, cur, FakeReplacement.writable(tgt));
      case 'addNode':
        if (doc.nodes.containsKey(id)) return const [];
        final n = target.nodes[id]!;
        return [
          AddNode(
            n.copyWith(
              config: {
                for (final e in n.config.entries)
                  if (FakeReplacement.writable(e.value).liveRefs.every((r) => r.node == id))
                    e.key: FakeReplacement.writable(e.value),
              },
            ),
          ),
        ];
      case 'title':
        final n = doc.nodes[id] ?? (throw const _NotYet());
        final t = target.nodes[id]!.title;
        return n.title == t ? const [] : [SetField(id, const TitleKey(), VString(t))];
      case 'move':
        final n = doc.nodes[id] ?? (throw const _NotYet());
        final t = target.nodes[id]!;
        return n.x == t.x && n.y == t.y ? const [] : [MoveNode(id, t.x, t.y)];
      case 'config':
        final n = doc.nodes[id] ?? (throw const _NotYet());
        return register(id, key!, n.config[key], FakeReplacement.writable(target.nodes[id]!.config[key]!));
      default: // addEdge
        return doc.edges.containsKey(id) ? const [] : [AddEdge(target.edges[id]!)];
    }
  }

  List<Op> register(String node, String key, Value? cur, Value tgt) {
    if (cur != null && FakeReplacement.writable(cur) == tgt) return const [];
    if (cur is VItems && tgt is VItems) {
      final item = itemOps(node, [key], cur.items, tgt.items);
      if (item != null) return item;
    }
    return [
      SetField(node, ConfigKey([key]), tgt),
    ];
  }

  List<Op>? itemOps(String node, List<String> path, List<Item> c, List<Item> t) {
    final cIds = {for (final i in c) i.id}, tIds = {for (final i in t) i.id};
    const eq = ListEquality<String>();
    if (!eq.equals(
      [
        for (final i in c)
          if (tIds.contains(i.id)) i.id,
      ],
      [
        for (final i in t)
          if (cIds.contains(i.id)) i.id,
      ],
    )) {
      return null;
    }
    if (t.any((i) => !cIds.contains(i.id) && doc.deletedItems.containsKey(i.id))) return null;
    final old = {for (final i in c) i.id: FakeReplacement.writable(i.value)};
    final out = <Op>[
      for (final i in c)
        if (!tIds.contains(i.id)) RemoveItem(node, path, i.id),
    ];
    var unchanged = 0;
    for (final i in t) {
      final o = old[i.id];
      if (o == null) continue;
      if (o == i.value) {
        unchanged++;
      } else {
        out.add(UpdateItem(node, path, i.id, i.value));
      }
    }
    String? after;
    for (final i in t) {
      if (!cIds.contains(i.id)) out.add(InsertItem(node, path, i, after));
      after = i.id;
    }
    return unchanged > 0 || out.length <= 1 ? out : null;
  }
}
