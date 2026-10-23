import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../node_panel/harness.dart';

export '../../node_panel/harness.dart';

/// A node from Dify's React Flow JSON [data] (as the DSL import makes it: selectors naming outputs of [doc]'s nodes
/// become references), at the left of the canvas, inside [parent].
Node difyNode(String id, String type, Map<String, Object?> data, {Document? doc, String? title, String? parent}) =>
    nodeFromDify(
      {
        'id': id,
        'type': 'custom',
        'position': {'x': 0, 'y': 0},
        'width': 240,
        'height': 100,
        'parentId': ?parent,
        'data': {'type': type, 'title': title ?? type, 'desc': '', ...data},
      },
      doc ?? Document(nodes: const [], edges: const []),
      id: id,
    );

/// A chain of nodes from Dify data, each connected to the next (`start` -> ... -> the node under test), built in
/// order so later nodes' selectors become references to earlier ones.
({List<Node> nodes, List<Edge> edges}) difyChain(List<(String id, String type, Map<String, Object?> data)> chain) {
  final nodes = <Node>[];
  final edges = <Edge>[];
  for (final (i, (id, type, data)) in chain.indexed) {
    nodes.add(
      difyNode(
        id,
        type,
        data,
        doc: Document(nodes: nodes, edges: edges),
      ),
    );
    if (i > 0) edges.add(Edge(id: 'e$i', source: chain[i - 1].$1, target: id));
  }
  return (nodes: nodes, edges: edges);
}

/// The node panel of [id] on [h] with this group's bodies and [services], rebuilt on every document change.
Widget llmPanel(
  Harness h,
  String id, {
  LlmGroupServices services = LlmGroupServices.empty,
  bool chatMode = false,
  bool readOnly = false,
}) => panelApp(
  h,
  LlmGroupScope(
    services: services,
    child: ListenableBuilder(
      listenable: h.controller,
      builder: (context, _) => WorkflowNodePanel(
        key: ValueKey(id),
        node: h[id]!,
        actions: panelActions(
          h,
          options: WorkflowMenuOptions(isChatMode: chatMode, canEdit: !readOnly),
        ),
        bodies: const NodePanelBodies(llmPanelBodies),
      ),
    ),
  ),
);

/// Starts [h] with [chain] (the last node is the one under test), the panel 400 px wide on a wide canvas.
Future<Harness> startPanel(
  WidgetTester t,
  List<(String id, String type, Map<String, Object?> data)> chain, {
  LlmGroupServices services = LlmGroupServices.empty,
  bool chatMode = false,
  bool readOnly = false,
  Size screen = const Size(1400, 1000),
  bool pump = true,
}) async {
  final g = difyChain(chain);
  final h = await Harness.start(t, g.nodes, edges: g.edges);
  t.view.physicalSize = screen;
  h.store
    ..setWorkflowCanvasWidth(screen.width)
    ..setNodePanelWidth(400);
  final id = chain.last.$1;
  h.controller.selectNode(id);
  if (!pump) return h;
  await t.pumpWidget(llmPanel(h, id, services: services, chatMode: chatMode, readOnly: readOnly));
  await settle(t);
  return h;
}

/// The Dify `data` of [id] now.
Map<String, Object?> dataOf(Harness h, String id) => difyDataOf(h[id]!);
