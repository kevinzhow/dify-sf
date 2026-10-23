import 'dart:convert';
import 'dart:io';

import 'package:dify_sf_app/src/workflow_editor/organize/elk_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ELK graph builder against Dify's own TypeScript `buildPortAwareGraph` output: every case of
/// packages/elk_layered/research/builder_cases.json (the builder's inputs) built here and serialised must equal the
/// graph in research/graphs.json (what Dify's builder produced for elkjs), byte for byte.
void main() {
  const research = '../packages/elk_layered/research';
  final cases = jsonDecode(File('$research/builder_cases.json').readAsStringSync()) as List;
  final graphs = {
    for (final r in jsonDecode(File('$research/graphs.json').readAsStringSync()) as List)
      (r as Map)['id']: r['graph'] as Map<String, Object?>,
  };

  test('all ${cases.length} builder cases have Dify\'s graph', () {
    expect(cases, hasLength(126));
    expect(graphs.keys.toSet(), {for (final c in cases) (c as Map)['id']});
  });

  for (final c in cases.cast<Map<String, Object?>>()) {
    final id = c['id']! as String;
    test(id, () {
      final nodes = (c['nodes']! as List).cast<Map<String, Object?>>();
      final edges = (c['edges']! as List).cast<Map<String, Object?>>();
      final expected = graphs[id]!;
      // Container interiors use Dify's child option set (the corpus lays some random graphs out with it too).
      final child = jsonEncode(expected['layoutOptions']) == jsonEncode(childLayoutOptions);
      final g = buildPortAwareGraph(nodes, edges);
      final graph = {
        // A container's interior is named after the container (getLayoutForChildNodes).
        'id': nodes.first['parentId'] ?? 'workflow-root',
        'layoutOptions': child ? childLayoutOptions : rootLayoutOptions,
        'children': g.elkNodes,
        'edges': g.elkEdges,
      };
      expect(jsonEncode(graph), jsonEncode(expected));
      // The editor's top-level filters keep these inputs whole.
      if (!child) expect(jsonEncode(rootElkGraph(nodes, edges)), jsonEncode(expected));
    });
  }
}
