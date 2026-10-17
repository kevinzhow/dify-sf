import 'dart:math';
import 'dart:ui';

/// The curve of an edge from an output port [a] to an input port [b] (horizontal tangents at both ends), as
/// [segments] + 1 points in canvas coordinates. Renderers draw it and hit testing measures against it.
List<Offset> edgeCurve(Offset a, Offset b, {int segments = 16}) {
  final dx = max(40.0, (b.dx - a.dx).abs() / 2);
  final c1 = a + Offset(dx, 0), c2 = b - Offset(dx, 0);
  return [
    for (var i = 0; i <= segments; i++)
      () {
        final t = i / segments, u = 1 - t;
        return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
      }(),
  ];
}

/// Distance from [p] to the polyline [pts].
double distanceToPolyline(Offset p, List<Offset> pts) {
  var best = double.infinity;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], ab = pts[i + 1] - a;
    final len2 = ab.distanceSquared;
    final t = len2 == 0 ? 0.0 : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    best = min(best, (p - (a + ab * t)).distance);
  }
  return best;
}
