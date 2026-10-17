import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_bodies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

export 'harness.dart';

/// [openCorePanel] with the Code and Template bodies; the urls opened go to [urls].
Future<CorePanel> openCodePanel(
  WidgetTester t,
  List<Node> nodes,
  String nodeId, {
  List<Edge> edges = const [],
  CorePanelHostData Function(CorePanel p)? host,
  bool readOnly = false,
  List<String>? urls,
}) => openCorePanel(
  t,
  nodes,
  nodeId,
  edges: edges,
  host: host,
  readOnly: readOnly,
  options: WorkflowMenuOptions(openUrl: urls?.add),
  view: const Size(1200, 1600),
);
