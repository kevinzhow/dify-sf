/// How the Steps view inserts a block: through the canvas's insertion ([NodeInsertion.addNodeAt] and its block
/// selector) for a "+" on an edge or after a handle, and, where branches meet, the same insertion on one edge into
/// the join with the join's other incoming edges moved onto the new node, as one undo step
/// ([EditorController.applyGraphChange] through [applyGraphChangeTo]).
///
/// Where new steps go on the canvas: exactly where the canvas's own insertion puts them (Dify's handleNodeAdd: on
/// an edge at the next node's place with the nodes after it moved one node width plus 60 px right; after a handle
/// to the right of the node, or 39 px below its lowest next node). It measures nodes by their canvas size; without a
/// laid-out canvas (the Steps view shown instead), [StepsActions.sizeOf] gives the size the canvas's card layout
/// will give the node, so new steps neither overlap nor stack. A duplicate goes below its original, at the first
/// free place ([StepsActions.duplicateBelow]). The canvas's Organize lays everything out again.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_graph.dart';
import '../../cards/dify_cards.dart';
import '../../ids.dart';
import '../../workflow/dify_json.dart';
import '../block_selector/block_selector.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../node_panel/workflow_panels.dart' show NodePanelActions;
import '../store/workflow_store.dart' show DifyJson;
import 'steps_layout.dart';

/// The size the canvas gives [n] once it has laid out its card (`reactFlowSizeOf` of the [DifyCards] layout), for
/// a node the canvas has not measured.
Size stepCardSize(Node n, Document doc) {
  final card = const DifyCards().layoutOf(n, doc).card;
  return Size((card.right + card.left).roundToDouble(), (card.bottom + card.left).roundToDouble());
}

/// The Steps view's actions: the node panel's ([NodePanelActions]: deleting a step others reference asks first),
/// measuring nodes the canvas has not laid out by their card layout, and placing duplicates where nothing is.
class StepsActions extends NodePanelActions {
  StepsActions({
    required super.controller,
    required super.canvas,
    required super.store,
    super.options,
    required super.confirmDelete,
  });

  static final _measured = Expando<Size>('step card size');

  /// The canvas's size of [n]; without one (no canvas laid out, no stored size), its card layout's.
  @override
  Size? sizeOf(Node n) => super.sizeOf(n) ?? (_measured[n] ??= stepCardSize(n, doc));

  /// [n]'s top-left on the canvas (a container's child is placed relative to its container).
  Offset absolutePositionOf(Node n) {
    final parent = doc.nodes[CanvasGraph.parentOf(n) ?? ''];
    final origin = Offset(n.x.toDouble(), n.y.toDouble());
    return parent == null ? origin : origin + absolutePositionOf(parent);
  }

  /// Where a copy of [n] goes: below it ([yOffset] apart, as handleNodeAdd stacks next nodes), moved further down
  /// past every top-level node it would overlap. Deterministic: the same document gives the same place.
  Offset freePlaceBelow(Node n) {
    final size = sizeOf(n) ?? const Size(nodeWidth, 90);
    final origin = absolutePositionOf(n);
    var at = Offset(origin.dx, origin.dy + size.height + yOffset);
    final taken = [
      for (final m in doc.nodes.values)
        if (CanvasGraph.parentOf(m) == null)
          Offset(m.x.toDouble(), m.y.toDouble()) & (sizeOf(m) ?? const Size(nodeWidth, 90)),
    ];
    for (var i = 0; i <= taken.length; i++) {
      final box = at & size;
      final hits = taken.where((r) => r.overlaps(box));
      if (hits.isEmpty) break;
      at = Offset(at.dx, hits.map((r) => r.bottom).reduce((a, b) => a > b ? a : b) + yOffset);
    }
    return at;
  }

  /// handleNodesDuplicate for step [nodeId], with the copy's top-left at [freePlaceBelow] instead of the canvas
  /// pointer (a phone has none, so consecutive copies would land on each other).
  Future<void> duplicateBelow(String nodeId) async {
    final n = doc.nodes[nodeId];
    if (n == null || nodesReadOnly) return;
    final pointer = store.mousePosition.value;
    final at = canvas.view.toScreen(freePlaceBelow(n));
    store.setMousePosition((pageX: at.dx, pageY: at.dy, elementX: at.dx, elementY: at.dy));
    try {
      await duplicateNodes(nodeId);
    } finally {
      store.setMousePosition(pointer);
    }
  }
}

