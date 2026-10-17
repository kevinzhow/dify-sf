import 'dart:ui';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import 'spatial_grid.dart';

/// Where a node's card and handles sit, relative to the node's position (the top-left of React Flow's node element,
/// which is the selection frame: the card sits 1 px inside it).
class CardLayout {
  const CardLayout({
    required this.card,
    Rect? visual,
    this.sources = const {'source': CanvasNode.defaultHandleY},
    this.target = true,
  }) : visual = visual ?? card;

  /// The card (hit testing, frames).
  final Rect card;

  /// Everything drawn for the node (the card, plus the START/TRIGGER label container of entry nodes).
  final Rect visual;

  /// Source handles by id, as the y of the handle's middle below the card's top.
  final Map<String, double> sources;

  /// Whether the node has a target (input) handle.
  final bool target;
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

  /// The document's node (content changes are published here; cards listen).
  final ValueNotifier<Node> node;

  /// Run status shown on the canvas: idle, running, succeeded, failed, exception.
  final status = ValueNotifier('idle');

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
  // Measured from the card's outer edge (Dify positions handles inside the card's 1 px border: -right-[9px] and
  // top-4 put the box 8 px outside and its middle 25 px down).
  static const handleOut = 8.0;
  static const defaultHandleY = 25.0;

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

  /// A node's card layout (cards differ by type and content, and show labels of other nodes).
  final CardLayout Function(Node node, Document doc) layoutOf;

  /// The workflow's Start node (system variables are shown under it).
  Node? get startNode => _byId.values.map((n) => n.node.value).where((n) => n.type == 'start').firstOrNull;

  final slots = <CanvasNode?>[];
  final _byId = <String, CanvasNode>{};
  final _free = <int>[];
  int _nextOrder = 0;
  List<CanvasEdge> edges = const [];

  /// Node ids being dragged locally: the document does not move them until the drag ends.
  final dragging = <String>{};

  /// Where the nodes are, for hit testing and culling.
  final grid = SpatialGrid();

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
      if (identical(n.node.value, node)) continue;
      final old = n.node.value;
      n.node.value = node;
      if (!dragging.contains(node.id) && (old.x != node.x || old.y != node.y)) {
        n
          ..x = node.x.toDouble()
          ..y = node.y.toDouble();
        grid.put(n.slot, n.rect.topLeft);
        change.moved.add(n);
      }
      final layout = layoutOf(node, doc);
      if (layout.card != n.layout.card ||
          layout.visual != n.layout.visual ||
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
    if (!listEquals(key(edges), key(this.edges))) {
      this.edges = edges;
      change.edgesChanged = true;
    }
    if (change.added.isNotEmpty || change.removed.isNotEmpty || change.moved.isNotEmpty || change.resized.isNotEmpty) {
      change.edgesChanged = true;
    }
    return change;
  }
}
