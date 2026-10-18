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
  final visualChanges = ChangeNotifier();

  /// Iteration warnings already shown in this editor, never part of the shared document.
  final parallelWarnings = <String>{};
  final selection = CanvasSelection();
  final ValueNotifier<ControlMode> controlMode;

  /// The nodes on the canvas (set while a WorkflowCanvas shows this controller).
  CanvasGraph? graph;

  /// The node drawn by a live widget instead of its card (the selected note's editor), if any.
  final liveCard = ValueNotifier<LiveCard?>(null);

  /// The run fields shown on the nodes, by node id (a node missing is [NodeRunView.idle]). Local view state set by
  /// the run (never part of the document).
  final nodeRun = ValueNotifier<Map<String, NodeRunView>>(const {});

  /// The run fields shown on the edges, by edge id (an edge missing is [EdgeRunView.idle]).
  final edgeRun = ValueNotifier<Map<String, EdgeRunView>>(const {});

  /// Dify's `nodesReadOnly` for the canvas's own gestures (React Flow's `nodesDraggable` / `nodesConnectable` and the
  /// delete key are off while it is true). The workflow editor points it at its store.
  bool Function() isReadOnly = _never;

  static bool _never() => false;

  /// React Flow's `isValidConnection` (with Dify's handleNodeConnect checks): whether dropping a connection from
  /// [sourceHandle] of [source] on [target] adds an edge. The workflow editor points it at Dify's rules.
  bool Function(String source, String sourceHandle, String target) isValidConnection = _anyConnection;

  static bool _anyConnection(String source, String sourceHandle, String target) => true;

  /// React Flow's `onNodeDrag` for the node under the pointer: [position] is where the drag puts its top-left; the
  /// answer is where it goes instead (Dify snaps it to the helplines), null to leave it. Top-level nodes only.
  Offset? Function(String nodeId, Offset position)? onNodeDrag;

  /// React Flow's `onNodeDragStop` (Dify clears the helplines).
  VoidCallback? onNodeDragStop;

  /// React Flow's `onConnectStart` / `onConnectEnd`: a connection is dragged out of [handleId] of [nodeId], and the
  /// drag ended (connected or not).
  void Function(String nodeId, String handleId)? onConnectStart;
  VoidCallback? onConnectEnd;

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
    visualChanges.dispose();
    selection.dispose();
    controlMode.dispose();
    liveCard.dispose();
    nodeRun.dispose();
    edgeRun.dispose();
  }
}
