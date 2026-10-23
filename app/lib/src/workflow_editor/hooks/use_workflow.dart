/// hooks/use-workflow.ts over the document: `isValidConnection` (with the checks of use-nodes-interactions.ts
/// `handleNodeConnect`) and `useIsNodeInIteration` / `useIsNodeInLoop`. The read-only states are the store's
/// (`nodesReadOnlyOf`, `OperatorReadOnly`).
library;

import 'package:collab_client/collab_client.dart';

import '../../workflow/dify_json.dart';
import '../block_selector/block_defaults.dart' show availableNodeTypes, getAvailableBlocks;
import '../context_menu/clipboard.dart' show isNoteNode;
import '../context_menu/workflow_actions.dart' show parentIdOf;

/// `getNodeCatalogType` (utils/node.ts): `agent-v2` for an Agent v2 node's data (an `agent` node of kind
/// `dify_agent`, version 2), else the node's type.
String getNodeCatalogType(Node n) {
  String? field(String key) => jsStr(plainOf(n.config[key]));
  final isAgentV2 =
      (n.type == 'agent' || n.type == 'agent-v2') &&
      field('agent_node_kind') == 'dify_agent' &&
      field('version') == '2';
  return isAgentV2 ? 'agent-v2' : n.type;
}

/// The document's own handle ids (`out` / `in`) are Dify's `source` / `target`.
String _sourceHandle(String h) => h == 'out' ? 'source' : h;
String _targetHandle(String h) => h == 'in' ? 'target' : h;

/// `useWorkflow().isValidConnection`: [source] may connect to [target] when neither is a note, both are in the same
/// container (or none), each type accepts the other ([getAvailableBlocks] of the app's blocks: [chatMode],
/// [agentV2]), and the new edge closes no cycle. A type the app does not offer at all is not restricted: Dify's
/// documents have none, dify-sf's own templates do (an Answer node in a workflow).
bool isValidConnection(
  Document doc, {
  required String source,
  required String target,
  String sourceHandle = 'source',
  bool chatMode = false,
  bool agentV2 = false,
}) {
  final s = doc.nodes[source], t = doc.nodes[target];
  if (s == null || t == null) return false;
  if (isNoteNode(s) || isNoteNode(t)) return false;
  if (parentIdOf(s) != parentIdOf(t)) return false;
  final types = availableNodeTypes(chatMode: chatMode, agentV2: agentV2);
  final sourceType = getNodeCatalogType(s), targetType = getNodeCatalogType(t);
  final next = getAvailableBlocks(sourceType, availableTypes: types, inContainer: parentIdOf(s) != null).next;
  final prev = getAvailableBlocks(targetType, availableTypes: types, inContainer: parentIdOf(t) != null).prev;
  final known = types.contains(sourceType) && types.contains(targetType);
  if (known && (!next.contains(targetType) || !prev.contains(sourceType))) return false;
  // `hasCycle(targetNode)`: some path from the target leads back to the source.
  final outgoers = <String, List<String>>{};
  for (final e in doc.edges.values) {
    (outgoers[e.source] ??= []).add(e.target);
  }
  final visited = <String>{};
  bool hasCycle(String id) {
    if (!visited.add(id)) return false;
    for (final o in outgoers[id] ?? const <String>[]) {
      if (o == source || hasCycle(o)) return true;
    }
    return false;
  }

  return !hasCycle(target);
}

/// `handleNodeConnect`'s early returns: the same node, nodes in different containers, a note, or an edge that
/// already joins these handles.
bool canConnect(Document doc, {required String source, required String target, String sourceHandle = 'source'}) {
  if (source == target) return false;
  final s = doc.nodes[source], t = doc.nodes[target];
  if (s == null || t == null) return false;
  if (parentIdOf(s) != parentIdOf(t)) return false;
  if (isNoteNode(s) || isNoteNode(t)) return false;
  return !doc.edges.values.any(
    (e) =>
        e.source == source &&
        _sourceHandle(e.sourceHandle) == _sourceHandle(sourceHandle) &&
        e.target == target &&
        _targetHandle(e.targetHandle) == 'target',
  );
}

/// `useIsNodeInIteration(iterationId).isNodeInIteration` / `useIsNodeInLoop(loopId).isNodeInLoop`: [nodeId] is a
/// direct child of [containerId].
bool isNodeInContainer(Document doc, String containerId, String nodeId) {
  final n = doc.nodes[nodeId];
  return n != null && parentIdOf(n) == containerId;
}
