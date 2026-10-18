import 'dart:math';
import 'dart:ui';

/// Dify's edge path: React Flow's bezier with curvature 0.16 from a source handle on the right to a target handle on
/// the left, both ends pulled 8 px into the handles (custom-edge.tsx). [source] and [target] are the handle points;
/// set [inset] to 0 for the line dragged out of a handle (custom-connection-line.tsx).
List<Offset> edgeCurve(Offset source, Offset target, {double inset = 8, int segments = 24}) {
  final a = source - Offset(inset, 0), b = target + Offset(inset, 0);
  final c1 = Offset(a.dx + _controlOffset(b.dx - a.dx), a.dy);
  final c2 = Offset(b.dx - _controlOffset(b.dx - a.dx), b.dy);
  return [
    for (var i = 0; i <= segments; i++)
      () {
        final t = i / segments, u = 1 - t;
        return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
      }(),
  ];
}

/// custom-connection-line.tsx's target marker: a 2 x 8 bar at the dragged end [to] (`x={toX} y={toY - 4}`), in
/// [connectionLineMarkerColor].
Rect connectionLineMarker(Offset to) => Rect.fromLTWH(to.dx, to.dy - 4, 2, 8);

/// `fill="#2970FF"`.
const connectionLineMarkerColor = Color(0xFF2970FF);

/// The connection line's stroke: `stroke="#D0D5DD" strokeWidth={2}`.
const connectionLineColor = Color(0xFFD0D5DD);

/// React Flow's calculateControlOffset: half the horizontal distance when the target is to the right, otherwise
/// curvature * 25 * sqrt(-distance).
double _controlOffset(double distance, {double curvature = 0.16}) =>
    distance >= 0 ? 0.5 * distance : curvature * 25 * sqrt(-distance);

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
