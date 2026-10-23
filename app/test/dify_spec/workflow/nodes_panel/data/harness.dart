import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';
import '../../context_menu/harness.dart';

export '../../../dify_test_i18n.dart';
export '../../context_menu/harness.dart';

/// A node from Dify's node [data] (with `type` and `title`), as the DSL import makes it: two-part selectors to
/// [others] become references, `variables` and the like keyed lists. [parent] puts it in a container.
Node difyNode(
  String id,
  Map<String, Object?> data, {
  List<Node> others = const [],
  String? parent,
  int x = 0,
  int y = 0,
  int w = 240,
  int h = 90,
}) => nodeFromDify(
  {
    'id': id,
    'type': 'custom',
    'position': {'x': x, 'y': y},
    'width': w,
    'height': h,
    'parentId': ?parent,
    'data': {'title': data['title'] ?? id, ...data},
  },
  Document(nodes: others),
  id: id,
);

/// An edge [source] -> [target] (Dify's default handles).
Edge edge(String source, String target, {String sourceHandle = 'source'}) =>
    Edge(id: '$source-$sourceHandle-$target', source: source, sourceHandle: sourceHandle, target: target);

/// Renders node [id]'s panel body from [body] (rebuilt whenever the document changes), [width] wide in a
/// scrollable panel column, under a [DataPanelHost] with [toast] / [openUrl] and [host] (node-specific host widgets
/// around the body).
Future<void> renderBody(
  WidgetTester t,
  Harness h,
  String id,
  NodePanelBodyBuilder body, {
  double width = 420,
  WorkflowMenuOptions options = const WorkflowMenuOptions(),
  DataToast? toast,
  ValueChanged<String>? openUrl,
  Widget Function(Widget child)? host,
}) async {
  useDifyTestTranslator();
  final actions = h.actions(options);
  Widget content = ListenableBuilder(
    listenable: h.controller,
    builder: (context, _) {
      final node = h[id];
      if (node == null) return const SizedBox.shrink();
      return body(context, NodePanelProps(node: node, controller: h.controller, actions: actions));
    },
  );
  if (host != null) content = host(content);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: DataPanelHost(
            toast: toast,
            openUrl: openUrl,
            child: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(child: content),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await Harness.settle(t);
}

/// Node [id]'s Dify data now.
Map<String, Object?> dataOf(Harness h, String id) => difyDataOf(h[id]!);

/// Moves the focus away (commits text drafts) and lets the edit land.
Future<void> blur(WidgetTester t) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await Harness.settle(t);
}

/// The toasts shown, as `(type, message)`.
class Toasts {
  final list = <(DataToastType, String)>[];
  void call(DataToastType type, String message) => list.add((type, message));
  List<String> get messages => [for (final (_, m) in list) m];
}
