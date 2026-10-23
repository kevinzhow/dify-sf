import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../context_menu/harness.dart';

export '../../../../dify_test_i18n.dart';
export '../../../context_menu/harness.dart';

/// A node of [type] whose config is Dify's [data] (plain JSON; `title` becomes the node title).
Node difyNode(String id, String type, Map<String, Object?> data) => node(
  id,
  type: type,
  title: data['title'] as String? ?? 'Node $id',
  config: {
    for (final e in data.entries)
      if (e.key != 'title' && e.key != 'type') e.key: Value.of(e.value),
  },
);

/// Renders [body] for node [id] of [h] (rebuilt on every document change) under [wrap] (the host scopes), 420 wide.
Future<void> pumpBody(
  WidgetTester t,
  Harness h,
  String id,
  NodePanelBodyBuilder body, {
  Widget Function(Widget child)? wrap,
}) async {
  final actions = h.actions();
  Widget content = ListenableBuilder(
    listenable: h.controller,
    builder: (context, _) => h[id] == null
        ? const SizedBox()
        : body(context, NodePanelProps(node: h[id]!, controller: h.controller, actions: actions)),
  );
  content = wrap?.call(content) ?? content;
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 420, child: SingleChildScrollView(child: content)),
          ),
        ),
      ),
    ),
  );
  await Harness.settle(t);
}
