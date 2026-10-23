import 'package:collab_client/collab_client.dart';

import '../../workflow/dify_json.dart';
import 'checklist/checklist_item.dart';
import 'header_data.dart';

/// The config keys the header reads from nodes (test-run options, the publisher's tool inputs and outputs).
const _keys = ['provider_id', 'plugin_name', 'variables', 'outputs'];

/// What the header shows of [doc]: its nodes (id, type, title, a few fields), whether a Start node leads anywhere,
/// and the [checklist].
WorkflowGraphFacts graphFactsOf(Document doc, {List<ChecklistItem> checklist = const []}) {
  final starts = {
    for (final n in doc.nodes.values)
      if (n.type == 'start') n.id,
  };
  return WorkflowGraphFacts(
    nodes: [
      for (final n in doc.nodes.values)
        HeaderNode(
          id: n.id,
          type: n.type,
          title: n.title,
          data: {
            for (final k in _keys)
              if (n.config[k] != null) k: plainOf(n.config[k]),
          },
        ),
    ],
    hasUserInputNode: doc.edges.values.any((e) => starts.contains(e.source)),
    checklist: checklist,
  );
}
