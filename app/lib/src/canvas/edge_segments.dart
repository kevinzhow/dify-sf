import 'dart:ui';

import '../design/dify_tokens.g.dart';
import 'canvas_graph.dart';
import 'edge_curve.dart';

/// Steps a gradient edge's colour is quantised to (one batch per colour).
const edgeGradientSteps = 16;

/// The edges as line segments grouped by the colour each segment is drawn in, for a renderer that draws lines in
/// flat colours (Flutter Scene): a gradient stroke (custom-edge.tsx's `url(#id)`, from the source handle to the
/// target handle) gives each segment the colour at its middle, quantised to [edgeGradientSteps]; a stroke's opacity
/// (`_waitingRun` 0.7) is mixed over the canvas background, so every colour is opaque (edges lie on the background,
/// under the cards).
Map<Color, List<(Offset, Offset)>> edgeSegmentsByColor(
  CanvasGraph graph,
  Iterable<CanvasEdge> edges, {
  String? selected,
  Color background = DifyColors.workflowCanvasWorkflowBg,
}) {
  final out = <Color, List<(Offset, Offset)>>{};
  for (final e in edges) {
    final a = graph.slots[e.source], b = graph.slots[e.target];
    if (a == null || b == null) continue;
    final from = a.outPortFor(e.sourceHandle), to = b.inPort;
    final stroke = graph.strokeOf(e, selected: e.id == selected);
    final pts = edgeCurve(from, to);
    final axis = to - from, len2 = axis.distanceSquared;
    for (var k = 0; k + 1 < pts.length; k++) {
      var t = 0.0;
      if (stroke.isGradient && len2 > 0) {
        final mid = (pts[k] + pts[k + 1]) / 2 - from;
        t = ((mid.dx * axis.dx + mid.dy * axis.dy) / len2).clamp(0.0, 1.0);
        t = (t * edgeGradientSteps).round() / edgeGradientSteps;
      }
      final c = stroke.at(t);
      final color = c.a >= 1 ? c : Color.alphaBlend(c, background);
      (out[color] ??= []).add((pts[k], pts[k + 1]));
    }
  }
  return out;
}