extension StepsInsertion on WorkflowActions {
  /// The blocks a "+" at [insert] offers (as [NodeInsertion.showInsertBlockSelector] computes them for its point).
  List<String> stepBlocksAt(StepInsert insert, BlockSelectorData data) {
    switch (insert.at) {
      case InsertAfter(:final nodeId):
        final n = doc.nodes[nodeId];
        return n == null ? const [] : availableBlocksOf(n, data).next;
      case InsertBefore(:final nodeId):
        final n = doc.nodes[nodeId];
        return n == null ? const [] : availableBlocksOf(n, data).prev;
      case InsertOnEdge(:final edgeId):
        final e = doc.edges[edgeId];
        final s = e == null ? null : doc.nodes[e.source], t = e == null ? null : doc.nodes[e.target];
        if (s == null || t == null) return const [];
        // custom-edge.tsx: both ends' blocks under the edge's container (the target's flags, as edge data has).
        final inContainer = jsTruthy(plainOf(t.config['isInIteration'])) || jsTruthy(plainOf(t.config['isInLoop']));
        final all = availableNodeTypes(chatMode: data.chatMode, agentV2: data.agentV2);
        final prev = useAvailableBlocks(t.type, availableTypes: all, inContainer: inContainer).prev;
        final next = useAvailableBlocks(s.type, availableTypes: all, inContainer: inContainer).next;
        return [
          for (final b in prev)
            if (next.contains(b)) b,
        ];
    }
  }

  /// Opens the block selector for [insert] at [anchor] (global), as the canvas's "+" does, and inserts the block
  /// picked. Completes when the selector closes.
  Future<void> showStepBlockSelector(BuildContext context, StepInsert insert, {Rect? anchor}) async {
    if (nodesReadOnly) return;
    if (!insert.isJoin) return showInsertBlockSelector(context, insert.at, anchor: anchor);
    final data = BlockSelectorScope.of(context);
    final p = BlockSelectorPlacements.sourceHandle;
    await BlockSelector(
      placement: p.placement,
      sideOffset: p.sideOffset,
      alignOffset: p.alignOffset,
      availableBlocksTypes: stepBlocksAt(insert, data),
      onSelect: (type, defaults, {toolDefaultValue}) =>
          insertStep(insert, type, defaults, toolDefaultValue: toolDefaultValue),
    ).show(context, anchor: anchor);
  }

  /// Inserts a [type] block at [insert]: [addNodeAt] its point; at a join, on the first edge into the join with the
  /// others ([StepInsert.retarget]) moved onto the new node, in the same undo step. The new node is selected.
  void insertStep(StepInsert insert, String type, DifyJson? defaults, {DifyJson? toolDefaultValue}) {
    if (nodesReadOnly) return;
    final at = insert.at;
    if (!insert.isJoin || at is! InsertOnEdge) {
      return addNodeAt(at, type, defaults, toolDefaultValue: toolDefaultValue);
    }
    final first = doc.edges[at.edgeId];
    if (first == null) return;
    final g = reactFlowGraphOf(doc, sizeOf: sizeOf, selectedNodeId: controller.selectedNodeId);
    final id = newId('n');
    final base = handleNodeAdd(
      g.nodes,
      g.edges,
      nodeType: type,
      defaultValue: defaults,
      pluginDefaultValue: toolDefaultValue,
      prevNodeId: first.source,
      prevNodeSourceHandle: difyHandle(first.sourceHandle),
      nextNodeId: first.target,
      nextNodeTargetHandle: difyHandle(first.targetHandle),
      id: id,
    );
    if (base == null) return;
    final others = [
      for (final edgeId in insert.retarget)
        if (doc.edges[edgeId] case final e? when e.target == first.target && e.id != first.id) e,
    ];
    final change = GraphChange(
      event: base.event,
      nodeId: base.nodeId,
      addNodes: base.addNodes,
      addEdges: [
        ...base.addEdges,
        for (final e in others)
          {
            'id': '${e.source}-${difyHandle(e.sourceHandle)}-$id-target',
            'source': e.source,
            'sourceHandle': e.sourceHandle,
            'target': id,
            'targetHandle': 'target',
          },
      ],
      moveNodes: base.moveNodes,
      updateData: base.updateData,
      removeEdges: [...base.removeEdges, for (final e in others) e.id],
      removeNodes: base.removeNodes,
      selectNodeId: base.selectNodeId,
    );
    applyGraphChangeTo(controller, change);
    if (change.selectNodeId case final selected?) selectNode(selected);
  }
}
