import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/if_else_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

export 'harness.dart';

/// [child] in a Material app with Dify's test translator, 400 px wide at the top left.
Future<void> renderIfElse(WidgetTester t, Widget child) async {
  useDifyTestTranslator();
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 400, child: child),
        ),
      ),
    ),
  );
  await settle(t);
}

/// [ifElsePanelBody] for [nodeId] over [nodes] (the core registry is wired by the app, so the body is used directly).
Future<CorePanel> openIfElsePanel(
  WidgetTester t,
  List<Node> nodes,
  String nodeId, {
  List<Edge> edges = const [],
  bool readOnly = false,
}) => openCorePanel(t, nodes, nodeId, edges: edges, readOnly: readOnly);
