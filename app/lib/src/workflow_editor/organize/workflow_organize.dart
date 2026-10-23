/// hooks/use-workflow-organize.ts and its helpers (use-workflow-organize.helpers.ts): "Organize blocks" from the
/// control bar and Mod+O. Each iteration's and loop's interior is laid out first (and the container grown to fit
/// it), then the top level; the result is one undo step (`LayoutOrganize`) of `moveNode` ops for the nodes whose
/// position changed, plus the container sizes that changed.
///
/// Document positions are integers (the import rounds Dify's fractional positions and keeps the exact one in
/// `_dify_node.position`, which the export uses while it still rounds to the node's position): ELK's coordinates are
/// rounded the same way, as node insertion does. Positions of children are relative to their container, in Dify and
/// in the document alike.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import '../../canvas/canvas_controller.dart';
import '../../editor/editor_controller.dart';
import '../../editor/undo_manager.dart' show HistoryEvent;
import '../node_insertion/insert_block.dart' show reactFlowGraphOf;
import '../operator/actions.dart' show OperatorReadOnly;
import '../store/workflow_store.dart';
import 'elk_layout.dart';

export 'elk_layout.dart';

typedef ContainerSizeChange = ({double width, double height});
typedef LayerInfo = ({double minY, double maxHeight});

bool _isContainer(DifyJson n) => switch ((n['data'] as Map?)?['type']) {
  'loop' || 'iteration' => true,
  _ => false,
};

bool _isTopLevel(DifyJson n) => (n['parentId'] == null || n['parentId'] == '') && n['type'] == 'custom';

double _num(Object? v) => v is num ? v.toDouble() : 0;

/// getLayoutContainerNodes: the top-level iterations and loops.
List<DifyJson> getLayoutContainerNodes(List<DifyJson> nodes) => [
  for (final n in nodes)
    if (_isContainer(n) && _isTopLevel(n)) n,
];

/// getContainerSizeChanges: each container grown (never shrunk) to hold its laid-out children with padding.
Map<String, ContainerSizeChange> getContainerSizeChanges(
  List<DifyJson> parentNodes,
  Map<String, LayoutResult> childLayoutsMap,
) => {
  for (final parent in parentNodes)
    if (childLayoutsMap[parent['id']] case final layout? when layout.nodes.isNotEmpty)
      parent['id']! as String: (
        width: math.max(
          _num(parent['width']),
          layout.bounds.maxX - layout.bounds.minX + nodeLayoutHorizontalPadding * 2,
        ),
        height: math.max(
          _num(parent['height']),
          layout.bounds.maxY - layout.bounds.minY + nodeLayoutVerticalPadding * 2,
        ),
      ),
};

/// applyContainerSizeChanges: the containers' React Flow and data sizes.
List<DifyJson> applyContainerSizeChanges(List<DifyJson> nodes, Map<String, ContainerSizeChange> changes) => [
  for (final n in nodes)
    if (changes[n['id']] case final size? when _isContainer(n))
      {
        ...n,
        'width': size.width,
        'height': size.height,
        'data': {...(n['data']! as Map), 'width': size.width, 'height': size.height},
      }
    else
      n,
];

/// createLayerMap: per ELK layer, its top and tallest node.
Map<int, LayerInfo> createLayerMap(LayoutResult layout) {
  final map = <int, LayerInfo>{};
  for (final info in layout.nodes.values) {
    final layer = info.layer;
    if (layer == null) continue;
    final existing = map[layer];
    map[layer] = (
      minY: existing == null || info.y < existing.minY ? info.y : existing.minY,
      maxHeight: existing == null || info.height > existing.maxHeight ? info.height : existing.maxHeight,
    );
  }
  return map;
}

double _alignedY(LayoutInfo info, Map<int, LayerInfo> layerMap) {
  final layer = info.layer == null ? null : layerMap[info.layer];
  if (layer == null) return info.y;
  return layer.minY + layer.maxHeight / 2 - info.height / 2;
}

/// applyLayoutToNodes: top-level nodes at their layout position (centred in their layer when ELK reports layers),
/// each container's children at theirs inside the container's padding. Nodes without a layout keep their position.
List<DifyJson> applyLayoutToNodes({
  required List<DifyJson> nodes,
  required LayoutResult layout,
  required List<DifyJson> parentNodes,
  required Map<String, LayoutResult> childLayoutsMap,
}) {
  final layerMap = createLayerMap(layout);
  final parents = {for (final p in parentNodes) p['id']};
  return [
    for (final n in nodes)
      if (_isTopLevel(n) && layout.nodes[n['id']] != null)
        {
          ...n,
          'position': {'x': layout.nodes[n['id']]!.x, 'y': _alignedY(layout.nodes[n['id']]!, layerMap)},
        }
      else if (parents.contains(n['parentId']) && childLayoutsMap[n['parentId']]?.nodes[n['id']] != null)
        () {
          final child = childLayoutsMap[n['parentId']]!;
          final info = child.nodes[n['id']]!;
          return {
            ...n,
            'position': {
              'x': nodeLayoutHorizontalPadding + (info.x - child.bounds.minX),
              'y': nodeLayoutVerticalPadding + (info.y - child.bounds.minY),
            },
          };
        }()
      else
        n,
  ];
}

