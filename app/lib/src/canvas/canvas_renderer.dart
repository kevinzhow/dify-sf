import 'package:flutter/widgets.dart';

import 'canvas_graph.dart';

/// Draws the canvas. The input, selection and accessibility logic is shared; a renderer only shows things.
/// [SceneRenderer] draws with Flutter Scene; [WidgetRenderer] with plain widgets (tests, and where Flutter GPU is
/// not available).
abstract class CanvasRenderer {
  /// The document changed (after [CanvasGraph.sync]).
  void apply(CanvasChange change);

  /// These nodes are being dragged (lifted, their edges redrawn live) until [endMove].
  void beginMove(Set<int> slots);

  /// Dragged nodes moved.
  void moved(Iterable<int> slots);
  void endMove(Set<int> slots);

  /// The edge being dragged out of a port, from [from] to the pointer [to] (canvas); null hides it.
  void connectPreview(Offset? from, Offset? to);

  /// Selection or hover changed for these slots (and the selected edge may have changed).
  void selectionChanged(Set<int> slots);

  /// A node's run view ([CanvasNode.run]) changed.
  void statusChanged(int slot);

  /// The edges' run views ([CanvasGraph.edgeRun]) changed.
  void edgeRunChanged();

  Widget build(BuildContext context);
  void dispose();
}
