import 'dart:math';

import 'package:flutter/widgets.dart';

import 'canvas_graph.dart';
import 'canvas_input.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'live_card.dart';

/// What the editor around the canvas (Dify's header, toolbars, minimap, menus) sees of the canvas and can do to it:
/// the view, the selection, the control mode, and React Flow's viewport helpers with React Flow's numbers.
class CanvasVisualChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class CanvasDimming {
  const CanvasDimming({required this.nodes, required this.dependencies});
  final Set<String> nodes;
  final List<(String, String)> dependencies;
}

class CanvasController {
  CanvasController({ControlMode mode = ControlMode.pointer}) : controlMode = ValueNotifier(mode);

  final view = CanvasViewState();
  final visualChanges = CanvasVisualChanges();

  /// Iteration warnings already shown in this editor, never part of the shared document.
  final parallelWarnings = <String>{};
  final dimming = ValueNotifier<CanvasDimming?>(null);
  final selection = CanvasSelection();
  final ValueNotifier<ControlMode> controlMode;

  /// The nodes on the canvas (set while a WorkflowCanvas shows this controller).
  CanvasGraph? graph;

  /// Where the canvas's viewport is in the window (set while a WorkflowCanvas shows this controller).
  Offset? Function()? viewportOrigin;

  /// Pans the least so that node [id] is clear above the window's y [coveredFromY] (a phone's half sheet over the
  /// canvas), only when it is covered; its top stays in view.
  void revealAbove(String id, double coveredFromY, {double margin = 16}) {
    final origin = viewportOrigin?.call(), node = graph?[id];
    if (origin == null || node == null) return;
    final r = view.rectToScreen(node.rect).shift(origin);
    final dy = min(r.bottom + margin - coveredFromY, r.top - origin.dy - margin);
    if (dy <= 0) return;
    view.center = view.center + Offset(0, dy / view.scale);
  }

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

  /// Dify's nodeAnimation flag, owned by the workflow store.
  bool Function() animatePositions = _never;

  /// Whether a document move of node [id] glides into place although [animatePositions] is off: a collaborator's move
  /// (presence, protocol 1.22; their drags arrive as positions every 125 ms). Null: never.
  bool Function(String id)? glideMove;

  /// While the user drags nodes: the node under the pointer and the pointer's offset from its top-left (canvas
  /// coordinates). Presence reports it, so the others draw this user's pointer on the node as it moves.
  final dragGrab = ValueNotifier<(String, Offset)?>(null);
  VoidCallback? onInteraction;

  static bool _never() => false;

  /// The phone editor's select mode (dify-sf, compact windows): one finger on empty canvas draws a selection box
  /// (in pointer mode) instead of panning. Off by default, so touch pans everywhere else as before.
  final touchSelect = ValueNotifier<bool>(false);

  /// A finger tapped (pressed and released without dragging) a node's source handle: the phone editor adds the next
  /// node there. Null: such a tap does nothing (a drag from the handle connects either way).
  void Function(String nodeId, String handle)? onHandleTap;

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
  void Function(String source, String handle, String? target, Offset point)? onConnectMove;
  void Function(String source, String handle, String target, Offset point)? onConnectDrop;

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
    dragGrab.dispose();
    dimming.dispose();
    selection.dispose();
    controlMode.dispose();
    touchSelect.dispose();
    liveCard.dispose();
    nodeRun.dispose();
    edgeRun.dispose();
  }
}
