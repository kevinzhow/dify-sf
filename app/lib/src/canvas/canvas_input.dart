import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editor/editor_controller.dart';
import '../editor/undo_manager.dart';
import 'canvas_graph.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'edge_curve.dart';

/// How a left-button drag on empty canvas and the wheel behave (Dify's control modes; Dify's stored values are the
/// names). In comment mode a press on the canvas does nothing (placing comments is the comment layer's).
enum ControlMode { pointer, hand, comment }

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
    this.modeSource,
    this.readOnly = _never,
    this.validConnection = _any,
    this.nodeDrag,
    this.nodeDragStop,
    this.connectStart,
    this.connectEnd,
    this.connectMove,
    this.connectDrop,
  });

  static bool _never() => false;
  static bool _any(String source, String sourceHandle, String target) => true;

  /// Whether a connection dropped from [sourceHandle] of [source] on [target] becomes an edge (React Flow's
  /// `isValidConnection`).
  final bool Function(String source, String sourceHandle, String target) validConnection;

  /// Where the grabbed (top-level) node goes when the drag puts its top-left at the given position; null: there.
  final Offset? Function(String nodeId, Offset position)? Function()? nodeDrag;

  /// The drag ended.
  final VoidCallback? Function()? nodeDragStop;

  /// A connection drag began from a node's source handle / ended.
  final void Function(String nodeId, String handleId)? Function()? connectStart;
  final VoidCallback? Function()? connectEnd;
  final void Function(String, String, String?, Offset)? Function()? connectMove;
  final void Function(String, String, String, Offset)? Function()? connectDrop;

  /// Dify's `nodesReadOnly`: nodes are selected but not dragged, handles do not connect, Delete does nothing.
  final bool Function() readOnly;

  final EditorController controller;
  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final CanvasRenderer Function() renderer;

  /// The box being dragged out (screen coordinates), for the overlay.
  final marquee = ValueNotifier<Rect?>(null);

  /// The connection being dragged out (canvas coordinates: the source handle, the pointer), for the overlay.
  final connectLine = ValueNotifier<(Offset, Offset)?>(null);

  /// Dify's control mode (pointer by default).
  final ValueListenable<ControlMode>? modeSource;
  ControlMode get mode => modeSource?.value ?? ControlMode.pointer;

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

  /// The nodes a drag is moving now (empty between drags): a new renderer takes them over mid-drag.
  Set<int> get moving => _moving;

  /// Pointers the live card took (its editor, toolbar, resize handle): no canvas gesture for them.
  final _claimed = <int>{};

  void claim(PointerDownEvent e) => _claimed.add(e.pointer);
  bool claimed(PointerEvent e) => _claimed.contains(e.pointer);

  // React Flow's d3 double-click: double the zoom (Shift halves it), anchored at the pointer.
  // Feed the recognizer without delaying our raw pointer selection/drag handling. Interactive card controls
  // either claim the pointer or win the gesture arena, so editing text never zooms the canvas.
  Offset _doubleClickAt = Offset.zero;
  late final _doubleClick = DoubleTapGestureRecognizer()
    ..onDoubleTapDown = ((details) => _doubleClickAt = details.localPosition)
    ..onDoubleTap = () => view.zoomAt(_doubleClickAt, HardwareKeyboard.instance.isShiftPressed ? 0.5 : 2);

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

  /// What a click at [c] lands on: the top-most node, unless it is an underlay (a note) with an edge over it.
  CanvasNode? _clickTarget(Offset c) {
    final n = nodeAt(c);
    return n != null && n.layout.underlay && edgeAt(c) != null ? null : n;
  }

  /// Nested nodes lie above their container even when it is selected (React Flow: nested z-index 1001 > the 1000 a
  /// selected node gets), then selected nodes, then later nodes above earlier ones; underlays (notes) below all.
  int stackKey(CanvasNode n) => n.layout.underlay
      ? n.order - (1 << 50)
      : (n.depth << 44) + (selection.nodes.contains(n.slot) ? 1 << 40 : 0) + n.order;

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
    if (claimed(e)) return;
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
    // Comment mode: nodes neither select nor drag, nothing connects; clicks are the comment layer's.
    if (mode == ControlMode.comment) return;
    final locked = readOnly();
    final port = locked ? null : outPortAt(c), hit = _clickTarget(c);
    if (port == null) _doubleClick.addPointer(e);
    if (port != null) {
      _gesture = 'connect';
      _connectFrom = port;
      connectStart?.call()?.call(port.$1.id, port.$2);
    } else if (hit != null) {
      _gesture = locked ? 'none' : 'move';
      _grabbed = hit.slot;
      if (!selection.nodes.contains(hit.slot)) selection.selectNodes([hit.slot]);
      controller.selectNode(hit.id);
      onApplied?.call('select');
    } else if (mode == ControlMode.pointer) {
      _gesture = 'marquee';
    } else if (mode == ControlMode.hand) {
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
        final d = _clamped(c - _lastCanvas);
        // The grabbed node follows the pointer from where the drag (not the snapping) put it.
        var grabShift = d;
        final grab = _grabRaw == null ? null : graph.slots[_grabbed!];
        if (grab != null) {
          _grabRaw = _grabRaw! + d;
          final to = nodeDrag?.call()?.call(grab.id, _grabRaw!) ?? _grabRaw!;
          grabShift = to - Offset(grab.x, grab.y);
        }
        for (final slot in _moving) {
          final n = graph.slots[slot]!;
          final shift = _grabGroup.contains(slot) ? grabShift : d;
          n
            ..x += shift.dx
            ..y += shift.dy;
          graph.grid.put(slot, n.rect.topLeft);
        }
        renderer().moved(_moving);
        onApplied?.call('move');
      case 'connect':
        final from = _connectFrom!.$1.outPortFor(_connectFrom!.$2);
        renderer().connectPreview(from, c);
        connectLine.value = (from, c);
        connectMove?.call()?.call(_connectFrom!.$1.id, _connectFrom!.$2, nodeAt(c)?.id, c);
        onApplied?.call('connect');
      case 'marquee':
        marquee.value = Rect.fromPoints(_downLocal, e.localPosition);
        onApplied?.call('marquee');
    }
    _moved = true;
    _lastCanvas = c;
  }

  void up(PointerEvent e) {
    if (_claimed.remove(e.pointer)) return;
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
        connectLine.value = null;
        final target = nodeAt(c);
        final (from, handle) = _connectFrom!;
        if (target != null &&
            target.slot != from.slot &&
            target.layout.target &&
            validConnection(from.id, handle, target.id)) {
          // dify-sf's own documents use `out`; Dify's handles keep their ids (branches, classes, ...).
          controller.connect(from.id, target.id, sourceHandle: handle == 'source' ? null : handle);
          onApplied?.call('connected');
          connectDrop?.call()?.call(from.id, handle, target.id, c);
        }
        _connectFrom = null;
        connectEnd?.call()?.call();
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
    final c = view.toCanvas(e.localPosition);
    final n = _clickTarget(c);
    if (n?.slot != selection.hovered) {
      selection.hover(n?.slot);
      onApplied?.call('hover');
    }
    // handleEdgeEnter / handleEdgeLeave do nothing while the nodes are read-only.
    selection.hoveredEdge.value = n == null && !readOnly() ? edgeAt(c)?.id : null;
  }

  void exit(PointerExitEvent e) {
    selection.hover(null);
    selection.hoveredEdge.value = null;
  }

  /// The wheel pans in pointer mode and zooms with Ctrl/Cmd (or in hand mode), around the pointer; unless something
  /// on the canvas takes it first (the pointer signal resolver: the live note's editor).
  void signal(PointerSignalEvent e) => GestureBinding.instance.pointerSignalResolver.register(e, _signal);

  void _signal(PointerSignalEvent e) {
    if (e is PointerScaleEvent) {
      view.zoomAt(e.localPosition, e.scale);
      onApplied?.call('zoom');
      return;
    }
    if (e is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    // React Flow's panOnScroll is on in pointer mode only: elsewhere the wheel zooms.
    if (mode != ControlMode.pointer || keys.isControlPressed || keys.isMetaPressed) {
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

  /// Delete/Backspace removes the selected edge or nodes; the arrow keys move the selected nodes ([nodeKey] without
  /// a focused node: Dify's focused selection).
  KeyEventResult key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_arrows.containsKey(e.logicalKey)) return selection.nodes.isEmpty ? KeyEventResult.ignored : nodeKey(null, e);
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey != LogicalKeyboardKey.delete && e.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    if (readOnly()) return KeyEventResult.ignored;
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

  // ----- the keyboard (use-node-keyboard-interactions.ts, utils/keyboard-movement.ts) -----

  static final _arrows = {
    LogicalKeyboardKey.arrowLeft: const Offset(-1, 0),
    LogicalKeyboardKey.arrowRight: const Offset(1, 0),
    LogicalKeyboardKey.arrowUp: const Offset(0, -1),
    LogicalKeyboardKey.arrowDown: const Offset(0, 1),
  };

  static bool _fixed(CanvasNode n) => n.type == 'iteration-start' || n.type == 'loop-start';

  /// A key on the [focused] node (null: on the selection). Enter / Space selects the node and Escape deselects it;
  /// an arrow moves it, or the selection when it is selected, by 5 px (20 with Shift) as one undo step
  /// (NodeDragStop); a child stays inside its container. Nothing happens while the nodes are read-only, in comment
  /// mode, with Alt / Ctrl / Meta, or on an iteration / loop start.
  KeyEventResult nodeKey(CanvasNode? focused, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final dir = _arrows[k];
    final isSelectionKey =
        k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.escape;
    if (dir == null && !isSelectionKey) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isAltPressed || keys.isControlPressed || keys.isMetaPressed) return KeyEventResult.handled;
    if (readOnly() || mode == ControlMode.comment) return KeyEventResult.handled;
    if (focused != null && _fixed(focused)) return KeyEventResult.handled;
    if (isSelectionKey) {
      if (focused == null || e is! KeyDownEvent) return KeyEventResult.handled;
      if (k == LogicalKeyboardKey.escape) {
        selection.selectNodes(const []);
        controller.selectNode(null);
      } else {
        selection.selectNodes([focused.slot]);
        controller.selectNode(focused.id);
      }
      onApplied?.call('select');
      return KeyEventResult.handled;
    }
    final step = keys.isShiftPressed ? 20.0 : 5.0;
    final movement = dir! * step;
    final moving = {
      if (focused != null && !selection.nodes.contains(focused.slot))
        focused.slot
      else
        for (final s in selection.nodes)
          if (graph.slots[s] case final n? when !_fixed(n)) s,
    };
    // A moving container already carries its children.
    final leaders = [
      for (final s in moving)
        if (!_hasAncestorIn(graph.slots[s]!, moving)) graph.slots[s]!,
    ];
    final moves = <(String, int, int)>[];
    for (final n in leaders) {
      final parent = n.parentId == null ? null : graph[n.parentId!];
      final own = parent == null ? Offset(n.x, n.y) : Offset(n.x - parent.x, n.y - parent.y);
      var next = own + movement;
      if (parent != null) {
        final box = parent.rect, w = n.layout.visual.width + 2, h = n.layout.visual.height + 2;
        next = Offset(
          next.dx.clamp(16, max(16.0, box.width + 2 - 16 - w)),
          next.dy.clamp(65, max(65.0, box.height + 2 - 20 - h)),
        );
      }
      final x = next.dx.round(), y = next.dy.round();
      // Against the container's side: Dify keeps the position (getRestricted{Iteration,Loop}Position).
      if (x == own.dx.round() && y == own.dy.round()) continue;
      moves.add((n.id, x, y));
    }
    if (moves.isEmpty) return KeyEventResult.handled;
    controller.undo.begin(HistoryEvent.nodeDragStop, nodeId: focused?.id);
    try {
      for (final (id, x, y) in moves) {
        controller.moveNode(id, x, y);
      }
    } finally {
      controller.undo.end();
    }
    onApplied?.call('move');
    return KeyEventResult.handled;
  }

  // ----- moving nodes: drawn every frame, sent as at most ~8 small ops per second, and once at the end -----

  /// The nodes the user drags (their containers' children come along).
  Set<int> _leaders = {};

  /// The node under the pointer when the drag began; [_grabRaw] is where the drag alone has put it (null: it is not
  /// snapped: inside a container, or an iteration / loop start), [_grabGroup] it and its children.
  int? _grabbed;
  Offset? _grabRaw;
  Set<int> _grabGroup = {};

  void _beginMove() {
    _leaders = {
      for (final s in selection.nodes)
        // A node whose container is also dragged moves with the container.
        if (!_hasAncestorIn(graph.slots[s]!, selection.nodes)) s,
    };
    _moving = {
      for (final s in _leaders) ...[s, for (final d in graph.descendantsOf(graph.slots[s]!.id)) d.slot],
    };
    graph.dragging.addAll([for (final s in _moving) graph.slots[s]!.id]);
    final grab = _grabbed == null ? null : graph.slots[_grabbed!];
    final snaps =
        grab != null &&
        _leaders.contains(grab.slot) &&
        grab.parentId == null &&
        grab.type != 'iteration-start' &&
        grab.type != 'loop-start';
    _grabRaw = snaps ? Offset(grab.x, grab.y) : null;
    _grabGroup = snaps ? {grab.slot, for (final d in graph.descendantsOf(grab.id)) d.slot} : {};
    renderer().beginMove(_moving);
    // One drag is one undo step (Dify's NodeDragStop).
    controller.undo.begin(HistoryEvent.nodeDragStop, nodeId: graph.slots[_leaders.first]?.id);
    _sendTimer = Timer.periodic(const Duration(milliseconds: 125), (_) => _sendMoves());
  }

  bool _hasAncestorIn(CanvasNode n, Set<int> slots) {
    for (var p = n.parentId; p != null; p = graph[p]?.parentId) {
      final pn = graph[p];
      if (pn != null && slots.contains(pn.slot)) return true;
    }
    return false;
  }

  /// Children stay inside their container (Dify's getRestricted{Iteration,Loop}Position: 16 px from the sides, 65 px
  /// from the top, 20 px from the bottom), so the drag is limited to what keeps every dragged child inside.
  Offset _clamped(Offset d) {
    var dx = d.dx, dy = d.dy;
    for (final slot in _leaders) {
      final n = graph.slots[slot]!;
      final parent = n.parentId == null ? null : graph[n.parentId!];
      if (parent == null) continue;
      final box = parent.rect, own = Offset(n.x, n.y) - Offset(parent.x, parent.y);
      final w = n.layout.visual.width + 2, h = n.layout.visual.height + 2; // React Flow's node box
      dx = dx.clamp(16 - own.dx, box.width + 2 - 16 - w - own.dx);
      dy = dy.clamp(65 - own.dy, box.height + 2 - 20 - h - own.dy);
    }
    return Offset(dx, dy);
  }

  /// Positions are sent for the dragged nodes only (their children's are relative and do not change); a node inside
  /// a container sends its position relative to the container.
  void _sendMoves() {
    for (final slot in _leaders) {
      final n = graph.slots[slot];
      if (n == null) continue;
      final doc = n.node.value;
      final parent = n.parentId == null ? null : graph[n.parentId!];
      final rel = parent == null ? Offset(n.x, n.y) : Offset(n.x - parent.x, n.y - parent.y);
      final x = rel.dx.round(), y = rel.dy.round();
      if (doc.x != x || doc.y != y) controller.moveNode(n.id, x, y);
    }
  }

  void _endMove() {
    _sendTimer?.cancel();
    _sendTimer = null;
    _sendMoves();
    controller.undo.end();
    final done = _moving;
    _moving = {};
    renderer().endMove(done);
    graph.dragging.removeAll([for (final s in done) graph.slots[s]?.id].whereType<String>());
    _grabRaw = null;
    _grabGroup = {};
    nodeDragStop?.call()?.call();
  }

  void dispose() {
    _sendTimer?.cancel();
    marquee.dispose();
    connectLine.dispose();
    _doubleClick.dispose();
  }
}
