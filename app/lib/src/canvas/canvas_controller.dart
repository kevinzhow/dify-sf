import 'dart:math';

import 'package:flutter/widgets.dart';

import 'canvas_graph.dart';
import 'canvas_input.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'live_card.dart';

/// What the editor around the canvas (Dify's header, toolbars, minimap, menus) sees of the canvas and can do to it:
/// the view, the selection, the control mode, and React Flow's viewport helpers with React Flow's numbers.
class CanvasController {
  CanvasController({ControlMode mode = ControlMode.pointer}) : controlMode = ValueNotifier(mode);

  final view = CanvasViewState();
  final selection = CanvasSelection();
  final ValueNotifier<ControlMode> controlMode;

  /// The nodes on the canvas (set while a WorkflowCanvas shows this controller).
  CanvasGraph? graph;

  /// The node drawn by a live widget instead of its card (the selected note's editor), if any.
  final liveCard = ValueNotifier<LiveCard?>(null);

  /// Dify's `nodesReadOnly` for the canvas's own gestures (React Flow's `nodesDraggable` / `nodesConnectable` and the
  /// delete key are off while it is true). The workflow editor points it at its store.
  bool Function() isReadOnly = _never;

  static bool _never() => false;

  /// React Flow's zoomIn/zoomOut: d3 `scaleBy(1.2)` around the viewport's middle.
  static const zoomStep = 1.2;

  void zoomIn() => zoomTo(view.scale * zoomStep);
  void zoomOut() => zoomTo(view.scale / zoomStep);

  /// React Flow's zoomTo: the zoom changes around the viewport's middle.
  void zoomTo(double scale) =>
      view.zoomAt(Offset(view.viewport.width / 2, view.viewport.height / 2), scale / view.scale);

  /// React Flow's setViewport: screen = canvas * [zoom] + ([x], [y]).
  void setViewport(double x, double y, double zoom) {
    view
      ..scale = zoom
      ..center = (Offset(view.viewport.width / 2, view.viewport.height / 2) - Offset(x, y)) / view.scale;
  }

  /// React Flow's fitView (padding 0.1, Dify's zoom range): the nodes' bounds, centred, as large as fits.
  void fitView({double padding = 0.1}) {
    final g = graph;
    if (g == null || g.length == 0 || view.viewport.isEmpty) return;
    final b = g.bounds;
    final zoom = min(
      view.viewport.width / (b.width * (1 + padding)),
      view.viewport.height / (b.height * (1 + padding)),
    ).clamp(CanvasViewState.minScale, CanvasViewState.maxScale);
    view
      ..scale = zoom
      ..center = b.center;
  }

  void dispose() {
    view.dispose();
    selection.dispose();
    controlMode.dispose();
    liveCard.dispose();
  }
}
