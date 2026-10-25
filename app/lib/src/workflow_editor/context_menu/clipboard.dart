import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/services.dart';

import '../store/workflow_store.dart' show DifyJson;

/// utils/clipboard.ts: Dify's clipboard holds React Flow nodes and edges (Dify's JSON), in the store and on the
/// system clipboard as `{"kind": "dify-workflow-clipboard", "version": <app DSL version>, "nodes", "edges"}`, so
/// copies move between this app and Dify in a browser.
const workflowClipboardKind = 'dify-workflow-clipboard';

class WorkflowClipboardReadResult {
  const WorkflowClipboardReadResult({
    this.nodes = const [],
    this.edges = const [],
    this.sourceVersion,
    this.isVersionMismatch = false,
    this.agentPackages = const {},
  });

  static const empty = WorkflowClipboardReadResult();

  final List<DifyJson> nodes;
  final List<DifyJson> edges;
  final String? sourceVersion;
  final bool isVersionMismatch;
  final DifyJson agentPackages;
}

bool isClipboardNodeStructurallyValid(Object? v) {
  if (v is! Map || v['id'] is! String || v['type'] is! String || v['data'] is! Map) return false;
  final p = v['position'];
  return p is Map && p['x'] is num && p['y'] is num && (p['x'] as num).isFinite && (p['y'] as num).isFinite;
}

bool isClipboardEdgeStructurallyValid(Object? v) =>
    v is Map && v['id'] is String && v['source'] is String && v['target'] is String;

WorkflowClipboardReadResult parseWorkflowClipboardText(String text, String currentClipboardVersion) {
  if (text.isEmpty) return WorkflowClipboardReadResult.empty;
  try {
    final parsed = jsonDecode(text);
    if (parsed is! Map ||
        parsed['kind'] != workflowClipboardKind ||
        parsed['version'] is! String ||
        parsed['nodes'] is! List ||
        parsed['edges'] is! List) {
      return WorkflowClipboardReadResult.empty;
    }
    final version = parsed['version'] as String;
    return WorkflowClipboardReadResult(
      nodes: [
        for (final n in parsed['nodes'] as List)
          if (isClipboardNodeStructurallyValid(n)) (n as Map).cast<String, Object?>(),
      ],
      edges: [
        for (final e in parsed['edges'] as List)
          if (isClipboardEdgeStructurallyValid(e)) (e as Map).cast<String, Object?>(),
      ],
      agentPackages: parsed['agent_packages'] is Map
          ? (parsed['agent_packages'] as Map).cast<String, Object?>()
          : const {},
      sourceVersion: version,
      isVersionMismatch: version != currentClipboardVersion,
    );
  } on FormatException {
    return WorkflowClipboardReadResult.empty;
  }
}

String stringifyWorkflowClipboardData(
  ({List<DifyJson> nodes, List<DifyJson> edges}) payload,
  String currentClipboardVersion, {
  DifyJson agentPackages = const {},
}) => jsonEncode({
  'kind': workflowClipboardKind,
  'version': currentClipboardVersion,
  'nodes': payload.nodes,
  'edges': payload.edges,
  if (agentPackages.isNotEmpty) 'agent_packages': agentPackages,
});

Future<void> writeWorkflowClipboard(
  ({List<DifyJson> nodes, List<DifyJson> edges}) payload,
  String currentClipboardVersion, {
  DifyJson agentPackages = const {},
}) => Clipboard.setData(
  ClipboardData(text: stringifyWorkflowClipboardData(payload, currentClipboardVersion, agentPackages: agentPackages)),
);

Future<WorkflowClipboardReadResult> readWorkflowClipboard(String currentClipboardVersion) async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return parseWorkflowClipboardText(data?.text ?? '', currentClipboardVersion);
  } catch (_) {
    return WorkflowClipboardReadResult.empty;
  }
}

