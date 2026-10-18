import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'canvas_graph.dart';

/// A node drawn by a live widget instead of its card (the selected note, edited in place). The renderer puts it in
/// the node's own layer, at the node's top-left in canvas coordinates (scaled and clipped with the canvas), so what
/// lies over the node (edges, later nodes) lies over the widget too.
@immutable
class LiveCard {
  const LiveCard({required this.nodeId, required this.builder});

  final String nodeId;

  /// The widget, laid out at the size it chooses (it may draw outside it, e.g. a toolbar above the node: its root
  /// should be an [OverflowHitStack] for those parts to take pointer events).
  final Widget Function(BuildContext context, CanvasNode node) builder;
}

/// What a renderer draws of the [LiveCard]: its node, and the widget wrapped so pointer events reach it only where
/// nothing on the canvas lies over it (elsewhere the canvas handles them, as for what is drawn there). The events it
/// takes are its own: the canvas does not also select, drag or pan with them ([claim]).
class LiveCardLayer {
  LiveCardLayer({required this.source, required this.graph, required this.isTopAt, required this.claim});

  final ValueListenable<LiveCard?> source;
  final CanvasGraph graph;

  /// Whether [node] is what the canvas has on top at a canvas point (no later node or edge there).
  final bool Function(CanvasNode node, Offset point) isTopAt;

  /// The live widget took this pointer down.
  final void Function(PointerDownEvent event) claim;

  /// The live card's node, when it is on the canvas.
  CanvasNode? get node {
    final id = source.value?.nodeId;
    return id == null ? null : graph[id];
  }

  /// The live card of [n] for a renderer's [OverflowHitStack] in canvas coordinates.
  Widget build(BuildContext context, CanvasNode n) {
    final origin = n.rect.topLeft;
    return Positioned(
      key: ValueKey('live-${n.id}'),
      left: origin.dx,
      top: origin.dy,
      child: ValueListenableBuilder<NodeRunView>(
        valueListenable: n.run,
        child: source.value!.builder(context, n),
        builder: (context, run, child) => CanvasInteractionGate(
          opacity: run.opacity,
          accepts: (local) => isTopAt(n, origin + local),
          claim: claim,
          child: child!,
        ),
      ),
    );
  }

  /// The underlays a renderer that cannot put a widget between its own layers must draw as widgets under all it
  /// draws: the live node (an underlay) and the underlays below it that overlap it, directly or through one another,
  /// bottom to top.
  List<CanvasNode> underlayStack(CanvasNode live) {
    if (!live.layout.underlay) return [live];
    final out = {live};
    final todo = [live];
    while (todo.isNotEmpty) {
      final a = todo.removeLast();
      for (final slot in graph.grid.near(a.visual)) {
        final b = graph.slots[slot];
        if (b == null || out.contains(b) || !b.layout.underlay || b.order > live.order) continue;
        if (!b.visual.overlaps(a.visual)) continue;
        out.add(b);
        todo.add(b);
      }
    }
    return out.toList()..sort((a, b) => a.order.compareTo(b.order));
  }
}

/// Passes hits on to its child only where [accepts] (local position), and claims the pointer downs and wheel events
/// its child takes.
class CanvasInteractionGate extends SingleChildRenderObjectWidget {
  const CanvasInteractionGate({this.opacity = 1, required this.accepts, required this.claim, required super.child});
  final double opacity;
  final bool Function(Offset local) accepts;
  final void Function(PointerDownEvent event) claim;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLiveGate(accepts, claim, opacity);

  @override
  void updateRenderObject(BuildContext context, _RenderLiveGate r) => r
    ..accepts = accepts
    ..claim = claim
    ..opacity = opacity;
}

// RenderOpacity supplies compositing without a wrapper whose default hit testing would clip the toolbar
// outside the card. Keep the original overflow-aware gate as the outer render object.
class _RenderLiveGate extends RenderOpacity {
  _RenderLiveGate(this.accepts, this.claim, double opacity) : super(opacity: opacity);
  bool Function(Offset local) accepts;
  void Function(PointerDownEvent event) claim;

  // Not limited to its own box: the child draws (and takes events) outside it.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!accepts(position) || !hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) claim(event);
    // Dify's `nowheel`: the wheel over it does not move the canvas.
    if (event is PointerSignalEvent) GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
  }
}

/// A [Stack] whose children take pointer events outside its own box (cards at canvas coordinates, far outside the
/// viewport-sized box a canvas transform applies to; a note's toolbar above the note).
class OverflowHitStack extends Stack {
  const OverflowHitStack({super.key, super.children}) : super(clipBehavior: Clip.none);

  @override
  RenderStack createRenderObject(BuildContext context) =>
      _RenderOverflowHitStack(textDirection: Directionality.maybeOf(context));
}

class _RenderOverflowHitStack extends RenderStack {
  _RenderOverflowHitStack({super.textDirection}) : super(clipBehavior: Clip.none);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}
