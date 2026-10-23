/// Dify's node insertion and replacement (hooks/use-nodes-interactions.ts `handleNodeAdd` / `handleNodeChange`, with
/// hooks/use-workflow.ts `getAfterNodesInSameBranch` and the helpers of utils/node.ts and utils/workflow.ts) as pure
/// functions over React Flow's JSON: the current nodes and edges in, the [GraphChange] Dify's `setNodes` /
/// `setEdges` make out.
///
/// Nodes are Dify's (`{id, type, position, width, height, parentId, zIndex, data}`), edges too (`{id, source,
/// sourceHandle, target, targetHandle, data}`). Runtime flags Dify keeps on nodes (`_connectedSourceHandleIds`,
/// `selected`, `_children`, `_isShowTips`, the variable-assigner popup) are not part of a [GraphChange] beyond what
/// the new nodes carry: the document does not store them.
library;

import '../../editor/undo_manager.dart' show HistoryEvent;
import '../block_selector/block_defaults.dart';
import '../node_panel/bodies/llm/llm_bodies.dart' show isAgentV2NodeData;
import '../store/workflow_store.dart' show DifyJson;

// ---- constants.ts ------------------------------------------------------------------------------------------------

const nodeWidth = 240.0;
const xOffset = 60.0;
const nodeWidthXOffset = nodeWidth + xOffset;
const yOffset = 39.0;

// ---- the result --------------------------------------------------------------------------------------------------

/// What one `handleNodeAdd` / `handleNodeChange` does to the graph, for the app to apply as one undo step.
class GraphChange {
  const GraphChange({
    required this.event,
    required this.nodeId,
    this.addNodes = const [],
    this.addEdges = const [],
    this.moveNodes = const {},
    this.updateData = const {},
    this.removeEdges = const [],
    this.removeNodes = const [],
    this.selectNodeId,
  });

  /// The history step (`NodeAdd`, `NodeChange`) and the node it names (`saveStateToHistory(event, {nodeId})`).
  final HistoryEvent event;
  final String nodeId;

  /// New nodes (an iteration's or loop's start node after its container) and edges, as Dify's JSON.
  final List<DifyJson> addNodes;
  final List<DifyJson> addEdges;

  /// Existing nodes' new positions (the nodes after an insertion point move right).
  final Map<String, ({double x, double y})> moveNodes;

  /// Existing nodes' changed `data` keys (a container whose `start_node_id` was the node inserted before).
  final Map<String, DifyJson> updateData;

  final List<String> removeEdges;
  final List<String> removeNodes;

  /// The node selected afterwards, all others deselected; null: none selected.
  final String? selectNodeId;

  /// The node to add (the first of [addNodes]).
  DifyJson? get newNode => addNodes.firstOrNull;
}

// ---- utils/node.ts -----------------------------------------------------------------------------------------------

/// getNodeCatalogType: the block an Agent v2 node (an `agent` node with Agent v2's discriminator) was picked as.
String getNodeCatalogType(DifyJson data) => isAgentV2NodeData(data) ? 'agent-v2' : '${data['type']}';

/// getNodeCustomTypeByNodeDataType: `custom-simple` for a loop end, else none (generateNewNode's `custom`).
String? getNodeCustomTypeByNodeDataType(String type) => type == 'loop-end' ? 'custom-simple' : null;

/// getTopLeftNodePosition.
({double x, double y}) getTopLeftNodePosition(Iterable<DifyJson> nodes) {
  var x = double.infinity, y = double.infinity;
  for (final n in nodes) {
    final p = _position(n);
    if (p.x < x) x = p.x;
    if (p.y < y) y = p.y;
  }
  return (x: x, y: y);
}

/// getNestedNodePosition: [node]'s position relative to [parent].
({double x, double y}) getNestedNodePosition(DifyJson node, DifyJson parent) {
  final p = _position(node), q = _position(parent);
  return (x: p.x - q.x, y: p.y - q.y);
}

// ---- utils/workflow.ts -------------------------------------------------------------------------------------------

