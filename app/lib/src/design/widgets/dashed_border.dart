/// A box with a (dashed or solid) 1 px rounded border and a fill: the shared primitive behind the drop zones
/// (`border border-dashed border-components-dropzone-border` in Dify's uploaders) and the other dashed cards.
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';

class DashedBorderBox extends StatelessWidget {
  const DashedBorderBox({
    super.key,
    required this.child,
    required this.color,
    required this.fill,
    this.dashed = true,
    this.radius = DifyRadius.xl,
  });

  final Widget child;
  final Color color, fill;
  final bool dashed;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedBorder(color: color, fill: fill, dashed: dashed, radius: radius),
    child: child,
  );
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, required this.fill, required this.dashed, required this.radius});
  final Color color, fill;
  final bool dashed;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..color = fill);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()..addRRect(rrect.deflate(0.5));
    if (!dashed) {
      canvas.drawPath(path, stroke);
      return;
    }
    // Chrome's dashed border: dashes about three times the border width.
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 6) {
        canvas.drawPath(metric.extractPath(d, (d + 3).clamp(0, metric.length)), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.fill != fill || old.dashed != dashed || old.radius != radius;
}
