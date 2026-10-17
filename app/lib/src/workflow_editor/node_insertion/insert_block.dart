/// Dify's handleNodeAdd / handleNodeChange on the collaborative document: the document's graph as React Flow's
/// JSON in, the [GraphChange] applied through [EditorController.applyGraphChange] as one undo step, and the block
/// selector opened where Dify opens it to insert (a node's handle "+", an edge's "+", the next-step section) or to
/// change a node.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/widgets/widgets.dart' show DifyPlacement;
import '../../editor/editor_controller.dart';
import '../../ids.dart';
import '../../workflow/dify_json.dart';
import '../block_selector/block_selector.dart';
import '../context_menu/context_menu.dart';
import '../node_panel/panel_edit.dart' show mergeValue;
import '../store/workflow_store.dart' show DifyJson;
import 'node_insertion.dart';

export 'node_insertion.dart';

/// Where a block picked in the selector goes: after a node's source handle, before a node's target handle, or on
/// an edge (between its two nodes).
sealed class InsertPoint {
  const InsertPoint();
}

/// After [nodeId]'s [sourceHandle] (its source handle's "+", the next-step section's add).
final class InsertAfter extends InsertPoint {
  const InsertAfter(this.nodeId, [this.sourceHandle = 'source']);
  final String nodeId, sourceHandle;
}

/// Before [nodeId]'s [targetHandle] (its target handle's "+").
final class InsertBefore extends InsertPoint {
  const InsertBefore(this.nodeId, [this.targetHandle = 'target']);
  final String nodeId, targetHandle;
}

/// On edge [edgeId] (its "+").
final class InsertOnEdge extends InsertPoint {
  const InsertOnEdge(this.edgeId);
  final String edgeId;
}

/// A document handle as Dify names it: dify-sf's own default handles `out` / `in` are Dify's `source` / `target`.
String difyHandle(String handle) => switch (handle) {
  'out' => 'source',
  'in' => 'target',
  _ => handle,
};

/// The document's graph as React Flow's JSON for [handleNodeAdd] / [handleNodeChange]: each node's [difyNodeOf]
/// with its measured size ([sizeOf]), `selected` for [selectedNodeId] and the `_targetBranches` workflow-init gives
/// if-else and question-classifier nodes; each edge's [difyEdgeOf] with Dify's handle names.
({List<DifyJson> nodes, List<DifyJson> edges}) reactFlowGraphOf(
  Document doc, {
  Size? Function(Node)? sizeOf,
  String? selectedNodeId,
}) => (
  nodes: [
    for (final n in doc.nodes.values)
      () {
        final json = difyNodeOf(n);
        final size = sizeOf?.call(n);
        if (size != null) {
          json
            ..['width'] = size.width
            ..['height'] = size.height;
        }
        final data = (json['data']! as Map).cast<String, Object?>();
        if (n.id == selectedNodeId) data['selected'] = true;
        final branches = _targetBranches(data);
        if (branches != null) data['_targetBranches'] = branches;
        return {...json, 'data': data};
      }(),
  ],
  edges: [
    for (final e in doc.edges.values)
      {
        ...difyEdgeOf(e, doc),
        'sourceHandle': difyHandle(e.sourceHandle),
        'targetHandle': difyHandle(e.targetHandle),
      },
  ],
);

/// utils/workflow-init.ts: an if-else's cases then `false`, a question classifier's classes.
List<DifyJson>? _targetBranches(DifyJson data) => switch (data['type']) {
  'if-else' => [
    for (final c in jsList(data['cases']))
      if (jsStr(jsGet(c, 'case_id')) case final id?) {'id': id, 'name': ''},
    {'id': 'false', 'name': ''},
  ],
  'question-classifier' => [
    for (final c in jsList(data['classes']))
      if (c is Map) c.cast<String, Object?>(),
  ],
  _ => null,
};

