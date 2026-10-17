import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import 'canvas_graph.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'edge_curve.dart';

/// Pointer and keyboard input on the canvas, hit-tested in canvas coordinates: click selects (Shift toggles), drag
/// moves the selection, drag from an output port connects, drag on empty canvas pans (Shift: box select), the wheel
/// zooms around the pointer, a click near an edge selects it, Delete/Backspace removes the selection.
/// Every change to the document goes through [EditorController].
class CanvasInput {
  CanvasInput({
    required this.controller,
    required this.graph,
    required this.view,
    required this.selection,
    required this.renderer,
  });

  final EditorController controller;
  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final CanvasRenderer Function() renderer;

  /// The box being dragged out (screen coordinates), for the overlay.
  final marquee = ValueNotifier<Rect?>(null);

  /// Box select without holding Shift (tests and benchmarks cannot hold a key).
  bool forceMarquee = false;

  /// Called after an input changed what is drawn (benchmarks time input to frame).
  void Function(String kind)? onApplied;

  String _gesture = 'none'; // pan, move, connect, marquee
  Offset _downLocal = Offset.zero;
  Offset _lastCanvas = Offset.zero;
  Offset _panCenter = Offset.zero;
  bool _moved = false;
  CanvasNode? _connectFrom;
  Set<int> _moving = {};
  Timer? _sendTimer;

  static const _slop = 3.0;
  static const _portRadiusPx = 10.0;
  static const _edgeRadiusPx = 6.0;

  // ----- hit testing -----

  /// The top-most node at [c]: selected nodes lie above the others, later nodes above earlier ones.
  CanvasNode? nodeAt(Offset c) {
    CanvasNode? hit;
    for (final slot in graph.grid.near(Rect.fromCenter(center: c, width: 1, height: 1))) {
      final n = graph.slots[slot];
      if (n == null || !n.rect.contains(c)) continue;
      if (hit == null || stackKey(n) > stackKey(hit)) hit = n;
    }
    return hit;
  }

  int stackKey(CanvasNode n) => (selection.nodes.contains(n.slot) ? 1 << 40 : 0) + n.order;

  CanvasNode? outPortAt(Offset c) {
    final r = max(_portRadiusPx / view.scale, 4.0);
    for (final slot in graph.grid.near(Rect.fromCenter(center: c, width: 2 * r, height: 2 * r))) {
      final n = graph.slots[slot];
      if (n != null && (n.outPort - c).distance <= r) return n;
    }
    return null;
  }

  CanvasEdge? edgeAt(Offset c) {
    final r = _edgeRadiusPx / view.scale;
    CanvasEdge? best;
    var bestD = r;
    for (final e in graph.edges) {
      final a = graph.slots[e.source]!, b = graph.slots[e.target]!;
      final box = Rect.fromPoints(a.outPort, b.inPort).inflate(60 + r);
      if (!box.contains(c)) continue;
      final d = distanceToPolyline(c, edgeCurve(a.outPort, b.inPort));
      if (d <= bestD) {
        best = e;
        bestD = d;
      }
    }
    return best;
  }

  // ----- pointer -----

  void down(PointerDownEvent e) {
    if (e.buttons & kPrimaryButton == 0) return;
    _downLocal = e.localPosition;
    final c = view.toCanvas(e.localPosition);
    _lastCanvas = c;
    _moved = false;
    final port = outPortAt(c), hit = nodeAt(c);
    if (port != null) {
      _gesture = 'connect';
      _connectFrom = port;
    } else if (hit != null) {
      _gesture = 'move';
      if (!selection.nodes.contains(hit.slot)) {
        selection.selectNodes([hit.slot], toggle: HardwareKeyboard.instance.isShiftPressed);
      }
      controller.selectNode(hit.id);
      onApplied?.call('select');
    } else if (forceMarquee || HardwareKeyboard.instance.isShiftPressed) {
      _gesture = 'marquee';
    } else {
      _gesture = 'pan';
      _panCenter = view.center;
    }
  }