/// getNodesConnectedSourceOrTargetHandleIdsMap: for the nodes at either end of [changes] (`(type: 'add' | 'remove',
/// edge)`), their `_connectedSourceHandleIds` / `_connectedTargetHandleIds` after the changes.
Map<String, ({List<String> source, List<String> target})> getNodesConnectedSourceOrTargetHandleIdsMap(
  List<({String type, DifyJson edge})> changes,
  List<DifyJson> nodes,
) {
  final map = <String, ({List<String> source, List<String> target})>{};
  List<String> ids(DifyJson n, String key) => [for (final h in (_data(n)[key] as List?) ?? const []) '$h'];
  ({List<String> source, List<String> target}) entry(DifyJson n) => map[n['id']! as String] ??= (
    source: ids(n, '_connectedSourceHandleIds'),
    target: ids(n, '_connectedTargetHandleIds'),
  );
  // `splice(findIndex(...), 1)`: a handle that is not there takes the last one with it (index -1).
  void remove(List<String> list, Object? handle) {
    final i = list.indexOf('$handle');
    if (i >= 0) {
      list.removeAt(i);
    } else if (list.isNotEmpty) {
      list.removeLast();
    }
  }

  for (final (:type, :edge) in changes) {
    final source = _find(nodes, edge['source']), target = _find(nodes, edge['target']);
    if (source != null) entry(source);
    if (target != null) entry(target);
    if (source != null) {
      final list = entry(source).source;
      if (type == 'remove') remove(list, edge['sourceHandle']);
      if (type == 'add') list.add(_handle(edge['sourceHandle'], 'source'));
    }
    if (target != null) {
      final list = entry(target).target;
      if (type == 'remove') remove(list, edge['targetHandle']);
      if (type == 'add') list.add(_handle(edge['targetHandle'], 'target'));
    }
  }
  return map;
}

// ---- hooks/use-workflow.ts ---------------------------------------------------------------------------------------

/// getAfterNodesInSameBranch: [nodeId]'s node and every node downstream of it (each once).
List<DifyJson> getAfterNodesInSameBranch(String nodeId, List<DifyJson> nodes, List<DifyJson> edges) {
  final current = _find(nodes, nodeId);
  if (current == null) return const [];
  final seen = {nodeId};
  final list = [current];
  void traverse(DifyJson root) {
    for (final n in _outgoers(root, nodes, edges)) {
      if (!seen.add(n['id']! as String)) continue;
      list.add(n);
      traverse(n);
    }
  }

  traverse(current);
  return list;
}

// ---- handleNodeAdd -----------------------------------------------------------------------------------------------

const _noNextEdgeAfter = {'if-else', 'question-classifier', 'human-input', 'loop-end'};
const _branchingSources = {'if-else', 'question-classifier', 'human-input'};