/// [change] applied to [c]'s document as one undo step: Dify's JSON becomes document nodes ([nodeFromDify]) and
/// edges, positions are rounded to the document's whole pixels.
void applyGraphChangeTo(EditorController c, GraphChange change) {
  final doc = c.doc;
  final added = [for (final n in change.addNodes) nodeFromDify(n, doc, id: n['id']! as String)];
  final named = added.where((n) => n.id == change.nodeId).firstOrNull;
  c.applyGraphChange(
    event: change.event,
    nodeId: change.nodeId,
    nodeTitle: named?.title,
    nodeType: named?.type,
    addNodes: added,
    moveNodes: {
      for (final MapEntry(key: id, value: p) in change.moveNodes.entries) id: (x: p.x.round(), y: p.y.round()),
    },
    setFields: [
      for (final MapEntry(key: id, value: data) in change.updateData.entries)
        for (final MapEntry(:key, :value) in data.entries)
          (node: id, path: [key], value: mergeValue(doc.nodes[id]?.config[key], value, doc)),
    ],
    removeEdges: change.removeEdges,
    addEdges: [
      for (final e in change.addEdges)
        Edge(
          id: e['id']! as String,
          source: e['source']! as String,
          sourceHandle: e['sourceHandle'] as String? ?? 'source',
          target: e['target']! as String,
          targetHandle: e['targetHandle'] as String? ?? 'target',
        ),
    ],
    removeNodes: change.removeNodes,
  );
}

/// useNodesInteractions' handleNodeAdd and handleNodeChange on the editor's document, and the block selectors that
/// lead to them.
extension NodeInsertion on WorkflowActions {
  ({List<DifyJson> nodes, List<DifyJson> edges}) get _graph =>
      reactFlowGraphOf(doc, sizeOf: sizeOf, selectedNodeId: controller.selectedNodeId);

  void _apply(GraphChange? change) {
    if (change == null) return;
    applyGraphChangeTo(controller, change);
    final selected = change.selectNodeId;
    if (selected != null) {
      selectNode(selected);
    } else {
      canvas.selection.selectNodes(const []);
      controller.selectNode(null);
    }
  }

  /// handleNodeAdd: a [type] node with [defaults] (the block selector's, Dify's `nodesMetaDataMap[type]
  /// .defaultValue`) and [toolDefaultValue] inserted at [at]. Nothing while the canvas is read-only.
  void addNodeAt(InsertPoint at, String type, DifyJson? defaults, {DifyJson? toolDefaultValue}) {
    if (nodesReadOnly) return;
    final g = _graph;
    final id = newId('n');
    _apply(switch (at) {
      InsertAfter(:final nodeId, :final sourceHandle) => handleNodeAdd(
        g.nodes,
        g.edges,
        nodeType: type,
        defaultValue: defaults,
        pluginDefaultValue: toolDefaultValue,
        prevNodeId: nodeId,
        prevNodeSourceHandle: difyHandle(sourceHandle),
        id: id,
      ),
      InsertBefore(:final nodeId, :final targetHandle) => handleNodeAdd(
        g.nodes,
        g.edges,
        nodeType: type,
        defaultValue: defaults,
        pluginDefaultValue: toolDefaultValue,
        nextNodeId: nodeId,
        nextNodeTargetHandle: difyHandle(targetHandle),
        id: id,
      ),
      InsertOnEdge(:final edgeId) => switch (doc.edges[edgeId]) {
        final e? => handleNodeAdd(
          g.nodes,
          g.edges,
          nodeType: type,
          defaultValue: defaults,
          pluginDefaultValue: toolDefaultValue,
          prevNodeId: e.source,
          prevNodeSourceHandle: difyHandle(e.sourceHandle),
          nextNodeId: e.target,
          nextNodeTargetHandle: difyHandle(e.targetHandle),
          id: id,
        ),
        null => null,
      },
    });
  }

  /// handleNodeChange: node [nodeId] replaced by a [type] node (a new id: a document node cannot change its type),
  /// keeping its place and the connections Dify keeps ([sourceHandle]: the handle it was reached from).
  void changeNode(String nodeId, String type, DifyJson? defaults, String sourceHandle, {DifyJson? toolDefaultValue}) {
    if (nodesReadOnly) return;
    final g = _graph;
    _apply(
      handleNodeChange(
        g.nodes,
        g.edges,
        currentNodeId: nodeId,
        nodeType: type,
        sourceHandle: difyHandle(sourceHandle),
        defaultValue: defaults,
        pluginDefaultValue: toolDefaultValue,
        id: newId('n'),
      ),
    );
  }

  /// `data.isInIteration || data.isInLoop`.
  bool _inContainer(Node n) => jsTruthy(plainOf(n.config['isInIteration'])) || jsTruthy(plainOf(n.config['isInLoop']));