// ----- document nodes <-> Dify's React Flow JSON (what the server's DSL converter does, DifyDSL.swift) -----

/// React Flow's node type of a document node (`custom`, `custom-note`, `custom-iteration-start`, ...).
String reactFlowTypeOf(Node n) => switch (n.config['_dify_node']) {
  VMap(:final entries) => switch (entries['type']) {
    VString(:final value) => value,
    _ => _defaultReactFlowType(n.type),
  },
  _ => _defaultReactFlowType(n.type),
};

/// The React Flow node type Dify gives a block it creates (constants.ts: CUSTOM_SIMPLE_NODE, CUSTOM_ITERATION_START_NODE…).
String _defaultReactFlowType(String type) => switch (type) {
  'loop-end' => 'custom-simple',
  'iteration-start' => 'custom-iteration-start',
  'loop-start' => 'custom-loop-start',
  'datasource-empty' => 'custom-data-source-empty',
  _ => 'custom',
};

bool isNoteNode(Node n) => reactFlowTypeOf(n) == 'custom-note';

/// Node types whose `outputs` is a map `{name: spec}` in Dify and keyed items here.
const _outputMaps = {'code'};

/// (node type, config key, item key): Dify arrays kept as keyed lists (`*` = any type).
const _keyedLists = [
  ('*', 'variables', 'variable'),
  ('end', 'outputs', 'variable'),
  ('if-else', 'cases', 'case_id'),
  ('llm', 'prompt_template', 'id'),
  ('loop', 'loop_variables', 'id'),
  ('loop', 'break_conditions', 'id'),
];

/// A document value as Dify's plain JSON: keyed lists become arrays, references `[node, output]`.
Object? plainJson(Value v) => switch (v) {
  VItems(:final items) => [for (final i in items) plainJson(i.value)],
  VRef(:final ref) || VBroken(:final ref) => [ref.node, ref.output],
  VList(:final items) => [for (final i in items) plainJson(i)],
  VMap(:final entries) => {for (final e in entries.entries) e.key: plainJson(e.value)},
  _ => v.toJson(),
};

/// The React Flow node Dify would have for [n] (`id`, `type`, `position`, `data`, and the stored extras).
DifyJson difyNodeOf(Node n) {
  final extra = n.config['_dify_node'];
  final top = <String, Object?>{if (extra is VMap) ...plainJson(extra)! as Map<String, Object?>};
  top['type'] ??= 'custom';
  final exact = top['position'];
  top['position'] =
      exact is Map &&
          exact['x'] is num &&
          exact['y'] is num &&
          (exact['x'] as num).round() == n.x &&
          (exact['y'] as num).round() == n.y
      ? exact
      : {'x': n.x, 'y': n.y};
  final data = <String, Object?>{};
  for (final MapEntry(:key, :value) in n.config.entries) {
    if (key == '_dify_node') continue;
    if (key == 'outputs' && _outputMaps.contains(n.type) && value is VItems) {
      // The converter's export: a spec that is only a value is written as the value.
      data[key] = {
        for (final i in value.items)
          if (plainJson(i.value) case final Map<String, Object?> spec)
            (spec.remove('name') as String?) ?? i.id: spec.length == 1 && spec.containsKey('value')
                ? spec['value']
                : spec,
      };
      continue;
    }
    data[key] = plainJson(value);
  }
  data['type'] = n.type;
  data['title'] = n.title;
  return {...top, 'id': n.id, 'data': data};
}

