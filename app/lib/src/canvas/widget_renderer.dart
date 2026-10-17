import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../design/dify_tokens.g.dart';
import 'canvas_graph.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'edge_curve.dart';
import 'node_card.dart';

/// Draws the canvas with plain widgets: only cards in (or near) the viewport are built, pan/zoom is one layer
/// transform, each card is its own repaint boundary. Used in widget tests and where Flutter GPU is not available.
class WidgetRenderer extends CanvasRenderer {
  WidgetRenderer({required this.graph, required this.view, required this.selection, required this.cards});

  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final CardSpec cards;

  final _version = ValueNotifier(0);
  final _edgesVersion = ValueNotifier(0);
  Set<int> _moving = {};
  (Offset, Offset)? _preview;

  void _bump() => _version.value++;

  @override
  void apply(CanvasChange change) {
    if (change.edgesChanged) _edgesVersion.value++;
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

  @override
  void statusChanged(int slot) => _bump();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_version, view]),
      builder: (context, _) {
        final visible = view.visible.inflate(80);
        final transform = Matrix4.identity()
          ..translateByDouble(view.viewport.width / 2, view.viewport.height / 2, 0, 1)
          ..scaleByDouble(view.scale, view.scale, 1, 1)
          ..translateByDouble(-view.center.dx, -view.center.dy, 0, 1);
        final children = <Widget>[
          RepaintBoundary(
            child: CustomPaint(
              painter: _EdgePainter(graph, _edgesVersion.value, live: false, moving: _moving, selected: selection.edge),
            ),
          ),
          if (_moving.isNotEmpty)
            CustomPaint(
              painter: _EdgePainter(graph, _version.value, live: true, moving: _moving, selected: selection.edge),
            ),
          if (_preview != null) CustomPaint(painter: _PreviewPainter(_preview!)),
          for (final n in _stacked(visible)) _card(context, n),
        ];
        return ClipRect(
          child: Transform(
            transform: transform,
            child: _UnboundedStack(children: children),
          ),
        );
      },
    );
  }

  /// Cards in [visible], bottom to top: selected nodes above the others, later nodes above earlier ones.
  List<CanvasNode> _stacked(Rect visible) {
    int key(CanvasNode n) => (selection.nodes.contains(n.slot) ? 1 << 40 : 0) + n.order;
    return [
      for (final slot in graph.grid.near(visible))
        if (graph.slots[slot] case final n? when visible.overlaps(n.rect)) n,
    ]..sort((a, b) => key(a).compareTo(key(b)));
  }

  Widget _card(BuildContext context, CanvasNode n) {
    final selected = selection.nodes.contains(n.slot);
    final status = switch (n.status.value) {
      'running' || 'paused' => DifyColors.stateAccentSolid,
      'succeeded' => DifyColors.stateSuccessSolid,
      'failed' => DifyColors.stateDestructiveSolid,
      'exception' => DifyColors.stateWarningSolid,
      _ => null,
    };
    final connectedIn = graph.edges.any((e) => e.target == n.slot);
    final connectedOut = graph.edges.any((e) => e.source == n.slot);
    // The box covers the card, its selected frame (1 px outside) and the handles (9 px outside).
    const out = CanvasNode.handleOut;
    Widget marker(bool on) => SizedBox(
      width: CanvasNode.handleBox,
      height: CanvasNode.handleBox,
      child: on
          ? const Padding(
              padding: EdgeInsets.fromLTRB(6, 4, 8, 4),
              child: ColoredBox(color: DifyColors.workflowLinkLineHandle),
            )
          : null,
    );
    return Positioned(
      left: n.x - out,
      top: n.y - 1,
      width: n.size.width + 2 * out,
      height: n.size.height + 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (selected)
            Positioned(
              left: out - 1,
              top: 0,
              width: n.size.width + 2,
              height: n.size.height + 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(DifyRadius.xxl),
                  border: Border.all(color: DifyColors.componentsOptionCardOptionSelectedBorder),
                ),
              ),
            ),
          Positioned(
            left: out,
            top: 1,
            width: n.size.width,
            height: n.size.height,
            child: KeyedSubtree(
              key: ValueKey('node-${n.id}'),
              child: RepaintBoundary(
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
                    border: status == null ? null : Border.all(color: status),
                  ),
                  child: cards.build(context, n, live: true),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 1 + CanvasNode.handleTop,
            child: KeyedSubtree(key: Key('in-${n.id}'), child: marker(connectedIn)),
          ),
          Positioned(
            right: 0,
            top: 1 + CanvasNode.handleTop,
            child: KeyedSubtree(
              key: Key('out-${n.id}'),
              child: Transform.flip(flipX: true, child: marker(connectedOut)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _version.dispose();
    _edgesVersion.dispose();
  }
}

class _Handle extends StatelessWidget {
  const _Handle({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: color, width: 2),
    ),
  );
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.graph, this.version, {required this.live, required this.moving, required this.selected});

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
      if (a == null || b == null) continue;
      canvas.drawPath(
        _path(edgeCurve(a.outPort, b.inPort)),
        Paint()
          ..color = e.id == selected ? DifyColors.workflowLinkLineHandle : DifyColors.workflowLinkLineNormal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.version != version || old.selected != selected || live;
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
        ..color = const Color(0xFFD0D5DD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.line != line;
}

/// A stack whose children are hit-testable outside its own box (the cards sit at canvas coordinates, far outside
/// the viewport-sized box the transform is applied to).
class _UnboundedStack extends Stack {
  const _UnboundedStack({required super.children}) : super(clipBehavior: Clip.none);

  @override
  RenderStack createRenderObject(BuildContext context) =>
      _RenderUnboundedStack(textDirection: Directionality.maybeOf(context));
}

class _RenderUnboundedStack extends RenderStack {
  _RenderUnboundedStack({super.textDirection}) : super(clipBehavior: Clip.none);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => hitTestChildren(result, position: position);
}
