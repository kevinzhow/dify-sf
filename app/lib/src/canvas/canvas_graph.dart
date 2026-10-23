import 'dart:ui';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import 'run_view.dart';
import 'spatial_grid.dart';

export 'run_view.dart' show NodeRunView, EdgeRunView;

/// Where a node's card and handles sit, relative to the node's position (the top-left of React Flow's node element,
/// which is the selection frame: the card sits 1 px inside it).
class CardLayout {
  const CardLayout({
    required this.card,
    Rect? visual,
    this.sources = const {'source': CanvasNode.defaultHandleY},
    this.target = true,
    this.underlay = false,
  }) : visual = visual ?? card;

  /// The card (hit testing, frames).
  final Rect card;

  /// Everything drawn for the node (the card, plus the START/TRIGGER label container of entry nodes).
  final Rect visual;

  /// Source handles by id, as the y of the handle's middle below the card's top.
  final Map<String, double> sources;

  /// Whether the node has a target (input) handle.
  final bool target;

  /// Drawn under the edges and every other node, selected or not, without the selected frame (the card shows its
  /// own selection): Dify's notes (`.react-flow__node-custom-note { z-index: -1 }`).
  final bool underlay;
}

/// One node as the canvas sees it. Slots are reused when nodes go and come, so renderers can keep per-slot
/// resources (instances, components) in plain lists.
class CanvasNode {
  CanvasNode(this.slot, Node node, this.layout, this.order)
    : node = ValueNotifier(node),
      x = node.x.toDouble(),
      y = node.y.toDouble();

  final int slot;

  /// Stacking: later nodes lie above earlier ones (selected nodes above all).
  final int order;

  /// The container (iteration, loop) this node is inside; its position is then relative to the container's.
  String? parentId;

  /// How deeply nested the node is (0 at the top level); nested nodes and their edges lie above their container.
  int depth = 0;

  /// The document's node (content changes are published here; cards listen).
  final ValueNotifier<Node> node;

  /// The node's run fields as the canvas shows them (local view state, see [NodeRunView]).
  final run = ValueNotifier(NodeRunView.idle);

  /// What of [run] the card itself draws ([NodeRunView.forCard]: the renderer dims the node), so a card is not
  /// rebuilt (or recaptured) when only the dimming changes.
  final cardRun = ValueNotifier(NodeRunView.idle);

  /// The node is selected (cards whose content depends on it listen: Dify's retry row).
  final selected = ValueNotifier(false);

  /// The run status the canvas shows: idle, running, paused, succeeded, failed, exception.
  String get status => run.value.status;

  /// The pointer is over the card (Dify raises its shadow).
  final hovered = ValueNotifier(false);

  /// Position on the canvas; follows the document except while this client drags the node.
  double x;
  double y;
  CardLayout layout;

  String get id => node.value.id;
  String get type => node.value.type;

  /// The card on the canvas.
  Rect get rect => layout.card.shift(Offset(x, y));

  /// Everything drawn for the node.
  Rect get visual => layout.visual.shift(Offset(x, y));
  Size get size => layout.card.size;
  Offset get center => rect.center;
  // Handles (node-handle.tsx): 16 x 16 boxes straddling the card's side. React Flow connects at the box's outer side,
  // half way down.
  static const handleBox = 16.0;
  // Measured from the card's outer edge. Dify positions the 16 px handle box inside the card's 1 px border with
  // `-right-[9px] top-4 translate-y-0`; React Flow's own `transform: translate(0, -50%)` still applies (Tailwind v4's
  // `translate-*` set the separate `translate` property), so the box's middle, where edges attach, is 1 + 16 - 8 + 8
  // = 17 px down, and its outer side 8 px outside the card.
  static const handleOut = 8.0;
  static const defaultHandleY = 17.0;

  /// The target (input) handle's connection point.
  Offset get inPort => Offset(rect.left - handleOut, rect.top + defaultHandleY);

  /// The default source handle's connection point.
  Offset get outPort => outPortFor('source');

  /// A source handle's connection point (an unknown id, or dify-sf's own `out`, is the first handle).
  Offset outPortFor(String handle) {
    final y = layout.sources[handle] ?? layout.sources.values.firstOrNull ?? defaultHandleY;
    return Offset(rect.right + handleOut, rect.top + y);
  }

