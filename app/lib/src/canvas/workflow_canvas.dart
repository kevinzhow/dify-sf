import 'dart:async';

import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import 'canvas_a11y.dart';
import 'canvas_background.dart';
import 'canvas_controller.dart';
import 'card_controls.dart';
import 'canvas_graph.dart';
import 'canvas_input.dart';
import 'edge_curve.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'live_card.dart';
import '../cards/dify_cards.dart';
import 'node_card.dart';
import 'renderer_choice.dart';
import 'scene_renderer.dart';
import 'widget_renderer.dart';

/// Process-wide canvas defaults (from the launch options).
abstract final class CanvasDefaults {
  /// The first view as a React Flow viewport (x, y, zoom); null fits the graph.
  static (double, double, double)? viewport;

  /// Visual tests: print the canvas's rectangle on screen (`CANVAS_RECT left,top,width,height`) once it is laid out.
  static bool reportRect = false;

  /// Visual tests: the node selected once the document is shown (its panel opens, as after a click in Dify).
  static String? select;

  static (double, double, double)? parseViewport(String? s) {
    final p = s?.split(',').map(double.tryParse).toList();
    if (p == null || p.length != 3 || p.contains(null)) return null;
    return (p[0]!, p[1]!, p[2]!);
  }
}

/// The workflow canvas: the document's nodes and edges, drawn by Flutter Scene (or plain widgets where Flutter GPU is
/// not available), with selection, moving, connecting, panning and zooming. Edits go through [controller].
class WorkflowCanvas extends StatefulWidget {
  const WorkflowCanvas({
    super.key,
    required this.controller,
    this.canvas,
    this.cards = const DifyCards(),
    this.renderer,
  });

  final EditorController controller;

  /// The view, selection and control mode, shared with the editor around the canvas; null: the canvas keeps its own.
  final CanvasController? canvas;
  final CardSpec cards;

  /// Forces a renderer; by default Flutter Scene, or widgets under `flutter test`.
  final CanvasRendererKind? renderer;

  @override
  State<WorkflowCanvas> createState() => WorkflowCanvasState();
}