  void move(PointerMoveEvent e) {
    if (_gesture == 'none') return;
    if (!_moved && (e.localPosition - _downLocal).distance < _slop) return;
    final c = view.toCanvas(e.localPosition);
    switch (_gesture) {
      case 'pan':
        view.center = _panCenter - (e.localPosition - _downLocal) / view.scale;
        onApplied?.call('pan');
      case 'move':
        if (!_moved) _beginMove();
        final d = c - _lastCanvas;
        for (final slot in _moving) {
          final n = graph.slots[slot]!;
          n
            ..x += d.dx
            ..y += d.dy;
          graph.grid.put(slot, n.rect.topLeft);
        }
        renderer().moved(_moving);
        onApplied?.call('move');
      case 'connect':
        renderer().connectPreview(_connectFrom!.outPort, c);
        onApplied?.call('connect');
      case 'marquee':
        marquee.value = Rect.fromPoints(_downLocal, e.localPosition);
        onApplied?.call('marquee');
    }
    _moved = true;
    _lastCanvas = c;
  }

  void up(PointerEvent e) {
    final c = view.toCanvas(e.localPosition);
    switch (_gesture) {
      case 'move':
        if (_moved) _endMove();
      case 'pan':
        if (!_moved) {
          // A click on empty canvas: select the edge under it, or clear the selection.
          final edge = edgeAt(c);
          selection.selectEdge(edge?.id);
          if (edge != null) {
            controller.selectEdge(edge.id);
          } else {
            controller.selectNode(null);
          }
          onApplied?.call('select');
        }
      case 'connect':
        renderer().connectPreview(null, null);
        final target = nodeAt(c);
        if (target != null && target.slot != _connectFrom!.slot) {
          controller.connect(_connectFrom!.id, target.id);
          onApplied?.call('connected');
        }
        _connectFrom = null;
      case 'marquee':
        final r = marquee.value;
        marquee.value = null;
        if (r != null) {
          final cr = Rect.fromPoints(view.toCanvas(r.topLeft), view.toCanvas(r.bottomRight));
          selection.selectNodes([
            for (final slot in graph.grid.near(cr))
              if (graph.slots[slot] != null && cr.overlaps(graph.slots[slot]!.rect)) slot,
          ]);
          onApplied?.call('select');
        }
    }
    _gesture = 'none';
  }

  void hover(PointerHoverEvent e) {
    final n = nodeAt(view.toCanvas(e.localPosition));
    if (n?.slot != selection.hovered) {
      selection.hover(n?.slot);
      onApplied?.call('hover');
    }
  }

  void exit(PointerExitEvent e) => selection.hover(null);

  void signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    view.zoomAt(e.localPosition, exp(-e.scrollDelta.dy / 400));
    onApplied?.call('zoom');
  }

  /// Delete/Backspace removes the selected edge or nodes.
  KeyEventResult key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey != LogicalKeyboardKey.delete && e.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final edge = selection.edge;
    if (edge != null) {
      controller.deleteEdge(edge);
      selection.selectEdge(null);
      return KeyEventResult.handled;
    }
    final ids = [for (final s in selection.nodes) graph.slots[s]?.id].whereType<String>().toList();
    if (ids.isEmpty) return KeyEventResult.ignored;
    for (final id in ids) {
      controller.deleteNode(id);
    }
    selection.selectNodes(const []);
    return KeyEventResult.handled;
  }

  // ----- moving nodes: drawn every frame, sent as at most ~8 small ops per second, and once at the end -----

  void _beginMove() {
    _moving = {...selection.nodes};
    graph.dragging.addAll([for (final s in _moving) graph.slots[s]!.id]);
    renderer().beginMove(_moving);
    _sendTimer = Timer.periodic(const Duration(milliseconds: 125), (_) => _sendMoves());
  }

  void _sendMoves() {
    for (final slot in _moving) {
      final n = graph.slots[slot];
      if (n == null) continue;
      final doc = n.node.value;
      final x = n.x.round(), y = n.y.round();
      if (doc.x != x || doc.y != y) controller.moveNode(n.id, x, y);
    }
  }

  void _endMove() {
    _sendTimer?.cancel();
    _sendTimer = null;
    _sendMoves();
    final done = _moving;
    _moving = {};
    renderer().endMove(done);
    graph.dragging.removeAll([for (final s in done) graph.slots[s]?.id].whereType<String>());
  }

  void dispose() {
    _sendTimer?.cancel();
    marquee.dispose();
  }
}