  /// Source handles' hit boxes by id.
  Iterable<(String, Rect)> get outHandles => [
    for (final e in layout.sources.entries)
      (
        e.key,
        Rect.fromLTWH(rect.right + handleOut - handleBox, rect.top + e.value - handleBox / 2, handleBox, handleBox),
      ),
  ];

  /// The target handle's hit box.
  Rect get inHandle =>
      Rect.fromLTWH(rect.left - handleOut, rect.top + defaultHandleY - handleBox / 2, handleBox, handleBox);
}

class CanvasEdge {
  const CanvasEdge(this.id, this.source, this.target, {this.sourceHandle = 'out', this.targetHandle = 'in'});
  final String id;
  final int source;
  final int target;
  final String sourceHandle;
  final String targetHandle;
}

/// What changed in one [CanvasGraph.sync].
class CanvasChange {
  final added = <CanvasNode>[];
  final removed = <CanvasNode>[];
  final moved = <CanvasNode>[];
  final resized = <CanvasNode>[];

  /// Nodes whose content changed (title, config): their captures are stale.
  final changed = <CanvasNode>[];
  bool edgesChanged = false;

  bool get isEmpty =>
      added.isEmpty && removed.isEmpty && moved.isEmpty && resized.isEmpty && changed.isEmpty && !edgesChanged;
}

/// The document's nodes and edges, kept in slots.
class CanvasGraph {
  CanvasGraph({required this.layoutOf});

  /// A node's card layout (cards differ by type and content, and show labels of other nodes; a few by run state
  /// and selection: Dify's retry row).
  final CardLayout Function(Node node, Document doc, {NodeRunView run, bool selected}) layoutOf;

  /// Edge id → its run fields (local view state).
  Map<String, EdgeRunView> edgeRun = const {};

  /// How [e] is stroked now (custom-edge.tsx): its run view, selection, and whether it leaves a fail branch.
  EdgeStroke strokeOf(CanvasEdge e, {bool selected = false}) => customEdgeStroke(
    edgeRun[e.id] ?? EdgeRunView.idle,
    selected: selected,
    dimmed: dimming && !e.id.startsWith('tmp_'),
    isTemp: e.id.startsWith('tmp_'),
    connectedNodeIsHovering: e.id.startsWith('tmp_') || hoveredNode == e.source || hoveredNode == e.target,
    isFailBranch: e.sourceHandle == 'fail-branch',
  );

  /// The workflow's Start node (system variables are shown under it).
  Node? get startNode => _byId.values.map((n) => n.node.value).where((n) => n.type == 'start').firstOrNull;

  final slots = <CanvasNode?>[];
  final _byId = <String, CanvasNode>{};
  final _free = <int>[];
  int _nextOrder = 0;
  List<CanvasEdge> _edges = const [];
  List<CanvasEdge> temporaryEdges = const [];
  List<CanvasEdge> get edges => temporaryEdges.isEmpty ? _edges : [..._edges, ...temporaryEdges];
  bool dimming = false;
  int? hoveredNode;

  /// Node ids being dragged locally: the document does not move them until the drag ends.
  final dragging = <String>{};

  /// Where the nodes are, for hit testing and culling.
  final grid = SpatialGrid();

  /// Where the canvas origin was on screen (React Flow's viewport x, y) when the view last came to rest; cards whose
  /// content depends on the viewport listen to it (React Flow backgrounds inside containers).
  final restingOrigin = ValueNotifier(Offset.zero);

  int _depth(Node n, Document doc) {
    var d = 0;
    for (var p = parentOf(n); p != null && d < 8; p = doc.nodes[p] == null ? null : parentOf(doc.nodes[p]!)) {
      d++;
    }
    return d;
  }

  /// A node's descendants (children of containers, recursively).
  Iterable<CanvasNode> descendantsOf(String id) sync* {
    for (final n in _byId.values) {
      if (n.parentId == id) {
        yield n;
        yield* descendantsOf(n.id);
      }
    }
  }

  Iterable<CanvasNode> get nodes => _byId.values;
  int get length => _byId.length;
  CanvasNode? operator [](String id) => _byId[id];

  Rect get bounds {
    Rect? r;
    for (final n in _byId.values) {
      r = r == null ? n.visual : r.expandToInclude(n.visual);
    }
    return r ?? Rect.zero;
  }

