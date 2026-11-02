/// How the Steps view inserts a block: through the canvas's insertion ([NodeInsertion.addNodeAt] and its block
/// selector) for a "+" on an edge or after a handle, and, where branches meet, the same insertion on one edge into
/// the join with the join's other incoming edges moved onto the new node, as one undo step
/// ([EditorController.applyGraphChange] through [applyGraphChangeTo]).
library;

import 'package:flutter/widgets.dart';

import '../../ids.dart';
import '../../workflow/dify_json.dart';
import '../block_selector/block_selector.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../store/workflow_store.dart' show DifyJson;
import 'steps_layout.dart';

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
