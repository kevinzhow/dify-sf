import 'package:collab_client/collab_client.dart';

Node node(String id, [Map<String, Value> cfg = const {}]) => Node(id: id, type: 'llm', config: cfg);
Stamp stamp(int seq, String c) => Stamp(seq, c);
Op setStr(String n, List<String> path, String v) => SetField(n, ConfigKey(path), VString(v));
Op setPrompt(String n, String v) => setStr(n, ['prompt'], v);
Op ins(String n, String id, {String? after}) => InsertItem(n, ['outs'], Item(id, VString(id)), after);
Value ref(String n, [String o = 'o']) => VRef(OutputRef(n, o));

/// Ids of the items of list `outs` on node [n].
List<String> outIds(Document d, String n) {
  final v = d.nodes[n]!.config['outs'];
  return v is VItems ? [for (final i in v.items) i.id] : const [];
}

Object? cfg(Document d, String n, String key) => d.nodes[n]?.config[key]?.toJson();

/// A fresh two-node document like the Swift tests use.
Document baseDoc() => Document(nodes: [node('a'), node('b')]);