/// The React Flow edge Dify would have for [e] (the converter's derived fields).
DifyJson difyEdgeOf(Edge e, Document doc) {
  String? parentOf(String id) => switch (doc.nodes[id]?.config['_dify_node']) {
    VMap(:final entries) => switch (entries['parentId']) {
      VString(:final value) => value,
      _ => null,
    },
    _ => null,
  };
  final parent = parentOf(e.target);
  final parentType = parent == null ? null : doc.nodes[parent]?.type;
  return {
    'id': e.id,
    'type': 'custom',
    'source': e.source,
    'sourceHandle': e.sourceHandle,
    'target': e.target,
    'targetHandle': e.targetHandle,
    'data': {
      'sourceType': doc.nodes[e.source]?.type ?? '',
      'targetType': doc.nodes[e.target]?.type ?? '',
      'isInIteration': parentType == 'iteration',
      if (parentType == 'iteration') 'iteration_id': parent,
      'isInLoop': parentType == 'loop',
      if (parentType == 'loop') 'loop_id': parent,
    },
    'zIndex': parent == null ? 0 : 1002,
  };
}

/// A document node from Dify's React Flow JSON [json]: `data` (without `type`, `title`, `selected` and Dify's
/// `_` runtime flags) becomes the config, the other fields `_dify_node`; `[node, output]` pairs naming an output
/// of a node in [doc] become references. Throws [FormatException] on values the document cannot hold.
Node nodeFromDify(DifyJson json, Document doc, {required String id}) {
  final data = (json['data'] as Map).cast<String, Object?>();
  final type = data['type'] is String ? data['type']! as String : '';
  final pos = json['position'] as Map;
  final x = (pos['x'] as num).round(), y = (pos['y'] as num).round();
  final config = <String, Value>{};
  for (final MapEntry(:key, :value) in data.entries) {
    if (key == 'type' || key == 'title' || key == 'selected' || key.startsWith('_')) continue;
    config[key] = _value(value, doc);
  }
  for (final (t, key, itemKey) in _keyedLists) {
    if ((t == '*' || t == type) && config[key] is VList) {
      final items = _keyed((config[key]! as VList).items, itemKey);
      if (items != null) config[key] = VItems(items);
    }
  }
  if (_outputMaps.contains(type) && data['outputs'] is Map) {
    final outs = (data['outputs'] as Map).cast<String, Object?>();
    config['outputs'] = VItems([
      for (final name in outs.keys.toList()..sort())
        Item(
          name,
          _value({
            ...(outs[name] is Map ? outs[name]! as Map : {'value': outs[name]}),
            'name': name,
          }, doc),
        ),
    ]);
  }
  final extra = <String, Object?>{
    for (final MapEntry(:key, :value) in json.entries)
      if (!const {'id', 'data', 'position', 'positionAbsolute', 'selected', 'dragging'}.contains(key)) key: value,
    if (pos['x'] != x || pos['y'] != y) 'position': {'x': pos['x'], 'y': pos['y']},
  };
  if (extra.isNotEmpty) config['_dify_node'] = _value(extra, doc);
  return Node(
    id: id,
    type: type,
    title: data['title'] is String ? data['title']! as String : '',
    x: x,
    y: y,
    config: config,
  );
}

Value _value(Object? v, Document doc) {
  if (v is List && v.length == 2 && v[0] is String && v[1] is String) {
    final target = doc.nodes[v[0]];
    final outs = target == null ? null : Document.declaredOutputs(target);
    if (target != null && (outs == null || outs.contains(v[1]))) return VRef(OutputRef(v[0] as String, v[1] as String));
  }
  if (v is List) return VList([for (final i in v) _value(i, doc)]);
  if (v is Map) {
    final m = <String, Value>{};
    for (final MapEntry(:key, :value) in v.entries) {
      if (key is! String || key.startsWith(r'$')) throw FormatException('unsupported key $key');
      m[key] = _value(value, doc);
    }
    return VMap(m);
  }
  return Value.fromJson(v);
}

List<Item>? _keyed(List<Value> xs, String key) {
  final seen = <String>{};
  final out = <Item>[];
  for (final x in xs) {
    if (x is! VMap) return null;
    final id = x.entries[key];
    if (id is! VString || id.value.isEmpty || !seen.add(id.value)) return null;
    out.add(Item(id.value, x));
  }
  return out;
}