/// getLayoutByELK's signature (the top level's layout).
typedef RootLayout = LayoutResult Function(List<DifyJson> nodes, List<DifyJson> edges);

/// getLayoutForChildNodes's signature (a container's interior, null without children).
typedef ChildLayout = LayoutResult? Function(String parentNodeId, List<DifyJson> nodes, List<DifyJson> edges);

/// handleLayout's computation: the nodes as Dify's `setNodes` leaves them.
List<DifyJson> organizeNodes(
  List<DifyJson> nodes,
  List<DifyJson> edges, {
  RootLayout rootLayout = getLayoutByELK,
  ChildLayout childLayout = getLayoutForChildNodes,
}) {
  final parentNodes = getLayoutContainerNodes(nodes);
  final childLayoutsMap = <String, LayoutResult>{
    for (final p in parentNodes) p['id']! as String: ?childLayout(p['id']! as String, nodes, edges),
  };
  final resized = applyContainerSizeChanges(nodes, getContainerSizeChanges(parentNodes, childLayoutsMap));
  return applyLayoutToNodes(
    nodes: resized,
    layout: rootLayout(resized, edges),
    parentNodes: parentNodes,
    childLayoutsMap: childLayoutsMap,
  );
}

/// React Flow's measured size of a node (its element's offsetWidth/offsetHeight, whole pixels): the card and the
/// frame around it, which extends past the card on the right and bottom by the card's left inset (1 px for cards,
/// none for notes and iteration / loop start markers). Null when the node is not on the canvas.
Size? reactFlowSizeOf(CanvasController canvas, Node n) {
  final card = canvas.graph?[n.id]?.layout.card;
  if (card == null) return null;
  return Size((card.right + card.left).roundToDouble(), (card.bottom + card.left).roundToDouble());
}

/// useWorkflowOrganize: lays the workflow out and applies it to the shared document as one undo step.
class WorkflowOrganize {
  WorkflowOrganize({
    required this.controller,
    required this.canvas,
    required this.store,
    this.rootLayout = getLayoutByELK,
    this.childLayout = getLayoutForChildNodes,
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowStore store;
  final RootLayout rootLayout;
  final ChildLayout childLayout;

  /// handleLayout. Nothing while read-only; nothing either when ELK cannot lay the graph out (an edge to a node
  /// outside its level, a self-loop), where Dify's layout promise rejects.
  void handleLayout() {
    if (store.nodesReadOnly) return;
    store.setNodeAnimation(true);
    final doc = controller.doc;
    final graph = reactFlowGraphOf(doc, sizeOf: (n) => reactFlowSizeOf(canvas, n));
    final List<DifyJson> next;
    try {
      next = organizeNodes(graph.nodes, graph.edges, rootLayout: rootLayout, childLayout: childLayout);
    } on ArgumentError catch (e) {
      debugPrint('Organize blocks: $e');
      return;
    } on UnsupportedError catch (e) {
      debugPrint('Organize blocks: $e');
      return;
    }
    final before = {for (final n in graph.nodes) n['id']: n};
    final moves = <String, ({int x, int y})>{};
    final sizes = <({String node, List<String> path, Value value})>[];
    for (final n in next) {
      final id = n['id']! as String, old = before[id]!;
      if (!identical(n['position'], old['position'])) {
        final p = n['position']! as Map;
        moves[id] = (x: (p['x'] as num).round(), y: (p['y'] as num).round());
      }
      if (n['width'] != old['width'] || n['height'] != old['height']) {
        final node = doc.nodes[id]!;
        for (final (path, v) in [
          (const ['_dify_node', 'width'], n['width']),
          (const ['_dify_node', 'height'], n['height']),
          (const ['width'], n['width']),
          (const ['height'], n['height']),
        ]) {
          final value = Value.number(v! as num);
          if (ConfigTree.get(node.config, path) != value) sizes.add((node: id, path: path, value: value));
        }
      }
    }
    // Only what changed is sent; positions are last-writer-wins.
    controller.applyGraphChange(event: HistoryEvent.layoutOrganize, moveNodes: moves, setFields: sizes);
    canvas.setViewport(0, 0, 0.7);
  }
}
