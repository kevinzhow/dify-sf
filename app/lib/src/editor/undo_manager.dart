import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

/// Dify's history events (hooks/use-workflow-history.ts WorkflowHistoryEvent): what an undo step is called.
enum HistoryEvent {
  nodeTitleChange,
  nodeDescriptionChange,
  nodeDragStop,
  nodeChange,
  nodeConnect,
  nodePaste,
  nodeDelete,
  edgeDelete,
  edgeDeleteByDeleteBranch,
  edgeSourceHandleChange,
  nodeAdd,
  nodeResize,
  noteAdd,
  noteChange,
  noteDelete,
  layoutOrganize,
}

/// One undo step: the ops that undo a user action, and what it was.
class HistoryStep {
  HistoryStep(this.event, {this.nodeId, this.nodeTitle, this.nodeType});
  final HistoryEvent event;
  final String? nodeId;
  final String? nodeTitle;
  final String? nodeType;

  /// When the step was last added to (typing coalesces into one step).
  DateTime at = DateTime.now();

  /// The ops that revert the action, in the order to submit them.
  final List<Op> inverse = [];
}

/// Undo and redo of this client's own edits in a shared document (Yjs's UndoManager approach): each user action is
/// recorded with the ops that revert it, computed from the document just before; undoing submits those as new ops,
/// so other people's edits stay. What Dify's history records is recorded here (structural edits: nodes, edges,
/// titles, descriptions, moves); field edits in panels are not, as in Dify.
///
/// A node delete is reverted by restoring the node ([restoreNode], protocol 1.6); steps whose nodes others deleted
/// in the meantime are skipped op by op.
class UndoManager extends ChangeNotifier {
  UndoManager({required this.doc, required this.submit, required this.newId, this.restoreNode, this.limit = 50});

  /// The document as this client sees it now.
  final Document Function() doc;

  /// Sends an op (applied locally first).
  final void Function(Op op) submit;

  /// A fresh id with a prefix (edges and items re-created by an undo get new ids; nothing refers to them).
  final String Function(String prefix) newId;

  /// The op that brings back a deleted node with its edges, or null when the protocol has none.
  final Op Function(Node node, List<Edge> edges)? restoreNode;

  /// Steps kept (older ones are dropped).
  final int limit;

  /// Edits of one field this close together are one step.
  static const mergeWindow = Duration(milliseconds: 1500);

  final _past = <HistoryStep>[], _future = <HistoryStep>[];
  HistoryStep? _open;
  bool _replaying = false;

  List<HistoryStep> get past => List.unmodifiable(_past);
  List<HistoryStep> get future => List.unmodifiable(_future);
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// Starts a step; the ops recorded until [end] belong to it. The step names [nodeId]'s title and type, or
  /// [nodeTitle] and [nodeType] for a node the step is about to add.
  void begin(HistoryEvent event, {String? nodeId, String? nodeTitle, String? nodeType}) {
    end();
    final n = nodeId == null ? null : doc().nodes[nodeId];
    _open = HistoryStep(event, nodeId: nodeId, nodeTitle: n?.title ?? nodeTitle, nodeType: n?.type ?? nodeType);
  }

  /// Closes the step started by [begin] (an empty one is dropped).
  void end() {
    final s = _open;
    _open = null;
    if (s == null || s.inverse.isEmpty) return;
    _push(_past, s);
    _future.clear();
    notifyListeners();
  }

  /// Records [op] (about to be submitted by this client) in the open step, or as a step of its own when [event] is
  /// given. Edits outside a step and without an event are not undoable, and neither are writes of `$app`.
  void record(Op op, {HistoryEvent? event}) {
    if (_replaying) return;
    // Writes of the document-level registers (environment / conversation variables, features: protocol 1.7) are
    // not workflow history in Dify (its env and chat-variable panels save outside it), so they are never undoable.
    if (op.touchesApp) return;
    // Typing a title or description is one step: edits of the same field follow each other closely.
    final last = _past.lastOrNull;
    if (_open == null &&
        event != null &&
        last != null &&
        _future.isEmpty &&
        last.event == event &&
        last.nodeId == op.nodeId &&
        op is SetField &&
        DateTime.now().difference(last.at) < mergeWindow) {
      last.at = DateTime.now();
      return; // the step already holds the value to go back to
    }
    final own = _open == null && event != null;
    if (own) begin(event, nodeId: op.nodeId);
    final s = _open;
    if (s == null) return;
    final inv = _inverse(op, doc());
    if (inv != null) {
      // A drag sends many moves: the first one's inverse is the position to go back to.
      final dupMove = op is MoveNode && s.inverse.any((i) => i is MoveNode && i.node == op.node);
      if (!dupMove) s.inverse.insertAll(0, inv);
    }
    if (own) end();
  }

