import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../node_panel/harness.dart';

export 'package:dify_sf_app/src/workflow/dify_json.dart' show plainOf, difyDataOf;

export '../../node_panel/harness.dart';

/// Document nodes from Dify's React Flow nodes (`{id, data, position?}`), converted as an import does: keyed lists,
/// `[node, output]` pairs naming earlier nodes' outputs as references.
List<Node> difyNodes(List<Map<String, Object?>> nodes) {
  final out = <Node>[];
  for (final (i, n) in nodes.indexed) {
    final json = {
      'position': {'x': i * 300, 'y': 0},
      ...n,
    };
    out.add(nodeFromDify(json, Document(nodes: out), id: n['id']! as String));
  }
  return out;
}

/// A Dify node `{id, data: {type, title, ...data}}`.
Map<String, Object?> difyNode(String id, String type, [Map<String, Object?> data = const {}, String? title]) => {
  'id': id,
  'data': {'type': type, 'title': title ?? id, ...data},
};

/// Edges `a -> b` for each pair.
List<Edge> chain(List<String> ids) => [
  for (var i = 0; i + 1 < ids.length; i++) Edge(id: 'e$i', source: ids[i], target: ids[i + 1]),
];

/// The core panel body of [nodeId] in [h]'s editor, rebuilt as the document changes; toasts go to [toasts].
class CorePanel {
  CorePanel(this.h, this.nodeId);
  final Harness h;
  final String nodeId;
  final toasts = <String>[];

  Node get node => h[nodeId]!;

  /// The node's Dify data now.
  Map<String, Object?> get data => difyDataOf(node);

  Future<void> dispose(WidgetTester t) => h.dispose(t);
}

Future<CorePanel> openCorePanel(
  WidgetTester t,
  List<Node> nodes,
  String nodeId, {
  List<Edge> edges = const [],
  WorkflowMenuOptions options = const WorkflowMenuOptions(),
  CorePanelHostData Function(CorePanel panel)? host,
  bool readOnly = false,
  double width = 420,
  Size view = const Size(1200, 900),
  bool scroll = true,
}) async {
  final h = await Harness.start(t, nodes, edges: edges);
  t.view.physicalSize = view;
  useDifyTestTranslator();
  final panel = CorePanel(h, nodeId);
  if (readOnly) h.store.canvasReadOnly.value = true;
  final actions = panelActions(h, options: options);
  final body = ListenableBuilder(
    listenable: h.controller,
    builder: (context, _) {
      final n = h[nodeId]!;
      return corePanelBodies[n.type]!(context, NodePanelProps(node: n, controller: h.controller, actions: actions));
    },
  );
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: CorePanelHost(
            data: host?.call(panel) ?? CorePanelHostData(toastError: panel.toasts.add),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: scroll ? SingleChildScrollView(child: body) : body,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await settle(t);
  return panel;
}

/// A title shown in an `uppercase` style (looked up upper-cased, as a prefix of rich text: a `*` may follow).
Finder findTitle(String text) => find.textContaining(text.toUpperCase(), findRichText: true);
