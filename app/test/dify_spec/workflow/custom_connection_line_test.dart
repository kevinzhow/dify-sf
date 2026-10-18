// dify-spec: web/app/components/workflow/__tests__/custom-connection-line.spec.tsx
//
// The line dragged out of a handle: edgeCurve with no inset (React Flow's getBezierPath, curvature 0.16) stroked in
// connectionLineColor by the renderers, and the target marker (connectionLineMarker) drawn over the canvas.
import 'dart:math';

import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hooks/editor_harness.dart';

/// React Flow's getBezierPath (right source, left target) at [t].
Offset _bezier(Offset s, Offset e, double t) {
  final d = e.dx - s.dx;
  final offset = d >= 0 ? 0.5 * d : 0.16 * 25 * sqrt(-d);
  final c1 = Offset(s.dx + offset, s.dy), c2 = Offset(e.dx - offset, e.dy);
  final u = 1 - t;
  return s * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + e * (t * t * t);
}

ConnectionLineMarkerPainter? _marker(WidgetTester t) => find
    .byWidgetPredicate((w) => w is CustomPaint && w.painter is ConnectionLineMarkerPainter)
    .evaluate()
    .map((e) => (e.widget as CustomPaint).painter! as ConnectionLineMarkerPainter)
    .firstOrNull;

void main() {
  group('CustomConnectionLine', () {
    test('should render the bezier path and target marker', () {
      const from = Offset(10, 20), to = Offset(70, 80);
      final pts = edgeCurve(from, to, inset: 0);
      expect(pts.first, from);
      expect(pts.last, to);
      for (final (i, p) in pts.indexed) {
        final expected = _bezier(from, to, i / (pts.length - 1));
        expect((p - expected).distance, lessThan(1e-9));
      }
      expect(connectionLineColor, const Color(0xFFD0D5DD));
      expect(connectionLineMarker(to), const Rect.fromLTWH(70, 76, 2, 8));
      expect(connectionLineMarkerColor, const Color(0xFF2970FF));
    });

    testWidgets('should update the path when the endpoints change', (t) async {
      final h = await EditorHarness.start(t, [node('a', x: 100, y: 100)]);
      expect(_marker(t)?.rect, isNull);
      final from = h.outPort('a');
      final g = await t.startGesture(from, kind: PointerDeviceKind.mouse);
      await g.moveTo(const Offset(500, 300));
      await t.pump();
      expect(_marker(t)?.rect, connectionLineMarker(h.canvas.view.toCanvas(const Offset(500, 300))));
      await g.moveTo(const Offset(600, 450));
      await t.pump();
      expect(_marker(t)?.rect, connectionLineMarker(const Offset(600, 450)));
      await g.up();
      await t.pump();
      expect(_marker(t)?.rect, isNull);
      await h.dispose(t);
    });
  });
}