  void undo() => _replay(_past, _future);
  void redo() => _replay(_future, _past);

  void clear() {
    _past.clear();
    _future.clear();
    _open = null;
    notifyListeners();
  }

  void _replay(List<HistoryStep> from, List<HistoryStep> to) {
    end();
    if (from.isEmpty) return;
    final step = from.removeLast();
    final back = HistoryStep(step.event, nodeId: step.nodeId, nodeTitle: step.nodeTitle, nodeType: step.nodeType);
    _replaying = true;
    try {
      for (final op in step.inverse) {
        final d = doc();
        if (!_applies(op, d)) continue;
        final inv = _inverse(op, d);
        if (inv != null) back.inverse.insertAll(0, inv);
        submit(op);
      }
    } finally {
      _replaying = false;
    }
    if (back.inverse.isNotEmpty) _push(to, back);
    notifyListeners();
  }

  void _push(List<HistoryStep> list, HistoryStep s) {
    list.add(s);
    if (list.length > limit) list.removeAt(0);
  }

  /// Whether [op] still makes sense: the nodes and edges it needs exist (a node restore needs its node gone).
  bool _applies(Op op, Document d) => switch (op) {
    AddNode(:final node) => !d.nodes.containsKey(node.id) && !d.deletedNodes.containsKey(node.id),
    RestoreNode(:final node) => !d.nodes.containsKey(node.id) && d.deletedNodes.containsKey(node.id),
    AddEdge(:final edge) => d.nodes.containsKey(edge.source) && d.nodes.containsKey(edge.target),
    RemoveEdge(:final edge) => d.edges.containsKey(edge),
    MoveNode() || SetField() || RemoveNode() || InsertItem() || RemoveItem() || UpdateItem() => d.nodes.containsKey(
      op.nodeId,
    ),
  };

  /// The ops that revert [op], applied to [d]; null when it changes nothing that can be reverted.
  List<Op>? _inverse(Op op, Document d) {
    switch (op) {
      case MoveNode(:final node):
        final n = d.nodes[node];
        return n == null ? null : [MoveNode(node, n.x, n.y)];
      case SetField(:final node, :final field, :final value):
        final n = d.nodes[node];
        if (n == null) return null;
        final old = switch (field) {
          TitleKey() => VString(n.title),
          ConfigKey(:final path) => ConfigTree.get(n.config, path) ?? const VNull(),
          _ => null,
        };
        return old == null || old == value ? null : [SetField(node, field, old)];
      case AddNode(:final node) || RestoreNode(:final node):
        return [RemoveNode(node.id)];
      case RemoveNode(:final node):
        final n = d.nodes[node];
        final restore = restoreNode;
        if (n == null || restore == null) return null;
        final edges = [
          for (final e in d.edges.values)
            if (e.source == node || e.target == node) e,
        ];
        return [restore(n, edges)];
      case AddEdge(:final edge):
        return [RemoveEdge(edge.id)];
      case RemoveEdge(:final edge):
        final e = d.edges[edge];
        if (e == null) return null;
        return [
          AddEdge(
            Edge(
              id: newId('e'),
              source: e.source,
              sourceHandle: e.sourceHandle,
              target: e.target,
              targetHandle: e.targetHandle,
            ),
          ),
        ];
      case InsertItem(:final node, :final path, :final item):
        return [RemoveItem(node, path, item.id)];
      case RemoveItem(:final node, :final path, :final itemId):
        final list = d.nodes[node] == null ? null : ConfigTree.get(d.nodes[node]!.config, path);
        if (list is! VItems) return null;
        final at = list.items.indexWhere((i) => i.id == itemId);
        if (at < 0) return null;
        return [InsertItem(node, path, Item(newId('i'), list.items[at].value), at == 0 ? null : list.items[at - 1].id)];
      case UpdateItem(:final node, :final path, :final itemId):
        final list = d.nodes[node] == null ? null : ConfigTree.get(d.nodes[node]!.config, path);
        if (list is! VItems) return null;
        final item = list.items.where((i) => i.id == itemId).firstOrNull;
        return item == null ? null : [UpdateItem(node, path, itemId, item.value)];
    }
  }
}