/// handleNodeAdd: a new [nodeType] node, its data [defaultValue] (`nodesMetaDataMap[nodeType].defaultValue`, see
/// [blockDefaults]; null: the type is unknown and nothing happens) with its title numbered after the nodes of the
/// same type ("LLM 2") and [pluginDefaultValue] (a tool's, trigger's or data source's fields) over it, inserted
///
/// * after [prevNodeId]'s [prevNodeSourceHandle] (no [nextNodeId]): below its lowest outgoer, or [xOffset] right of
///   it when it has none;
/// * before [nextNodeId]'s [nextNodeTargetHandle] (no [prevNodeId]): at its place, it and its downstream moving
///   [nodeWidthXOffset] right; a container whose start node it was starts with the new node;
/// * between them, on their edge: at the next node's place, the downstream moving right, the edge replaced by two.
///
/// The new node takes the container (`parentId`, `isInIteration` / `isInLoop`, the nested z-index) of the node it
/// follows (or precedes); an iteration or loop comes with its start node. Edges are `custom`, with Dify's ids
/// (`source-sourceHandle-target-targetHandle`); a data source takes no incoming edge, a branching node (if-else,
/// question classifier, human input) and a loop end no outgoing one. [id] is the new node's (default `Date.now()`).
GraphChange? handleNodeAdd(
  List<DifyJson> nodes,
  List<DifyJson> edges, {
  required String nodeType,
  required DifyJson? defaultValue,
  DifyJson? pluginDefaultValue,
  String sourceHandle = 'source',
  String targetHandle = 'target',
  String? prevNodeId,
  String? prevNodeSourceHandle,
  String? nextNodeId,
  String? nextNodeTargetHandle,
  String? id,
}) {
  if (defaultValue == null) return null;
  final generated = generateNewNode(
    id: id,
    type: getNodeCustomTypeByNodeDataType(nodeType),
    data: {
      ...newNodeData(nodeType, defaultValue, toolDefaultValue: pluginDefaultValue, existing: nodes.map(_data)),
      'selected': true,
      '_showAddVariablePopup':
          (nodeType == 'variable-assigner' || nodeType == 'variable-aggregator') && prevNodeId != null,
      '_holdAddVariablePopup': false,
    },
    position: (x: 0, y: 0),
  );
  final newNode = generated.node, newData = _data(newNode), newId = newNode['id']! as String;
  final prevHandle = prevNodeSourceHandle ?? 'source', nextHandle = nextNodeTargetHandle ?? 'target';
  final added = [newNode, ?generated.start];

  /// The new node in [parent]'s container (Dify sets the flags only when [parentId] is set).
  void nest(String? parentId, DifyJson? extent, DifyJson? parent) {
    if (parentId != null) newNode['parentId'] = parentId;
    if (extent != null) newNode['extent'] = extent;
    if (parentId == null || parent == null) return;
    final type = _data(parent)['type'];
    newData
      ..['isInIteration'] = type == 'iteration'
      ..['isInLoop'] = type == 'loop';
    if (type == 'iteration') newData['iteration_id'] = parent['id'];
    if (type == 'loop') newData['loop_id'] = parent['id'];
    if (type == 'iteration' || type == 'loop') newNode['zIndex'] = nestedElementZIndex;
  }

  /// An edge from the add, laid out by [placedBy].
  DifyJson edge(DifyJson source, String sourceHandle, DifyJson target, String targetHandle, DifyJson placedBy) => _edge(
    source,
    sourceHandle,
    target,
    targetHandle,
    placedBy: placedBy,
    container: _parentOf(placedBy, nodes),
    selected: true,
  );

  Map<String, ({double x, double y})> shiftAfter(String nextId) => {
    for (final n in getAfterNodesInSameBranch(nextId, nodes, edges))
      n['id']! as String: (x: _position(n).x + nodeWidthXOffset, y: _position(n).y),
  };

  final prev = prevNodeId == null ? null : _find(nodes, prevNodeId);
  final next = nextNodeId == null ? null : _find(nodes, nextNodeId);
  if (prevNodeId != null && nextNodeId == null) {
    if (prev == null) return null;
    final outgoers = _stableSortedByY(_outgoers(prev, nodes, edges));
    final last = outgoers.lastOrNull;
    newData
      ..['_connectedTargetHandleIds'] = nodeType == 'datasource' ? <String>[] : [targetHandle]
      ..['_connectedSourceHandleIds'] = <String>[];
    final p = _position(prev);
    newNode['position'] = last == null
        ? {'x': p.x + _width(prev) + xOffset, 'y': p.y}
        : {'x': _position(last).x, 'y': _position(last).y + _height(last) + yOffset};
    final parent = _parentOf(prev, nodes);
    nest(prev['parentId'] as String?, prev['extent'] as DifyJson?, parent);
    return GraphChange(
      event: HistoryEvent.nodeAdd,
      nodeId: newId,
      addNodes: added,
      addEdges: [if (nodeType != 'datasource') edge(prev, prevHandle, newNode, targetHandle, prev)],
      selectNodeId: newId,
    );
  }
  if (prevNodeId == null && nextNodeId != null) {
    if (next == null) return null;
    if (!_branchingSources.contains(nodeType)) newData['_connectedSourceHandleIds'] = [sourceHandle];
    newData['_connectedTargetHandleIds'] = <String>[];
    newNode['position'] = {'x': _position(next).x, 'y': _position(next).y};
    final parent = _parentOf(next, nodes);
    nest(next['parentId'] as String?, next['extent'] as DifyJson?, parent);
    return GraphChange(
      event: HistoryEvent.nodeAdd,
      nodeId: newId,
      addNodes: added,
      addEdges: [if (!_noNextEdgeAfter.contains(nodeType)) edge(newNode, sourceHandle, next, nextHandle, next)],
      moveNodes: shiftAfter(nextNodeId),
      updateData: {
        for (final n in nodes)
          if (const {'iteration', 'loop'}.contains(_data(n)['type']) && _data(n)['start_node_id'] == nextNodeId)
            n['id']! as String: {'start_node_id': newId, 'startNodeType': newData['type']},
      },
      selectNodeId: newId,
    );
  }
  if (prevNodeId != null && nextNodeId != null) {
    if (prev == null || next == null) return null;
    newData
      ..['_connectedTargetHandleIds'] = nodeType == 'datasource' ? <String>[] : [targetHandle]
      ..['_connectedSourceHandleIds'] = [sourceHandle];
    newNode['position'] = {'x': _position(next).x, 'y': _position(next).y};
    final parent = _parentOf(prev, nodes);
    nest(prev['parentId'] as String?, prev['extent'] as DifyJson?, parent);
    final current = edges.where((e) => e['source'] == prevNodeId && e['target'] == nextNodeId).firstOrNull;
    return GraphChange(
      event: HistoryEvent.nodeAdd,
      nodeId: newId,
      addNodes: added,
      addEdges: [
        if (nodeType != 'datasource') edge(prev, prevHandle, newNode, targetHandle, prev),
        if (!_noNextEdgeAfter.contains(nodeType)) edge(newNode, sourceHandle, next, nextHandle, next),
      ],
      moveNodes: shiftAfter(nextNodeId),
      removeEdges: [?current?['id'] as String?],
      selectNodeId: newId,
    );
  }
  return null;
}

