import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import 'canvas_a11y.dart';
import 'canvas_graph.dart';
import 'canvas_input.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'node_card.dart';
import 'renderer_choice.dart';
import 'scene_renderer.dart';
import 'widget_renderer.dart';

/// The workflow canvas: the document's nodes and edges, drawn by Flutter Scene (or plain widgets where Flutter GPU is
/// not available), with selection, moving, connecting, panning and zooming. Edits go through [controller].
class WorkflowCanvas extends StatefulWidget {
  const WorkflowCanvas({super.key, required this.controller, this.cards = const CardSpec(), this.renderer});

  final EditorController controller;
  final CardSpec cards;

  /// Forces a renderer; by default Flutter Scene, or widgets under `flutter test`.
  final CanvasRendererKind? renderer;

  @override
  State<WorkflowCanvas> createState() => WorkflowCanvasState();
}

class WorkflowCanvasState extends State<WorkflowCanvas> {
  late final graph = CanvasGraph(sizeOf: widget.cards.sizeOf);
  final view = CanvasViewState();
  final selection = CanvasSelection();
  late final CanvasInput input;
  late final CanvasA11y a11y;
  late CanvasRendererKind kind;
  late CanvasRenderer renderer;
  final _focus = FocusNode(debugLabel: 'canvas');
  bool _fitted = false;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    kind = widget.renderer ?? defaultRendererKind();
    renderer = _makeRenderer(kind);
    input = CanvasInput(controller: c, graph: graph, view: view, selection: selection, renderer: () => renderer);
    a11y = CanvasA11y(
      graph: graph,
      view: view,
      selection: selection,
      onTap: (n) {
        selection.selectNodes([n.slot]);
        c.selectNode(n.id);
      },
    );
    view.addListener(a11y.viewMoved);
    selection.addListener(_selectionChanged);
    c.addListener(_documentChanged);
    _documentChanged();
  }

  CanvasRenderer _makeRenderer(CanvasRendererKind k) => switch (k) {
    CanvasRendererKind.scene => SceneRenderer(
      graph: graph,
      view: view,
      selection: selection,
      cards: widget.cards,
      onUnavailable: _fallBackToWidgets,
    ),
    CanvasRendererKind.widgets => WidgetRenderer(graph: graph, view: view, selection: selection, cards: widget.cards),
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

  void _selectionChanged() {
    renderer.selectionChanged(selection.changed);
    a11y.changed();
  }

  void _fit() {
    _fitted = true;
    view.fit(graph.bounds);
  }

  /// Sets a node's run status (from a run, or a simulation of one).
  void setStatus(String id, String status) {
    final n = graph[id];
    if (n == null || n.status.value == status) return;
    n.status.value = status;
    renderer.statusChanged(n.slot);
    a11y.changed();
  }

  @override
  void dispose() {
    c.removeListener(_documentChanged);
    selection.removeListener(_selectionChanged);
    view.removeListener(a11y.viewMoved);
    renderer.dispose();
    input.dispose();
    a11y.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != view.viewport) {
          view.viewport = size;
          if (!_fitted && graph.length > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _fit() : null);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) => a11y.viewMoved());
        }
        return Focus(
          focusNode: _focus,
          onKeyEvent: input.key,
          child: MouseRegion(
            onExit: input.exit,
            child: Listener(
              onPointerDown: (e) {
                _focus.requestFocus();
                input.down(e);
              },
              onPointerMove: input.move,
              onPointerUp: input.up,
              onPointerCancel: input.up,
              onPointerHover: input.hover,
              onPointerSignal: input.signal,
              behavior: HitTestBehavior.opaque,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(key: const Key('canvas-background'), color: scheme.surfaceContainerLowest),
                    renderer.build(context),
                    IgnorePointer(
                      child: ValueListenableBuilder<Rect?>(
                        valueListenable: input.marquee,
                        builder: (context, r, _) => CustomPaint(painter: _MarqueePainter(r, scheme.primary)),
                      ),
                    ),
                    a11y.build(),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _ZoomControls(view: view, onFit: _fit),
                    ),
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

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({required this.view, required this.onFit});
  final CanvasViewState view;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Offset mid() => Offset(view.viewport.width / 2, view.viewport.height / 2);
    return Material(
      elevation: 1,
      borderRadius: BorderRadius.circular(8),
      color: scheme.surface,
      child: ListenableBuilder(
        listenable: view,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const Key('zoom-out'),
              tooltip: 'Zoom out',
              icon: const Icon(Icons.remove, size: 18),
              onPressed: () => view.zoomAt(mid(), 1 / 1.2),
            ),
            Text('${(view.scale * 100).round()}%', style: const TextStyle(fontSize: 12)),
            IconButton(
              key: const Key('zoom-in'),
              tooltip: 'Zoom in',
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => view.zoomAt(mid(), 1.2),
            ),
            IconButton(
              key: const Key('zoom-fit'),
              tooltip: 'Fit to window',
              icon: const Icon(Icons.fit_screen, size: 18),
              onPressed: onFit,
            ),
          ],
        ),
      ),
    );
  }
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
