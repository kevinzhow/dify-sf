import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design/dify_tokens.g.dart';
import 'canvas_graph.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'edge_curve.dart';
import 'live_card.dart';
import 'node_card.dart';
import 'run_view.dart';

/// Draws the canvas with plain widgets: only cards in (or near) the viewport are built, pan/zoom is one layer
/// transform, each card is its own repaint boundary; the [live] card is drawn in its node's place. Used in widget
/// tests and where Flutter GPU is not available.
///
/// Card widgets are made once per document change and reused, so panning, selection and run updates do not rebuild
/// cards: a card listens to its own node (content, run state); the run's dimming and status border are drawn around
/// it by a builder listening to that node's run view alone.
class WidgetRenderer extends CanvasRenderer {
  WidgetRenderer({required this.graph, required this.view, required this.selection, required this.cards, this.live});

  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final CardSpec cards;
  final LiveCardLayer? live;

  final _version = ValueNotifier(0);
  final _edgesVersion = ValueNotifier(0);
  Set<int> _moving = {};
  (Offset, Offset)? _preview;

  /// The card widgets, per node (dropped on document changes: cards show labels of other nodes).
  var _cardWidgets = Expando<Widget>();

  void _bump() => _version.value++;

  @override
  void apply(CanvasChange change) {
    if (change.edgesChanged) _edgesVersion.value++;
    if (change.added.isNotEmpty || change.removed.isNotEmpty || change.changed.isNotEmpty) {
      _cardWidgets = Expando<Widget>();
    }
    _bump();
  }

  @override
  void beginMove(Set<int> slots) {
    _moving = slots;
    _edgesVersion.value++;
    _bump();
  }

  @override
  void moved(Iterable<int> slots) => _bump();

  @override
  void endMove(Set<int> slots) {
    _moving = {};
    _edgesVersion.value++;
    _bump();
  }

  @override
  void connectPreview(Offset? from, Offset? to) {
    _preview = from == null || to == null ? null : (from, to);
    _bump();
  }

  @override
  void selectionChanged(Set<int> slots) => _bump();

  // The node's builder listens to its run view.
  @override
  void statusChanged(int slot) {}