// ---- handleNodeChange --------------------------------------------------------------------------------------------

/// handleNodeChange: node [currentNodeId] replaced by a new [nodeType] node (a new id, [id] or `Date.now()`, as
/// Dify's generateNewNode gives it) at its place, in its container, selected if it was (every other node
/// deselected). Its incoming edges now end at the new node; of its outgoing edges, those of one handle are kept
/// (from the new node's first branch, or `source`): [sourceHandle] when it has edges, else the node's first branch,
/// else `source`, else the first outgoing edge's. The others go with the old node. [defaultValue] and
/// [pluginDefaultValue] as in [handleNodeAdd]; null [defaultValue] changes nothing.
GraphChange? handleNodeChange(
  List<DifyJson> nodes,
  List<DifyJson> edges, {
  required String currentNodeId,
  required String nodeType,
  required String sourceHandle,
  required DifyJson? defaultValue,
  DifyJson? pluginDefaultValue,
  String? id,
}) {
  final current = _find(nodes, currentNodeId);
  if (current == null || defaultValue == null) return null;
  final currentData = _data(current);
  final connected = [
    for (final e in edges)
      if (e['source'] == currentNodeId || e['target'] == currentNodeId) e,
  ];
  final generated = generateNewNode(
    id: id,
    type: getNodeCustomTypeByNodeDataType(nodeType),
    data: {
      ...newNodeData(nodeType, defaultValue, toolDefaultValue: pluginDefaultValue, existing: nodes.map(_data)),
      '_connectedSourceHandleIds': <String>[],
      '_connectedTargetHandleIds': <String>[],
      for (final k in const ['selected', 'isInIteration', 'isInLoop', 'iteration_id', 'loop_id'])
        if (currentData[k] != null) k: currentData[k],
    },
    position: _position(current),
  );
  final newNode = generated.node, newData = _data(newNode), newId = newNode['id']! as String;
  for (final k in const ['parentId', 'extent']) {
    if (current[k] != null) newNode[k] = current[k];
  }
  if (!newNode.containsKey('zIndex') && current['zIndex'] != null) newNode['zIndex'] = current['zIndex'];

  final parent = _parentOf(current, nodes);
  final outgoing = [
    for (final e in connected)
      if (e['source'] == currentNodeId) e,
  ];
  final handles = {for (final e in outgoing) _handle(e['sourceHandle'], 'source')};
  final branch = _firstBranch(currentData);
  var keep = sourceHandle.isEmpty ? 'source' : sourceHandle;
  if (!handles.contains(keep)) {
    if (branch != null && handles.contains(branch)) {
      keep = branch;
    } else if (handles.contains('source')) {
      keep = 'source';
    } else {
      keep = _handle(outgoing.firstOrNull?['sourceHandle'], 'source');
    }
  }
  final kept = {
    for (final e in outgoing)
      if (_handle(e['sourceHandle'], 'source') == keep) e['id'],
  };
  final newSourceHandle = _firstBranch(newData) ?? 'source';
  final reconnected = <DifyJson>[];
  for (final e in connected) {
    if (kept.contains(e['id'])) {
      final original = _find(nodes, e['target']);
      final target = original != null && original['id'] != currentNodeId ? original : newNode;
      reconnected.add(
        _edge(
          newNode,
          newSourceHandle,
          target,
          _handle(e['targetHandle'], 'target'),
          placedBy: target,
          container: identical(target, newNode) ? parent : _parentOf(target, nodes),
          from: e,
        ),
      );
    }
    if (e['target'] == currentNodeId && e['source'] != currentNodeId && !kept.contains(e['id'])) {
      final source = _find(nodes, e['source']);
      if (source == null) continue;
      reconnected.add(
        _edge(
          source,
          _handle(e['sourceHandle'], 'source'),
          newNode,
          _handle(e['targetHandle'], 'target'),
          placedBy: newNode,
          container: parent,
          from: e,
        ),
      );
    }
  }
  return GraphChange(
    event: HistoryEvent.nodeChange,
    nodeId: currentNodeId,
    addNodes: [newNode, ?generated.start],
    addEdges: reconnected,
    removeEdges: [for (final e in connected) e['id']! as String],
    removeNodes: [currentNodeId],
    selectNodeId: currentData['selected'] == true ? newId : null,
  );
}