  /// useAvailableBlocks(getNodeCatalogType(data), inContainer) for [node], over the app's blocks.
  ({List<String> prev, List<String> next}) availableBlocksOf(Node node, BlockSelectorData data) => useAvailableBlocks(
    getNodeCatalogType(difyDataOf(node)),
    availableTypes: availableNodeTypes(chatMode: data.chatMode, agentV2: data.agentV2),
    inContainer: _inContainer(node),
  );

  /// The block selector to insert at [at], anchored at [anchor] (or [context]'s box), with the blocks Dify offers
  /// there: a source handle's next blocks (with the Start tab), a target handle's previous blocks (with the Start
  /// tab), an edge's blocks that may follow its source and precede its target. [placement] defaults to the handle's
  /// or edge's; the next-step section passes [BlockSelectorPlacements.nextStep] and its 328 px width.
  Future<void> showInsertBlockSelector(
    BuildContext context,
    InsertPoint at, {
    Rect? anchor,
    ({DifyPlacement placement, double sideOffset, double alignOffset})? placement,
    double popupWidth = 400,
    bool? showStartTab,
  }) async {
    if (nodesReadOnly) return;
    final data = BlockSelectorScope.of(context);
    final List<String> types;
    final bool startTab;
    var p = placement;
    switch (at) {
      case InsertAfter(:final nodeId):
        final n = doc.nodes[nodeId];
        if (n == null) return;
        types = availableBlocksOf(n, data).next;
        startTab = true;
        p ??= BlockSelectorPlacements.sourceHandle;
      case InsertBefore(:final nodeId):
        final n = doc.nodes[nodeId];
        if (n == null) return;
        types = availableBlocksOf(n, data).prev;
        startTab = true;
        p ??= BlockSelectorPlacements.targetHandle;
      case InsertOnEdge(:final edgeId):
        final e = doc.edges[edgeId];
        final s = e == null ? null : doc.nodes[e.source], t = e == null ? null : doc.nodes[e.target];
        if (s == null || t == null) return;
        // custom-edge.tsx: both ends' blocks under the edge's container (the target's flags, as edge data has).
        final inContainer = _inContainer(t);
        final all = availableNodeTypes(chatMode: data.chatMode, agentV2: data.agentV2);
        final prev = useAvailableBlocks(t.type, availableTypes: all, inContainer: inContainer).prev;
        final next = useAvailableBlocks(s.type, availableTypes: all, inContainer: inContainer).next;
        types = [
          for (final b in prev)
            if (next.contains(b)) b,
        ];
        startTab = false;
        p ??= BlockSelectorPlacements.sourceHandle;
    }
    await BlockSelector(
      placement: p.placement,
      sideOffset: p.sideOffset,
      alignOffset: p.alignOffset,
      popupWidth: popupWidth,
      availableBlocksTypes: types,
      showStartTab: (showStartTab ?? startTab) && !data.chatMode && data.flow == BlockSelectorFlow.app,
      onSelect: (type, defaults, {toolDefaultValue}) =>
          addNodeAt(at, type, defaults, toolDefaultValue: toolDefaultValue),
    ).show(context, anchor: anchor);
  }

  /// next-step/operator.tsx ChangeItem: the block selector replacing node [nodeId] (reached from [sourceHandle]) by
  /// one of the blocks that may both precede and follow it, other than its own.
  Future<void> showChangeBlockSelector(BuildContext context, String nodeId, String sourceHandle, {Rect? anchor}) async {
    if (nodesReadOnly) return;
    final n = doc.nodes[nodeId];
    if (n == null) return;
    final data = BlockSelectorScope.of(context);
    final blocks = availableBlocksOf(n, data);
    final own = getNodeCatalogType(difyDataOf(n));
    const p = BlockSelectorPlacements.nextStepChange;
    await BlockSelector(
      placement: p.placement,
      sideOffset: p.sideOffset,
      alignOffset: p.alignOffset,
      popupWidth: 328,
      availableBlocksTypes: [
        for (final b in blocks.prev)
          if (blocks.next.contains(b) && b != own) b,
      ],
      onSelect: (type, defaults, {toolDefaultValue}) =>
          changeNode(nodeId, type, defaults, sourceHandle, toolDefaultValue: toolDefaultValue),
    ).show(context, anchor: anchor);
  }
}
