import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

export 'harness.dart';

/// [openCorePanel] for the aggregator's body (before it is registered in the core bodies).
Future<CorePanel> openAggregatorPanel(
  WidgetTester t,
  List<Node> nodes,
  String nodeId, {
  List<Edge> edges = const [],
  bool readOnly = false,
}) => openCorePanel(t, nodes, nodeId, edges: edges, readOnly: readOnly);

/// [child] 400 wide in a Material app with Dify's test translator.
Future<void> renderWidget(WidgetTester t, Widget child) async {
  useDifyTestTranslator();
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: SizedBox(width: 400, child: child),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}
