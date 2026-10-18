import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import 'canvas_graph.dart';

/// How cards look and where their handles are; [DifyCards] is Dify's.
abstract class CardSpec {
  const CardSpec();

  /// The node's card layout (size, handles), computed from the node's data and the document (for labels of the
  /// variables it references); [run] and [selected] for the cards whose size depends on them
  /// ([layoutDependsOnRun]).
  CardLayout layoutOf(Node node, Document doc, {NodeRunView run = NodeRunView.idle, bool selected = false});

  /// Whether [node]'s layout depends on its run state and selection (the canvas lays it out again when they change).
  bool layoutDependsOnRun(Node node) => false;

  /// Where [node]'s card shows a spinning loader for its run state ([CanvasNode.cardRun], [CanvasNode.selected]),
  /// on the canvas: renderers that cannot animate inside a card draw these themselves (see [CanvasSpinners]).
  List<Rect> spinners(CanvasNode node, CanvasGraph graph) => const [];

  /// The card for [node]. [live] cards show run status in their content (captures for zoomed-out views leave it
  /// out: the canvas draws status itself). [onPainted] is called after a frame in which the card repainted.
  Widget build(BuildContext context, CanvasNode node, CanvasGraph graph, {required bool live, VoidCallback? onPainted});

  /// Live controls, in canvas coordinates. Captured cards reserve their space instead of baking buttons into
  /// textures. The shared canvas layer handles hit testing, dimming and pointer ownership for either renderer.
  List<({Rect rect, Widget child})> controls(BuildContext context, CanvasNode node, CanvasGraph graph) => const [];
}

/// Whether cards below draw their loaders: false where the renderer draws them over the card instead (a captured
/// card cannot animate without being captured every frame); the card leaves their place empty.
class CanvasSpinners extends InheritedWidget {
  const CanvasSpinners({super.key, required this.drawnByCanvas, required super.child});

  final bool drawnByCanvas;

  static bool drawnByCanvasOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CanvasSpinners>()?.drawnByCanvas ?? false;

  @override
  bool updateShouldNotify(CanvasSpinners old) => drawnByCanvas != old.drawnByCanvas;
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

/// Captured cards leave room for controls painted by the shared live control layer.
class CanvasCardControls extends InheritedWidget {
  const CanvasCardControls({super.key, required super.child});
  static bool overlaid(BuildContext context) => context.getInheritedWidgetOfExactType<CanvasCardControls>() != null;
  @override
  bool updateShouldNotify(CanvasCardControls oldWidget) => false;
}
