import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart' show CanvasNode;
import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';

/// React Flow's MiniMap with Dify's props (operator/index.tsx): `pannable zoomable`, 102×72, `maskColor`
/// workflow-minimap-bg, in a 103×73 box (`rounded-lg border-[0.5px] border-divider-subtle bg-background-default-subtle
/// shadow-md shadow-shadow-shadow-5`).
///
/// Dify's `nodeClassName` sets `bg-*` / `border-*` classes, which do not paint SVG rects, so the browser draws React
/// Flow's defaults: fill #e2e2e2, transparent stroke, radius 5. Like the browser, the square map is drawn over the
/// box's rounded corners. Repaints when the view or [graphChanges] notify.
class WorkflowMiniMap extends StatelessWidget {
  const WorkflowMiniMap({super.key, required this.canvas, required this.graphChanges});

  final CanvasController canvas;
  final Listenable graphChanges;

  static const size = Size(102, 72);
  static const nodeColor = Color(0xFFE2E2E2);
  static final _shadow = [for (final s in DifyShadows.md) s.copyWith(color: DifyColors.shadowShadow5)];

  /// d3-zoom on the map: a drag pans the canvas (React Flow's panHandler), the wheel zooms it around the middle.
  void _drag(PointerMoveEvent e) {
    final m = _MiniMapLayout.of(canvas, size);
    if (m == null) return;
    final view = canvas.view;
    view.center += e.delta * m.viewScale * max(1, view.scale) / view.scale;
  }

  void _wheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (e) {
      final dy = (e as PointerScrollEvent).scrollDelta.dy;
      canvas.zoomTo(canvas.view.scale * pow(2, -dy * 0.002 * 10)); // zoomStep 10
    });
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: DifyColors.backgroundDefaultSubtle,
      border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      boxShadow: _shadow,
    ),
    child: Semantics(
      label: 'React Flow mini map',
      image: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerMove: _drag,
        onPointerSignal: _wheel,
        child: CustomPaint(
          size: size,
          painter: _MiniMapPainter(canvas, Listenable.merge([canvas.view, graphChanges])),
        ),
      ),
    ),
  );
}

/// The map's SVG viewBox as React Flow computes it, fitted into the element (`preserveAspectRatio` xMidYMid meet).
class _MiniMapLayout {
  _MiniMapLayout(this.viewBox, this.viewScale, this.offset, this.visible, Size element)
    : scale = min(element.width / viewBox.width, element.height / viewBox.height) {
    origin =
        Offset(element.width - viewBox.width * scale, element.height - viewBox.height * scale) / 2 -
        viewBox.topLeft * scale;
  }

  final Rect viewBox;
  final double viewScale;
  final double offset;
  final Rect visible;
  final double scale;
  late final Offset origin;

  static _MiniMapLayout? of(CanvasController canvas, Size element) {
    final view = canvas.view;
    if (view.viewport.isEmpty) return null;
    final visible = view.visible;
    final g = canvas.graph;
    final bounds = g == null || g.length == 0 ? visible : g.bounds.expandToInclude(visible);
    final viewScale = max(bounds.width / element.width, bounds.height / element.height);
    final w = viewScale * element.width, h = viewScale * element.height, offset = 5 * viewScale; // offsetScale 5
    final box = Rect.fromLTWH(
      bounds.left - (w - bounds.width) / 2 - offset,
      bounds.top - (h - bounds.height) / 2 - offset,
      w + 2 * offset,
      h + 2 * offset,
    );
    return _MiniMapLayout(box, viewScale, offset, visible, element);
  }
}

class _MiniMapPainter extends CustomPainter {
  _MiniMapPainter(this.canvas, Listenable repaint) : super(repaint: repaint);

  final CanvasController canvas;

  static final _node = Paint()..color = WorkflowMiniMap.nodeColor;
  static final _mask = Paint()..color = DifyColors.workflowMinimapBg;

  @override
  void paint(Canvas c, Size size) {
    final m = _MiniMapLayout.of(canvas, size);
    if (m == null) return;
    c
      ..save()
      ..clipRect(Offset.zero & size)
      ..translate(m.origin.dx, m.origin.dy)
      ..scale(m.scale);
    for (final n in canvas.graph?.nodes ?? const <CanvasNode>[]) {
      c.drawRRect(RRect.fromRectXY(n.visual, 5, 5), _node);
    }
    // The mask: everything but the visible part of the canvas.
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(m.viewBox.inflate(m.offset))
      ..addRect(m.visible);
    c
      ..drawPath(mask, _mask)
      ..restore();
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) => old.canvas != canvas;
}
