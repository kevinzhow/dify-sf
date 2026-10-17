import 'dart:ui';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import 'spatial_grid.dart';

/// One node as the canvas sees it. Slots are reused when nodes go and come, so renderers can keep per-slot
/// resources (instances, components) in plain lists.
class CanvasNode {
  CanvasNode(this.slot, Node node, this.size, this.order)
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

  /// Position on the canvas; follows the document except while this client drags the node.
  double x;
  double y;
  Size size;

  String get id => node.value.id;
  String get type => node.value.type;
  Rect get rect => Rect.fromLTWH(x, y, size.width, size.height);
  Offset get center => rect.center;
  Offset get inPort => Offset(x, y + size.height / 2);
  Offset get outPort => Offset(x + size.width, y + size.height / 2);
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
  CanvasGraph({required this.sizeOf});

  /// The card size of a node (cards differ by type and content).
  final Size Function(Node node) sizeOf;

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
      r = r == null ? n.rect : r.expandToInclude(n.rect);
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
        final c = CanvasNode(slot, node, sizeOf(node), _nextOrder++);
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
      final size = sizeOf(node);
      if (size != n.size) {
        n.size = size;
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