class WorkflowCanvasState extends State<WorkflowCanvas> {
  late final graph = CanvasGraph(layoutOf: widget.cards.layoutOf);
  late final CanvasController canvas = widget.canvas ?? (_ownCanvas = CanvasController());
  CanvasController? _ownCanvas;
  CanvasViewState get view => canvas.view;
  CanvasSelection get selection => canvas.selection;
  late final CanvasInput input;
  late final CanvasA11y a11y;
  late final live = LiveCardLayer(
    source: canvas.liveCard,
    graph: graph,
    // Edges lie over underlays (notes).
    isTopAt: (n, p) {
      final top = input.nodeAt(p);
      return (top == null || top.slot == n.slot) && !(n.layout.underlay && input.edgeAt(p) != null);
    },
    claim: (e) => input.claim(e),
  );
  late CanvasRendererKind kind;
  late CanvasRenderer renderer;
  final _focus = FocusNode(debugLabel: 'canvas');
  bool _fitted = false;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    canvas.graph = graph;
    kind = widget.renderer ?? defaultRendererKind();
    renderer = _makeRenderer(kind);
    input = CanvasInput(
      controller: c,
      graph: graph,
      view: view,
      selection: selection,
      renderer: () => renderer,
      modeSource: canvas.controlMode,
      readOnly: () => canvas.isReadOnly(),
      validConnection: (source, handle, target) => canvas.isValidConnection(source, handle, target),
      nodeDrag: () => canvas.onNodeDrag,
      nodeDragStop: () => canvas.onNodeDragStop,
      connectStart: () => canvas.onConnectStart,
      connectEnd: () => canvas.onConnectEnd,
    );
    input.onApplied = (_) => canvas.visualChanges.notifyListeners();
    a11y = CanvasA11y(
      graph: graph,
      view: view,
      selection: selection,
      onTap: (n) {
        // Comment mode: a node's button does not select it (Dify's node.tsx guard).
        if (canvas.controlMode.value == ControlMode.comment) return;
        selection.selectNodes([n.slot]);
        c.selectNode(n.id);
      },
      onKey: (n, e) => input.nodeKey(n, e),
    );
    view.addListener(a11y.viewMoved);
    view.addListener(_viewMoved);
    selection.addListener(_selectionChanged);
    c.addListener(_documentChanged);
    canvas.nodeRun.addListener(_runStatusChanged);
    canvas.edgeRun.addListener(_edgeRunChanged);
    _documentChanged();
    if (canvas.edgeRun.value.isNotEmpty) _edgeRunChanged();
  }

  Map<String, NodeRunView> _shownRun = const {};

  /// Shows [CanvasController.nodeRun] on the nodes: only the nodes whose run view changed are touched.
  void _runStatusChanged({bool all = false}) {
    final next = canvas.nodeRun.value, old = _shownRun;
    _shownRun = next;
    final ids = all ? graph.nodes.map((n) => n.id) : {...old.keys, ...next.keys};
    for (final id in ids) {
      setRun(id, next[id] ?? NodeRunView.idle);
    }
  }

  /// Shows [CanvasController.edgeRun] on the edges.
  void _edgeRunChanged() {
    graph.edgeRun = canvas.edgeRun.value;
    renderer.edgeRunChanged();
  }

  Timer? _rest;

  /// Publishes where the view came to rest (cards tied to the viewport redraw then, not while it moves).
  void _viewMoved() {
    _rest?.cancel();
    _rest = Timer(const Duration(milliseconds: 150), () {
      graph.restingOrigin.value = view.toScreen(Offset.zero);
      if (CanvasDefaults.reportRect) {
        final o = graph.restingOrigin.value;
        debugPrint('CANVAS_VIEW ${o.dx},${o.dy},${view.scale}');
      }
    });
  }

  CanvasRenderer _makeRenderer(CanvasRendererKind k) => switch (k) {
    CanvasRendererKind.scene => SceneRenderer(
      graph: graph,
      view: view,
      selection: selection,
      cards: widget.cards,
      live: live,
      onUnavailable: _fallBackToWidgets,
      onSettled: CanvasDefaults.reportRect ? () => debugPrint('CANVAS_SETTLED') : null,
    ),
    CanvasRendererKind.widgets => WidgetRenderer(
      graph: graph,
      view: view,
      selection: selection,
      cards: widget.cards,
      live: live,
    ),
  };

  /// Flutter Scene could not start (no Flutter GPU): draw with widgets instead.
  void _fallBackToWidgets(Object error) {
    if (!mounted || kind == CanvasRendererKind.widgets) return;
    debugPrint('canvas: Flutter Scene unavailable ($error); drawing with widgets');
    setState(() {
      renderer.dispose();
      kind = CanvasRendererKind.widgets;
      renderer = _makeRenderer(kind);
      renderer.apply(_everything());
    });
  }

  CanvasChange _everything() {
    final change = CanvasChange()..edgesChanged = true;
    change.added.addAll(graph.nodes);
    return change;
  }

  void _documentChanged() {
    final change = graph.sync(c.doc);
    for (final n in change.removed) {
      selection.forget(n.slot);
    }
    if (!change.isEmpty) {
      renderer.apply(change);
      a11y.changed();
      if (change.added.isNotEmpty && canvas.nodeRun.value.isNotEmpty) _runStatusChanged(all: true);
    }
    // The panel (or a test) selected a node or an edge: show it.
    final id = c.selectedNodeId;
    final slot = id == null ? null : graph[id]?.slot;
    if (slot != null && !(selection.nodes.length == 1 && selection.nodes.contains(slot))) {
      selection.selectNodes([slot]);
    } else if (id == null && c.selectedEdgeId != selection.edge) {
      selection.selectEdge(c.selectedEdgeId);
    }
    if (!_fitted && graph.length > 0 && !view.viewport.isEmpty) _fit();
  }

  int? _hovered;

  void _selectionChanged() {
    if (selection.hovered != _hovered) {
      if (_hovered != null) graph.slots[_hovered!]?.hovered.value = false;
      _hovered = selection.hovered;
      if (_hovered != null) graph.slots[_hovered!]?.hovered.value = true;
    }
    final resized = CanvasChange();
    for (final slot in selection.changed) {
      final n = graph.slots[slot];
      if (n == null) continue;
      n.selected.value = selection.nodes.contains(slot);
      if (widget.cards.layoutDependsOnRun(n.node.value) && graph.relayout(n, c.doc)) resized.resized.add(n);
    }
    if (resized.resized.isNotEmpty) renderer.apply(resized..edgesChanged = true);
    renderer.selectionChanged(selection.changed);
    a11y.changed();
  }

  void _fit() {
    final vp = _fitted ? null : CanvasDefaults.viewport;
    _fitted = true;
    final select = CanvasDefaults.select;
    if (select != null && c.doc.nodes.containsKey(select)) {
      CanvasDefaults.select = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? c.selectNode(select) : null);
    }
    if (vp != null) {
      // React Flow: screen = canvas * zoom + (x, y); our view is the canvas point at the middle of the viewport.
      view
        ..scale = vp.$3
        ..center = (Offset(view.viewport.width / 2, view.viewport.height / 2) - Offset(vp.$1, vp.$2)) / vp.$3;
      return;
    }
    canvas.fitView();
  }

  /// Sets a node's run view (from a run, or a simulation of one); a card whose size depends on it is laid out again.
  void setRun(String id, NodeRunView run) {
    final n = graph[id];
    if (n == null || n.run.value == run) return;
    final statusChanged = n.run.value.status != run.status;
    n.run.value = run;
    n.cardRun.value = run.forCard;
    if (widget.cards.layoutDependsOnRun(n.node.value) && graph.relayout(n, c.doc)) {
      final change = CanvasChange()
        ..resized.add(n)
        ..edgesChanged = true;
      renderer.apply(change);
    }
    renderer.statusChanged(n.slot);
    if (statusChanged) a11y.changed();
  }

  /// Sets a node's run status alone (tests, simulations).
  void setStatus(String id, String status) => setRun(id, NodeRunView(runningStatus: status == 'idle' ? null : status));

  @override
  void dispose() {
    c.removeListener(_documentChanged);
    canvas.nodeRun.removeListener(_runStatusChanged);
    canvas.edgeRun.removeListener(_edgeRunChanged);
    selection.removeListener(_selectionChanged);
    view.removeListener(a11y.viewMoved);
    view.removeListener(_viewMoved);
    _rest?.cancel();
    renderer.dispose();
    input.dispose();
    a11y.dispose();
    _focus.dispose();
    if (canvas.graph == graph) canvas.graph = null;
    _ownCanvas?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != view.viewport) {
          final old = view.viewport;
          view.viewport = size;
          // Like React Flow, a resize keeps the top-left corner of the view where it is (not the middle).
          if (!old.isEmpty) {
            view.center += Offset(size.width - old.width, size.height - old.height) / (2 * view.scale);
          }
          if (CanvasDefaults.reportRect) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              final o = box.localToGlobal(Offset.zero);
              debugPrint('CANVAS_RECT ${o.dx},${o.dy},${box.size.width},${box.size.height}');
            });
          }
          if (!_fitted && graph.length > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _fit() : null);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => a11y.viewMoved());
        }
        return Focus(
          focusNode: _focus,
          // Keys typed into a live card (the note editor) are not the canvas's.
          onKeyEvent: (node, e) => node.hasPrimaryFocus ? input.key(node, e) : KeyEventResult.ignored,
          child: MouseRegion(
            onExit: input.exit,
            child: Listener(
              onPointerDown: (e) {
                if (input.claimed(e)) return;
                _focus.requestFocus();
                input.down(e);
              },
              onPointerMove: input.move,
              onPointerUp: input.up,
              onPointerCancel: input.up,
              onPointerHover: input.hover,
              onPointerSignal: input.signal,
              onPointerPanZoomStart: input.panZoomStart,
              onPointerPanZoomUpdate: input.panZoomUpdate,
              behavior: HitTestBehavior.opaque,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CanvasBackground(key: const Key('canvas-background'), view: view),
                    renderer.build(context),
                    IgnorePointer(
                      child: ValueListenableBuilder<Rect?>(
                        valueListenable: input.marquee,
                        builder: (context, r, _) => CustomPaint(painter: _MarqueePainter(r, scheme.primary)),
                      ),
                    ),
                    // custom-connection-line.tsx's marker at the dragged end (the renderers draw the line).
                    IgnorePointer(
                      child: ValueListenableBuilder<(Offset, Offset)?>(
                        valueListenable: input.connectLine,
                        builder: (context, line, _) => CustomPaint(
                          painter: ConnectionLineMarkerPainter(
                            line == null ? null : view.rectToScreen(connectionLineMarker(line.$2)),
                          ),
                        ),
                      ),
                    ),
                    a11y.build(),
                    CanvasControlLayer(canvas: canvas, cards: widget.cards, input: input, changes: c),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The connection line's target marker, [rect] on screen (none while nothing is being connected).
class ConnectionLineMarkerPainter extends CustomPainter {
  ConnectionLineMarkerPainter(this.rect);
  final Rect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect case final r?) canvas.drawRect(r, Paint()..color = connectionLineMarkerColor);
  }

  @override
  bool shouldRepaint(ConnectionLineMarkerPainter old) => old.rect != rect;
}

class _MarqueePainter extends CustomPainter {
  _MarqueePainter(this.rect, this.color);
  final Rect? rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    canvas
      ..drawRect(r, Paint()..color = color.withValues(alpha: 0.12))
      ..drawRect(
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke,
      );
  }

  @override
  bool shouldRepaint(_MarqueePainter old) => old.rect != rect;
}