  /// The container a node sits in (Dify keeps `parentId` in `_dify_node`).
  static String? parentOf(Node n) => switch (n.config['_dify_node']) {
    VMap(:final entries) => switch (entries['parentId']) {
      VString(:final value) when value.isNotEmpty => value,
      _ => null,
    },
    _ => null,
  };

  /// A container's absolute position (its children's positions are relative to it).
  Offset absoluteOf(String id, Document doc, [int guard = 0]) {
    final n = doc.nodes[id];
    if (n == null) return Offset.zero;
    final parent = parentOf(n);
    final own = dragging.contains(id) && _byId[id] != null
        ? Offset(_byId[id]!.x, _byId[id]!.y) - (parent == null ? Offset.zero : absoluteOf(parent, doc, guard + 1))
        : Offset(n.x.toDouble(), n.y.toDouble());
    if (parent == null || guard > 8 || doc.nodes[parent] == null) return own;
    return absoluteOf(parent, doc, guard + 1) + own;
  }

  /// Lays [n] out again for its run state and selection; whether its layout changed.
  bool relayout(CanvasNode n, Document doc) {
    final layout = layoutOf(n.node.value, doc, run: n.cardRun.value, selected: n.selected.value);
    if (layout.card == n.layout.card &&
        layout.visual == n.layout.visual &&
        layout.underlay == n.layout.underlay &&
        mapEquals(layout.sources, n.layout.sources)) {
      return false;
    }
    n.layout = layout;
    grid.put(n.slot, n.rect.topLeft);
    return true;
  }

  CanvasChange sync(Document doc) {
    final change = CanvasChange();
    for (final id in [..._byId.keys]) {
      if (!doc.nodes.containsKey(id)) {
        final n = _byId.remove(id)!;
        slots[n.slot] = null;
        _free.add(n.slot);
        grid.remove(n.slot);
        change.removed.add(n);
      }
    }
    for (final node in doc.nodes.values) {
      final n = _byId[node.id];
      if (n == null) {
        final slot = _free.isNotEmpty ? _free.removeLast() : slots.length;
        final c = CanvasNode(slot, node, layoutOf(node, doc), _nextOrder++);
        final at = absoluteOf(node.id, doc);
        c
          ..x = at.dx
          ..y = at.dy
          ..parentId = parentOf(node)
          ..depth = _depth(node, doc);
        if (slot == slots.length) {
          slots.add(c);
        } else {
          slots[slot] = c;
        }
        _byId[node.id] = c;
        grid.put(slot, c.rect.topLeft);
        change.added.add(c);
        continue;
      }
      final at = absoluteOf(node.id, doc);
      if (!dragging.contains(node.id) && (n.x != at.dx || n.y != at.dy)) {
        // Moved itself, or its container moved.
        n
          ..x = at.dx
          ..y = at.dy;
        grid.put(n.slot, n.rect.topLeft);
        change.moved.add(n);
      }
      if (identical(n.node.value, node)) continue;
      final old = n.node.value;
      n.node.value = node;
      n
        ..parentId = parentOf(node)
        ..depth = _depth(node, doc);
      final layout = layoutOf(node, doc, run: n.cardRun.value, selected: n.selected.value);
      if (layout.card != n.layout.card ||
          layout.visual != n.layout.visual ||
          layout.underlay != n.layout.underlay ||
          !mapEquals(layout.sources, n.layout.sources)) {
        n.layout = layout;
        change.resized.add(n);
      }
      if (old.title != node.title || old.type != node.type || !mapEquals(old.config, node.config)) {
        change.changed.add(n);
      }
    }
    final edges = <CanvasEdge>[
      for (final e in doc.edges.values)
        if (_byId[e.source] != null && _byId[e.target] != null)
          CanvasEdge(
            e.id,
            _byId[e.source]!.slot,
            _byId[e.target]!.slot,
            sourceHandle: e.sourceHandle,
            targetHandle: e.targetHandle,
          ),
    ];
    List<Object> key(List<CanvasEdge> es) => [
      for (final e in es) (e.id, e.source, e.target, e.sourceHandle, e.targetHandle),
    ];
    if (!listEquals(key(edges), key(_edges))) {
      _edges = edges;
      change.edgesChanged = true;
    }
    if (change.added.isNotEmpty || change.removed.isNotEmpty || change.moved.isNotEmpty || change.resized.isNotEmpty) {
      change.edgesChanged = true;
    }
    return change;
  }
}
