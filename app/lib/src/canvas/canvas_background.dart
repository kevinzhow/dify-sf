import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import 'canvas_view_state.dart';

/// Dify's canvas background: React Flow's dot pattern, 14 px apart, 2 px dots, scaled with the zoom, on
/// `workflow-canvas-workflow-bg` (index.tsx `<Background gap={[14, 14]} size={2} />`). Drawn as one rectangle with
/// a repeating image of one tile, so it costs the same at any zoom.
class CanvasBackground extends StatefulWidget {
  const CanvasBackground({super.key, required this.view});
  final CanvasViewState view;

  @override
  State<CanvasBackground> createState() => _CanvasBackgroundState();
}

class _CanvasBackgroundState extends State<CanvasBackground> {
  static const gap = 14.0;
  static const dot = 2.0;
  static const tileScale = 8; // the tile is drawn at 8x so it stays crisp when zoomed in
  ui.Image? _tile;

  @override
  void initState() {
    super.initState();
    final recorder = ui.PictureRecorder();
    const s = gap * tileScale;
    Canvas(recorder)
      ..drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..color = DifyColors.workflowCanvasWorkflowBg)
      ..drawCircle(
        const Offset(s / 2, s / 2),
        dot / 2 * tileScale,
        Paint()..color = DifyColors.workflowCanvasWorkflowDotColor,
      );
    recorder.endRecording().toImage(s.toInt(), s.toInt()).then((image) {
      if (mounted) setState(() => _tile = image);
    });
  }

  @override
  void dispose() {
    _tile?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DotsPainter(widget.view, _tile),
    child: const SizedBox.expand(),
  );
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.view, this.tile) : super(repaint: view);
  final CanvasViewState view;
  final ui.Image? tile;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final t = tile;
    if (t == null) {
      canvas.drawRect(rect, Paint()..color = DifyColors.workflowCanvasWorkflowBg);
      return;
    }
    // React Flow's pattern is anchored at the canvas origin and offset by half a gap; canvas point p is on screen
    // at view.toScreen(p).
    const gap = _CanvasBackgroundState.gap, k = _CanvasBackgroundState.tileScale;
    final origin = view.toScreen(Offset.zero) - Offset(gap / 2, gap / 2) * view.scale;
    final m = Matrix4.identity()
      ..translateByDouble(origin.dx, origin.dy, 0, 1)
      ..scaleByDouble(view.scale / k, view.scale / k, 1, 1);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ImageShader(t, TileMode.repeated, TileMode.repeated, m.storage, filterQuality: FilterQuality.medium),
    );
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.tile != tile;
}