  @override
  void edgeRunChanged() {
    _edgesVersion.value++;
    _bump();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_version, view, ?live?.source]),
      builder: (context, _) {
        final visible = view.visible.inflate(80);
        // Per nesting depth: that depth's edges, then its cards (edges inside a container lie above the container
        // and below its children).
        final liveNode = live?.node;
        final cards = _stacked(visible, liveNode);
        final depths = {0, for (final n in cards) n.depth}.toList()..sort();
        Widget card(CanvasNode n) => n == liveNode ? live!.build(context, n) : _card(context, n);
        final children = <Widget>[
          for (final n in cards)
            if (n.layout.underlay) card(n),
          for (final d in depths) ...[
            RepaintBoundary(
              child: CustomPaint(
                painter: _EdgePainter(
                  graph,
                  _edgesVersion.value,
                  live: false,
                  moving: _moving,
                  selected: selection.edge,
                  depth: d,
                ),
              ),
            ),
            if (_moving.isNotEmpty)
              CustomPaint(
                painter: _EdgePainter(
                  graph,
                  _version.value,
                  live: true,
                  moving: _moving,
                  selected: selection.edge,
                  depth: d,
                ),
              ),
            for (final n in cards)
              if (n.depth == d && !n.layout.underlay) card(n),
          ],
          if (_preview != null) CustomPaint(painter: _PreviewPainter(_preview!)),
        ];
        return ClipRect(
          child: Transform(
            transform: view.matrix,
            child: OverflowHitStack(children: children),
          ),
        );
      },
    );
  }

  /// Cards in [visible] (and the live one, which keeps its state off screen), bottom to top: selected nodes above
  /// the others, later nodes above earlier ones.
  List<CanvasNode> _stacked(Rect visible, CanvasNode? live) {
    int key(CanvasNode n) => n.layout.underlay
        ? n.order - (1 << 50)
        : (n.depth << 44) + (selection.nodes.contains(n.slot) ? 1 << 40 : 0) + n.order;
    return [
      for (final slot in graph.grid.near(visible))
        if (graph.slots[slot] case final n? when visible.overlaps(n.rect) && n != live) n,
      ?live,
    ]..sort((a, b) => key(a).compareTo(key(b)));
  }

  Widget _card(BuildContext context, CanvasNode n) {
    final selected = selection.nodes.contains(n.slot);
    final connected = {
      for (final e in graph.edges) ...[
        if (e.target == n.slot) ('in', ''),
        if (e.source == n.slot)
          (
            'out',
            n.layout.sources.containsKey(e.sourceHandle)
                ? e.sourceHandle
                : n.layout.sources.keys.firstOrNull ?? 'source',
          ),
      ],
    };
    // One box covering what is drawn for the node, its selected frame and its handles.
    const out = CanvasNode.handleOut, box = CanvasNode.handleBox;
    final bounds = n.visual.expandToInclude(n.rect.inflate(out + 1));
    Offset local(Offset p) => p - bounds.topLeft;
    Widget marker(bool on, {bool right = false}) => SizedBox(
      width: box,
      height: box,
      child: on
          ? Padding(
              padding: right ? const EdgeInsets.fromLTRB(8, 4, 6, 4) : const EdgeInsets.fromLTRB(6, 4, 8, 4),
              child: const ColoredBox(color: DifyColors.workflowLinkLineHandle),
            )
          : null,
    );
    final card = local(n.rect.topLeft), visual = local(n.visual.topLeft);
    final cardWidget = _cardWidgets[n] ??= KeyedSubtree(
      key: ValueKey('node-${n.id}'),
      child: CanvasCardControls(child: RepaintBoundary(child: cards.build(context, n, graph, live: true))),
    );
    return Positioned.fromRect(
      key: ValueKey('canvas-node-${n.id}'),
      rect: bounds,
      child: ValueListenableBuilder<NodeRunView>(
        valueListenable: n.run,
        builder: (context, run, _) {
          // getNodeStatusBorders: no status border while the selected border shows.
          final status = selected ? null : statusBorderColor(run.status);
          // node.tsx: `_waitingRun && 'opacity-70'` on the node element (card, frames and handles).
          return Opacity(
            opacity: run.opacity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: visual.dx,
                  top: visual.dy,
                  width: n.visual.width,
                  height: n.visual.height,
                  child: cardWidget,
                ),
                // Over the card (it covers only the 1 px around it): an entry node's tab, drawn with the card,
                // would hide it.
                if (selected && !n.layout.underlay)
                  Positioned.fromRect(
                    rect: Rect.fromLTWH(card.dx - 1, card.dy - 1, n.size.width + 2, n.size.height + 2),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(DifyRadius.xxl),
                          border: Border.all(color: DifyColors.componentsOptionCardOptionSelectedBorder),
                        ),
                      ),
                    ),
                  ),
                if (status != null)
                  Positioned.fromRect(
                    key: Key('status-border-${n.id}'),
                    rect: Rect.fromLTWH(card.dx, card.dy, n.size.width, n.size.height),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
                          border: Border.all(color: status),
                        ),
                      ),
                    ),
                  ),
                if (n.layout.target)
                  Positioned(
                    left: local(n.inHandle.topLeft).dx,
                    top: local(n.inHandle.topLeft).dy,
                    child: KeyedSubtree(key: Key('in-${n.id}'), child: marker(connected.contains(('in', '')))),
                  ),
                for (final (i, (id, handle)) in n.outHandles.indexed)
                  Positioned(
                    left: local(handle.topLeft).dx,
                    top: local(handle.topLeft).dy,
                    child: KeyedSubtree(
                      key: Key(i == 0 ? 'out-${n.id}' : 'out-${n.id}-$id'),
                      child: marker(connected.contains(('out', id)), right: true),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _version.dispose();
    _edgesVersion.dispose();
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(
    this.graph,
    this.version, {
    required this.live,
    required this.moving,
    required this.selected,
    this.depth = 0,
  });

  /// Only edges whose source is at this nesting depth.
  final int depth;

  final CanvasGraph graph;
  final int version;
  final bool live;
  final Set<int> moving;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in graph.edges) {
      final isLive = moving.contains(e.source) || moving.contains(e.target);
      if (isLive != live) continue;
      final a = graph.slots[e.source], b = graph.slots[e.target];
      if (a == null || b == null || a.depth != depth) continue;
      final from = a.outPortFor(e.sourceHandle), to = b.inPort;
      final stroke = graph.strokeOf(e, selected: e.id == selected);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      // custom-edge-linear-gradient-render.tsx: userSpaceOnUse from the source handle to the target handle.
      if (stroke.isGradient && from != to) {
        paint.shader = ui.Gradient.linear(from, to, [stroke.at(0), stroke.at(1)]);
      } else {
        paint.color = stroke.at(0);
      }
      canvas.drawPath(_path(edgeCurve(from, to)), paint);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.version != version || old.selected != selected || old.depth != depth || live;
}

Path _path(List<Offset> pts) {
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (final p in pts.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  return path;
}

/// The line dragged out of a handle (custom-connection-line.tsx): no inset, #D0D5DD, 2 px.
class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.line);
  final (Offset, Offset) line;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _path(edgeCurve(line.$1, line.$2, inset: 0)),
      Paint()
        ..color = connectionLineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.line != line;
}
