import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import 'canvas_graph.dart';

/// How cards look and where their handles are; [DifyCards] is Dify's.
abstract class CardSpec {
  const CardSpec();

  /// The node's card layout (size, handles), computed from the node's data and the document (for labels of the
  /// variables it references).
  CardLayout layoutOf(Node node, Document doc);

  /// The card for [node]. [live] cards show run status in their content (captures for zoomed-out views leave it
  /// out: the canvas draws status itself). [onPainted] is called after a frame in which the card repainted.
  Widget build(BuildContext context, CanvasNode node, CanvasGraph graph, {required bool live, VoidCallback? onPainted});
}

/// BlockIcon background by node type (block-icon.tsx).
Color blockColor(String type) => switch (type) {
  'start' || 'start-placeholder' => const Color(0xFF085AFC),
  'llm' || 'agent' || 'agent-v2' => const Color(0xFF6172F3),
  'code' ||
  'template-transform' ||
  'variable-assigner' ||
  'variable-aggregator' ||
  'tool' ||
  'assigner' ||
  'parameter-extractor' ||
  'trigger-webhook' ||
  'trigger-plugin' => const Color(0xFF2E90FA),
  'end' || 'answer' || 'loop-end' || 'knowledge-index' => const Color(0xFFF79009),
  'if-else' || 'iteration' || 'loop' || 'list-operator' || 'human-input' => const Color(0xFF06AED4),
  'http-request' || 'trigger-schedule' => const Color(0xFF875BF7),
  'knowledge-retrieval' || 'question-classifier' || 'document-extractor' => const Color(0xFF17B26A),
  'datasource' => const Color(0xFF828DAD),
  _ => const Color(0xFF828DAD),
};
