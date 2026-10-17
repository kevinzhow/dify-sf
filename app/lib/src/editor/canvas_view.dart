import 'dart:async';
import 'dart:math' as math;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_controller.dart';

const double kNodeWidth = 220;
const double kNodeHeight = 78;
const double _handleSize = 16;

Offset _outHandle(Offset p) => Offset(p.dx + kNodeWidth, p.dy + kNodeHeight / 2);
Offset _inHandle(Offset p) => Offset(p.dx, p.dy + kNodeHeight / 2);

/// The node graph: draggable nodes (position ops), connections drawn from a node's right handle to another
/// node, panning by dragging the background.
class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.controller});

  final EditorController controller;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  Offset _pan = const Offset(40, 60);
  double _scale = 1;
  Size _viewport = Size.zero;
  bool _fitted = false;
  final Map<String, Offset> _dragPos = {};
  Timer? _moveTimer;
  final Map<String, Offset> _unsentMoves = {};

  String? _connectFrom;
  Offset? _ghostTo;
  String? _hoverTarget;
  final GlobalKey _areaKey = GlobalKey();

  EditorController get c => widget.controller;

  Offset _pos(Node n) => _dragPos[n.id] ?? Offset(n.x.toDouble(), n.y.toDouble());

  /// Canvas coordinates of a global pointer position.
  Offset _toCanvas(Offset global) {
    final box = _areaKey.currentContext!.findRenderObject()! as RenderBox;
    return (box.globalToLocal(global) - _pan) / _scale;
  }

  // ---- dragging nodes ----------------------------------------------------------------------------

  void _dragStart(Node n) {
    _dragPos[n.id] = Offset(n.x.toDouble(), n.y.toDouble());
    c.selectNode(n.id);
  }

  void _dragUpdate(Node n, Offset delta) {
    final p =
        (_dragPos[n.id] ?? Offset(n.x.toDouble(), n.y.toDouble())) +
        delta; // already in canvas units: the node sits inside a scaled FittedBox
    setState(() => _dragPos[n.id] = p);
    // Live collaboration without flooding the log: at most ~8 small moveNode ops per second.
    _unsentMoves[n.id] = p;
    _moveTimer ??= Timer(const Duration(milliseconds: 120), _flushMoves);
  }

  void _dragEnd(Node n) {
    _flushMoves();
    setState(() => _dragPos.remove(n.id));
  }

  void _flushMoves() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final moves = Map.of(_unsentMoves);
    _unsentMoves.clear();
    for (final e in moves.entries) {
      if (c.doc.nodes.containsKey(e.key)) c.moveNode(e.key, e.value.dx.round(), e.value.dy.round());
    }
  }

  // ---- connecting --------------------------------------------------------------------------------

  void _connectStart(Node n) => setState(() {
    _connectFrom = n.id;
    _ghostTo = _outHandle(_pos(n));
  });

  void _connectUpdate(Offset global) {
    final p = _toCanvas(global);
    setState(() {
      _ghostTo = p;
      _hoverTarget = _nodeAt(p, exclude: _connectFrom);
    });
  }

  void _connectEnd() {
    final from = _connectFrom;
    final target = _hoverTarget;
    setState(() {
      _connectFrom = null;
      _ghostTo = null;
      _hoverTarget = null;
    });
    if (from != null && target != null) c.connect(from, target);
  }

  String? _nodeAt(Offset p, {String? exclude}) {
    for (final n in c.doc.nodes.values) {
      if (n.id == exclude) continue;
      final o = _pos(n);
      if (Rect.fromLTWH(o.dx, o.dy, kNodeWidth, kNodeHeight).inflate(14).contains(p)) return n.id;
    }
    return null;
  }

  // ---- tapping connections -----------------------------------------------------------------------

  void _tapBackground(Offset local) {
    final p = (local - _pan) / _scale;
    String? best;
    var bestDist = 10.0 / _scale;
    for (final e in c.doc.edges.values) {
      final s = c.doc.nodes[e.source];
      final t = c.doc.nodes[e.target];
      if (s == null || t == null) continue;
      final d = _distanceToCurve(p, _outHandle(_pos(s)), _inHandle(_pos(t)));
      if (d < bestDist) {
        bestDist = d;
        best = e.id;
      }
    }
    if (best != null) {
      c.selectEdge(best);
    } else {
      c.selectNode(null);
    }
  }

  // ---- zoom --------------------------------------------------------------------------------------

  /// Scales and centres the graph in the viewport (never zooms in beyond 100%).
  void _fit() {
    final nodes = c.doc.nodes.values;
    if (nodes.isEmpty || _viewport.isEmpty) return;
    var rect = Rect.fromLTWH(nodes.first.x.toDouble(), nodes.first.y.toDouble(), kNodeWidth, kNodeHeight);
    for (final n in nodes) {
      rect = rect.expandToInclude(Rect.fromLTWH(n.x.toDouble(), n.y.toDouble(), kNodeWidth, kNodeHeight));
    }
    final s = math.min(1.0, math.min((_viewport.width - 80) / rect.width, (_viewport.height - 120) / rect.height));
    setState(() {
      _scale = s.clamp(0.25, 1.0);
      _pan = Offset(
        (_viewport.width - rect.width * _scale) / 2 - rect.left * _scale,
        math.max(60, (_viewport.height - rect.height * _scale) / 2 - rect.top * _scale),
      );
    });
  }

  /// Zooms by [factor] keeping the canvas point under [focal] (viewport coordinates) fixed.
  void _zoom(double factor, [Offset? focal]) {
    final f = focal ?? Offset(_viewport.width / 2, _viewport.height / 2);
    final next = (_scale * factor).clamp(0.25, 2.0);
    final canvasPoint = (f - _pan) / _scale;
    setState(() {
      _scale = next;
      _pan = f - canvasPoint * next;
    });
  }

  @override
  void dispose() {
    _moveTimer?.cancel();
    super.dispose();
  }

  // ---- build -------------------------------------------------------------------------------------

  /// Node cards by node id, reused while the node (the same immutable instance: `Document.apply` replaces only the
  /// nodes an op touches), its selection and its hover state are unchanged. Returning the identical widget lets Flutter
  /// skip the card's subtree, so panning, zooming and edits to other nodes rebuild only the cheap position wrappers.
  final Map<String, ({Node node, bool selected, bool hovered, Widget card})> _cards = {};

  Widget _card(Node n) {
    final selected = c.selectedNodeId == n.id;
    final hovered = _hoverTarget == n.id;
    final hit = _cards[n.id];
    if (hit != null && identical(hit.node, n) && hit.selected == selected && hit.hovered == hovered) return hit.card;
    final card = _NodeCard(
      key: ValueKey('node-${n.id}'),
      node: n,
      selected: selected,
      hovered: hovered,
      brokenCount: [for (final v in n.config.values) ...v.brokenRefs].length,
      onTap: () => c.selectNode(n.id),
      onDragStart: () => _dragStart(n),
      onDragUpdate: (d) => _dragUpdate(n, d),
      onDragEnd: () => _dragEnd(n),
      onConnectStart: () => _connectStart(n),
      onConnectUpdate: _connectUpdate,
      onConnectEnd: _connectEnd,
    );
    _cards[n.id] = (node: n, selected: selected, hovered: hovered, card: card);
    return card;
  }

  @override
  Widget build(BuildContext context) {
    final doc = c.doc;
    final scheme = Theme.of(context).colorScheme;
    final nodes = doc.nodes.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    _cards.removeWhere((id, _) => !doc.nodes.containsKey(id));
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        if (!_fitted && nodes.isNotEmpty && !_viewport.isEmpty) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _fit() : null);
        }
        return Listener(
          // Ctrl/Cmd + wheel (or a trackpad pinch reported as such) zooms around the pointer.
          onPointerSignal: (e) {
            if (e is PointerScrollEvent &&
                (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) {
              final box = _areaKey.currentContext!.findRenderObject()! as RenderBox;
              _zoom(e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1, box.globalToLocal(e.position));
            }
          },
          child: ClipRect(
            child: Stack(
              key: _areaKey,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const Key('canvas-background'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _tapBackground(d.localPosition),
                    onPanUpdate: (d) => setState(() => _pan += d.delta),
                    child: CustomPaint(painter: _GridPainter(_pan, scheme.outlineVariant.withValues(alpha: 0.5))),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _EdgePainter(
                        pan: _pan,
                        scale: _scale,
                        edges: [
                          for (final e in doc.edges.values)
                            if (doc.nodes[e.source] != null && doc.nodes[e.target] != null)
                              (
                                id: e.id,
                                from: _outHandle(_pos(doc.nodes[e.source]!)),
                                to: _inHandle(_pos(doc.nodes[e.target]!)),
                              ),
                        ],
                        selected: c.selectedEdgeId,
                        ghost: _connectFrom == null || _ghostTo == null || doc.nodes[_connectFrom] == null
                            ? null
                            : (from: _outHandle(_pos(doc.nodes[_connectFrom]!)), to: _ghostTo!),
                        color: scheme.outline,
                        selectedColor: scheme.primary,
                      ),
                    ),
                  ),
                ),
                for (final n in nodes)
                  // The box is wider than the card so the handles that stick out of it can still be hit.
                  Positioned(
                    left: _pos(n).dx * _scale + _pan.dx - _handleSize / 2 * _scale,
                    top: _pos(n).dy * _scale + _pan.dy,
                    width: (kNodeWidth + _handleSize) * _scale,
                    height: kNodeHeight * _scale,
                    child: FittedBox(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: kNodeWidth + _handleSize,
                        height: kNodeHeight,
                        child: _card(n),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    elevation: 1,
                    borderRadius: BorderRadius.circular(8),
                    color: scheme.surface,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const Key('zoom-out'),
                          tooltip: 'Zoom out',
                          icon: const Icon(Icons.remove, size: 18),
                          onPressed: () => _zoom(1 / 1.2),
                        ),
                        Text('${(_scale * 100).round()}%', style: const TextStyle(fontSize: 12)),
                        IconButton(
                          key: const Key('zoom-in'),
                          tooltip: 'Zoom in',
                          icon: const Icon(Icons.add, size: 18),
                          onPressed: () => _zoom(1.2),
                        ),
                        IconButton(
                          key: const Key('zoom-fit'),
                          tooltip: 'Fit to window',
                          icon: const Icon(Icons.fit_screen, size: 18),
                          onPressed: _fit,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    super.key,
    required this.node,
    required this.selected,
    required this.hovered,
    required this.brokenCount,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onConnectStart,
    required this.onConnectUpdate,
    required this.onConnectEnd,
  });

  final Node node;
  final bool selected;
  final bool hovered;
  final int brokenCount;
  final VoidCallback onTap;
  final VoidCallback onDragStart;
  final void Function(Offset delta) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onConnectStart;
  final void Function(Offset global) onConnectUpdate;
  final VoidCallback onConnectEnd;

  static Color typeColor(String type) => switch (type) {
    'start' => Colors.green.shade600,
    'llm' => Colors.indigo.shade500,
    'code' => Colors.orange.shade700,
    'answer' => Colors.teal.shade600,
    _ => Colors.blueGrey,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = typeColor(node.type);
    final border = selected
        ? scheme.primary
        : hovered
        ? Colors.green
        : scheme.outlineVariant;
    return Stack(
      children: [
        Positioned.fill(
          left: _handleSize / 2,
          right: _handleSize / 2,
          child: GestureDetector(
            onTap: onTap,
            onPanStart: (_) => onDragStart(),
            onPanUpdate: (d) => onDragUpdate(d.delta),
            onPanEnd: (_) => onDragEnd(),
            onPanCancel: onDragEnd,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Material(
                elevation: selected ? 4 : 1,
                color: scheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: border, width: selected || hovered ? 2 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: [
                    Container(width: 6, color: accent),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              node.title.isEmpty ? '(untitled)' : node.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  node.type,
                                  style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w500),
                                ),
                                if (brokenCount > 0) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.link_off,
                                    size: 14,
                                    color: scheme.error,
                                    key: Key('broken-badge-${node.id}'),
                                  ),
                                  const SizedBox(width: 2),
                                  Text('$brokenCount broken', style: TextStyle(color: scheme.error, fontSize: 12)),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Input handle (left) and output handle (right).
        Positioned(
          left: 0,
          top: kNodeHeight / 2 - _handleSize / 2,
          child: _Handle(key: Key('in-${node.id}'), color: hovered ? Colors.green : scheme.outline),
        ),
        Positioned(
          right: 0,
          top: kNodeHeight / 2 - _handleSize / 2,
          child: GestureDetector(
            key: Key('out-${node.id}'),
            onPanStart: (_) => onConnectStart(),
            onPanUpdate: (d) => onConnectUpdate(d.globalPosition),
            onPanEnd: (_) => onConnectEnd(),
            onPanCancel: onConnectEnd,
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: _Handle(color: accent),
            ),
          ),
        ),
      ],
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: _handleSize,
    height: _handleSize,
    decoration: BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 3),
    ),
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.pan, this.color);
  final Offset pan;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 28.0;
    final paint = Paint()..color = color;
    final ox = pan.dx % step;
    final oy = pan.dy % step;
    for (var x = ox; x < size.width; x += step) {
      for (var y = oy; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.pan != pan || old.color != color;
}

typedef _EdgeSpec = ({String id, Offset from, Offset to});

class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.pan,
    required this.scale,
    required this.edges,
    required this.selected,
    required this.ghost,
    required this.color,
    required this.selectedColor,
  });

  final Offset pan;
  final double scale;
  final List<_EdgeSpec> edges;
  final String? selected;
  final ({Offset from, Offset to})? ghost;
  final Color color;
  final Color selectedColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..translate(pan.dx, pan.dy)
      ..scale(scale);
    for (final e in edges) {
      final isSel = e.id == selected;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSel ? 3.5 : 2
        ..color = isSel ? selectedColor : color;
      canvas.drawPath(_curve(e.from, e.to), paint);
      _arrow(canvas, e.to, paint..style = PaintingStyle.fill);
    }
    final g = ghost;
    if (g != null) {
      canvas.drawPath(
        _curve(g.from, g.to),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = selectedColor.withValues(alpha: 0.7),
      );
    }
  }

  void _arrow(Canvas canvas, Offset tip, Paint paint) {
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - 9, tip.dy - 5)
      ..lineTo(tip.dx - 9, tip.dy + 5)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}

Path _curve(Offset a, Offset b) {
  final dx = math.max(40.0, (b.dx - a.dx).abs() / 2);
  return Path()
    ..moveTo(a.dx, a.dy)
    ..cubicTo(a.dx + dx, a.dy, b.dx - dx, b.dy, b.dx, b.dy);
}

/// Distance from [p] to the connection curve, by sampling.
double _distanceToCurve(Offset p, Offset a, Offset b) {
  final dx = math.max(40.0, (b.dx - a.dx).abs() / 2);
  final c1 = Offset(a.dx + dx, a.dy);
  final c2 = Offset(b.dx - dx, b.dy);
  var best = double.infinity;
  const n = 32;
  for (var i = 0; i <= n; i++) {
    final t = i / n;
    final u = 1 - t;
    final q = a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
    best = math.min(best, (q - p).distance);
  }
  return best;
}