// ---- helpers -----------------------------------------------------------------------------------------------------

DifyJson _data(DifyJson n) => (n['data'] as Map?)?.cast<String, Object?>() ?? const {};

DifyJson? _find(List<DifyJson> nodes, Object? id) => nodes.where((n) => n['id'] == id).firstOrNull;

DifyJson? _parentOf(DifyJson n, List<DifyJson> nodes) => n['parentId'] == null ? null : _find(nodes, n['parentId']);

({double x, double y}) _position(DifyJson n) {
  final p = (n['position'] as Map?) ?? const {};
  return (x: (p['x'] as num? ?? 0).toDouble(), y: (p['y'] as num? ?? 0).toDouble());
}

/// React Flow's measured size; unmeasured: a card's width, no height.
double _width(DifyJson n) => (n['width'] as num? ?? nodeWidth).toDouble();
double _height(DifyJson n) => (n['height'] as num? ?? 0).toDouble();

/// `handle || fallback`.
String _handle(Object? handle, String fallback) => handle is String && handle.isNotEmpty ? handle : fallback;

/// `data._targetBranches?.[0]?.id`.
String? _firstBranch(DifyJson data) => switch (data['_targetBranches']) {
  [final Map b, ...] when b['id'] != null => '${b['id']}',
  _ => null,
};

/// React Flow's getOutgoers: the targets of [node]'s edges, in node order.
List<DifyJson> _outgoers(DifyJson node, List<DifyJson> nodes, List<DifyJson> edges) {
  final ids = {
    for (final e in edges)
      if (e['source'] == node['id']) e['target'],
  };
  return [
    for (final n in nodes)
      if (ids.contains(n['id'])) n,
  ];
}

/// JavaScript's (stable) sort by `position.y`.
List<DifyJson> _stableSortedByY(List<DifyJson> nodes) {
  final indexed = nodes.indexed.toList()
    ..sort((a, b) {
      final c = _position(a.$2).y.compareTo(_position(b.$2).y);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return [for (final (_, n) in indexed) n];
}

/// A `custom` edge from [source]'s [sourceHandle] to [target]'s [targetHandle], laid out by [placedBy] (the end
/// whose container it runs in: `isInIteration` / `isInLoop` from that node's parent [container], the nested
/// z-index when it has a parent); [from] is the edge it replaces (its other fields kept).
DifyJson _edge(
  DifyJson source,
  String sourceHandle,
  DifyJson target,
  String targetHandle, {
  required DifyJson placedBy,
  required DifyJson? container,
  DifyJson? from,
  bool selected = false,
}) {
  final type = container == null ? null : _data(container)['type'];
  final inIteration = type == 'iteration', inLoop = type == 'loop';
  final parentId = placedBy['parentId'];
  final data = <String, Object?>{
    ...?(from?['data'] as Map?)?.cast<String, Object?>(),
    'sourceType': _data(source)['type'],
    'targetType': _data(target)['type'],
    'isInIteration': inIteration,
    'isInLoop': inLoop,
    'iteration_id': inIteration ? parentId : null,
    'loop_id': inLoop ? parentId : null,
    '_connectedNodeIsSelected': selected,
  }..removeWhere((k, v) => v == null && (k == 'iteration_id' || k == 'loop_id'));
  return {
    ...?from,
    'id': '${source['id']}-$sourceHandle-${target['id']}-$targetHandle',
    'type': 'custom',
    'source': source['id'],
    'sourceHandle': sourceHandle,
    'target': target['id'],
    'targetHandle': targetHandle,
    'data': data,
    'zIndex': parentId != null ? nestedElementZIndex : 0,
  };
}
