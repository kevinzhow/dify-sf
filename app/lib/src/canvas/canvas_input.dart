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

/// How a left-button drag on empty canvas and the wheel behave (Dify's control modes).
enum ControlMode { pointer, hand }

/// Pointer and keyboard input on the canvas, hit-tested in canvas coordinates, behaving like Dify's editor:
/// * click selects one node (no modifier multi-select; multi-select is the box), a click near an edge selects it;
/// * drag moves the selection, drag from a source handle connects;
/// * pointer mode: drag on empty canvas draws a selection box, the wheel pans, Ctrl/Cmd + wheel zooms;
///   hand mode: drag on empty canvas pans, the wheel zooms; the middle button always pans;
/// * Delete/Backspace removes the selection.
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

  ControlMode mode = ControlMode.pointer;

  /// Called after an input changed what is drawn (benchmarks time input to frame).
  void Function(String kind)? onApplied;

  String _gesture = 'none'; // pan, move, connect, marquee
  Offset _downLocal = Offset.zero;
  Offset _lastCanvas = Offset.zero;
  Offset _panCenter = Offset.zero;
  bool _moved = false;
  (CanvasNode, String)? _connectFrom;
  Set<int> _moving = {};
  Timer? _sendTimer;

  static const _slop = 3.0;
  static const _portSlackPx = 4.0;
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

  /// The node and source handle whose box is under [c] (a little larger when zoomed out).
  (CanvasNode, String)? outPortAt(Offset c) {
    final slack = max(0.0, _portSlackPx / view.scale - 2);
    for (final slot in graph.grid.near(Rect.fromCenter(center: c, width: 40, height: 40))) {
      final n = graph.slots[slot];
      if (n == null) continue;
      for (final (id, box) in n.outHandles) {
        if (box.inflate(slack).contains(c)) return (n, id);
      }
    }
    return null;
  }

  CanvasEdge? edgeAt(Offset c) {
    final r = _edgeRadiusPx / view.scale;
    CanvasEdge? best;
    var bestD = r;
    for (final e in graph.edges) {
      final a = graph.slots[e.source]!, b = graph.slots[e.target]!;
      final box = Rect.fromPoints(a.outPortFor(e.sourceHandle), b.inPort).inflate(60 + r);
      if (!box.contains(c)) continue;
      final d = distanceToPolyline(c, edgeCurve(a.outPortFor(e.sourceHandle), b.inPort));
      if (d <= bestD) {
        best = e;
        bestD = d;
      }
    }
    return best;
  }

  // ----- pointer -----

  void down(PointerDownEvent e) {
    _downLocal = e.localPosition;
    final c = view.toCanvas(e.localPosition);
    _lastCanvas = c;
    _moved = false;
    if (e.buttons & kMiddleMouseButton != 0) {
      _gesture = 'pan';
      _panCenter = view.center;
      return;
    }
    if (e.buttons & kPrimaryButton == 0) return;
    final port = outPortAt(c), hit = nodeAt(c);
    if (port != null) {
      _gesture = 'connect';
      _connectFrom = port;
    } else if (hit != null) {
      _gesture = 'move';
      if (!selection.nodes.contains(hit.slot)) selection.selectNodes([hit.slot]);
      controller.selectNode(hit.id);
      onApplied?.call('select');
    } else if (mode == ControlMode.pointer) {
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
        renderer().connectPreview(_connectFrom!.$1.outPortFor(_connectFrom!.$2), c);
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
      case 'pan' || 'marquee' when !_moved:
        {
          // A click on empty canvas: select the edge under it, or clear the selection.
          marquee.value = null;
          final edge = edgeAt(c);
          selection.selectEdge(edge?.id);
          if (edge != null) {
            controller.selectEdge(edge.id);
          } else {
            controller.selectNode(null);
          }
          onApplied?.call('select');
        }
      case 'pan':
        break;
      case 'connect':
        renderer().connectPreview(null, null);
        final target = nodeAt(c);
        final (from, handle) = _connectFrom!;
        if (target != null && target.slot != from.slot && target.layout.target) {
          // dify-sf's own documents use `out`; Dify's handles keep their ids (branches, classes, ...).
          controller.connect(from.id, target.id, sourceHandle: handle == 'source' ? null : handle);
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

  /// The wheel pans in pointer mode and zooms with Ctrl/Cmd (or in hand mode), around the pointer.
  void signal(PointerSignalEvent e) {
    if (e is PointerScaleEvent) {
      view.zoomAt(e.localPosition, e.scale);
      onApplied?.call('zoom');
      return;
    }
    if (e is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (mode == ControlMode.hand || keys.isControlPressed || keys.isMetaPressed) {
      view.zoomAt(e.localPosition, exp(-e.scrollDelta.dy / 400));
      onApplied?.call('zoom');
    } else {
      view.center += e.scrollDelta / view.scale;
      onApplied?.call('pan');
    }
  }

  // Trackpad: two fingers pan, pinch zooms.
  double _lastPinch = 1;

  void panZoomStart(PointerPanZoomStartEvent e) => _lastPinch = 1;

  void panZoomUpdate(PointerPanZoomUpdateEvent e) {
    view.center -= e.panDelta / view.scale;
    if (e.scale != _lastPinch) {
      view.zoomAt(e.localPosition, e.scale / _lastPinch);
      _lastPinch = e.scale;
    }
    onApplied?.call('pan');
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
