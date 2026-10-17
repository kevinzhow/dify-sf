import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import '../ids.dart';
import 'notices.dart';
import 'undo_manager.dart';

/// Everything the editor UI does to the document goes through here, and each action becomes a handful of
/// small ops (never a whole-object write). The controller owns the notices that tell the user what happened
/// to their edits.
class EditorController extends ChangeNotifier {
  EditorController({required this.session, required this.docId, required this.journaled, this.onRestart}) {
    _events = session.events.listen(_onEvent);
    _changes = session.changes.listen((_) => _onChanged());
    _rememberTitles();
    final recovered = session.pending.where((p) => p.op != null).length;
    if (recovered > 0) {
      _addNotice(
        Notice(
          id: _nextNoticeId++,
          kind: NoticeKind.info,
          message:
              'Recovered $recovered unsent edit${recovered == 1 ? '' : 's'} from your last session — sending '
              '${recovered == 1 ? 'it' : 'them'} now.',
        ),
      );
    }
  }

  final CollabSession session;
  final String docId;
  final bool journaled;

  /// Demo mode only: simulate a crash + restart.
  final VoidCallback? onRestart;

  late final StreamSubscription<ClientEvent> _events;
  late final StreamSubscription<void> _changes;

  final List<Notice> notices = [];
  int _nextNoticeId = 1;
  final Map<int, Notice> _byCseq = {};
  final Map<String, String> _titles = {};
  bool _disposed = false;

  String? selectedNodeId;
  String? selectedEdgeId;

  Document get doc => session.view;
  SessionStatus get status => session.status;
  bool get ready => session.hasState;

  Node? get selectedNode => selectedNodeId == null ? null : doc.nodes[selectedNodeId!];

  String titleOf(String nodeId) {
    final n = doc.nodes[nodeId];
    final t = n?.title.isNotEmpty == true ? n!.title : _titles[nodeId];
    return t == null || t.isEmpty ? nodeId : '“$t”';
  }

  /// The version the user is looking at right now; edits that take a while to make (typing) remember it.
  int get seenVersion => session.lastSeq;

  /// "The network is back" (user pressed the button, window regained focus): skip the backoff and reconnect.
  void reconnectNow() => session.networkAvailable();

  // ---- selection ---------------------------------------------------------------------------------

  void selectNode(String? id) {
    selectedNodeId = id;
    selectedEdgeId = null;
    notifyListeners();
  }

  void selectEdge(String? id) {
    selectedEdgeId = id;
    if (id != null) selectedNodeId = null;
    notifyListeners();
  }

  // ---- edits -------------------------------------------------------------------------------------

  /// Undo and redo of this client's own structural edits (Dify's history).
  late final undo = UndoManager(
    doc: () => doc,
    submit: (op) => session.edit(op),
    newId: newId,
    restoreNode: RestoreNode.new, // protocol 1.6
  );

  /// Submits [op], recorded for undo under [event] (or in the step the UI opened with `undo.begin`).
  void _edit(Op op, {HistoryEvent? event, int? base}) {
    undo.record(op, event: event);
    session.edit(op, base: base);
  }

  /// A `moveNode` op: layout is last-writer-wins, so it never conflicts.
  void moveNode(String id, int x, int y) => _edit(MoveNode(id, x, y));

  void setTitle(String nodeId, String title, {required int base}) {
    _edit(SetField(nodeId, const TitleKey(), VString(title)), event: HistoryEvent.nodeTitleChange, base: base);
  }

  void setConfig(String nodeId, List<String> path, Value value, {int? base}) {
    _edit(
      SetField(nodeId, ConfigKey(path), value),
      event: path.length == 1 && path.first == 'desc' ? HistoryEvent.nodeDescriptionChange : null,
      base: base,
    );
  }

  /// Inserts [value] as a new item after the item [after] (null: at the front); the new item's id ([id], else a
  /// fresh one: a Dify variable list keys its items by the variable's id).
  String insertItem(String nodeId, List<String> path, Value value, {String? after, String? id}) {
    id ??= newId('i');
    session.edit(InsertItem(nodeId, path, Item(id, value), after));
    return id;
  }

  void updateItem(String nodeId, List<String> path, String itemId, Value value, {int? base}) {
    session.edit(UpdateItem(nodeId, path, itemId, value), base: base);
  }

  void removeItem(String nodeId, List<String> path, String itemId) {
    session.edit(RemoveItem(nodeId, path, itemId));
  }

  String addNode(String type, {required int x, required int y}) {
    final id = newId('n');
    final title = switch (type) {
      'llm' => 'LLM',
      'code' => 'Code',
      'answer' => 'Answer',
      'start' => 'Start',
      _ => type,
    };
    _edit(
      AddNode(Node(id: id, type: type, title: title, x: x, y: y)),
      event: HistoryEvent.nodeAdd,
    );
    selectNode(id);
    return id;
  }

  /// Adds nodes built elsewhere (a block placed from the block selector, with an iteration's start node) as one undo
  /// step, and selects the first.
  void addNodes(List<Node> nodes, {HistoryEvent event = HistoryEvent.nodeAdd}) {
    if (nodes.isEmpty) return;
    undo.begin(event, nodeId: nodes.first.id);
    for (final n in nodes) {
      _edit(AddNode(n));
    }
    undo.end();
    selectNode(nodes.first.id);
  }

  /// Applies a graph edit (Dify's handleNodeAdd / handleNodeChange, built elsewhere) as one undo step [event] about
  /// [nodeId] ([nodeTitle] and [nodeType] when that node is one of [addNodes]): [addNodes] are added, [moveNodes]
  /// moved, [setFields] written, [removeEdges] removed, [addEdges] added, then [removeNodes] removed (their edges
  /// with them, so undo restores those as they were). There is no op that changes a node's type: a replacement is
  /// a removal and an addition. Selection is the caller's.
  void applyGraphChange({
    required HistoryEvent event,
    String? nodeId,
    String? nodeTitle,
    String? nodeType,
    List<Node> addNodes = const [],
    Map<String, ({int x, int y})> moveNodes = const {},
    List<({String node, List<String> path, Value value})> setFields = const [],
    List<String> removeEdges = const [],
    List<Edge> addEdges = const [],
    List<String> removeNodes = const [],
  }) {
    final gone = removeNodes.toSet();
    undo.begin(event, nodeId: nodeId, nodeTitle: nodeTitle, nodeType: nodeType);
    try {
      for (final n in addNodes) {
        _edit(AddNode(n));
      }
      for (final MapEntry(key: id, value: (:x, :y)) in moveNodes.entries) {
        final n = doc.nodes[id];
        if (n != null && (n.x != x || n.y != y)) _edit(MoveNode(id, x, y));
      }
      for (final f in setFields) {
        _edit(SetField(f.node, ConfigKey(f.path), f.value));
      }
      for (final id in removeEdges) {
        final e = doc.edges[id];
        if (e != null && !gone.contains(e.source) && !gone.contains(e.target)) _edit(RemoveEdge(id));
      }
      for (final e in addEdges) {
        _edit(AddEdge(e));
      }
      if (gone.isNotEmpty) _rememberTitles();
      for (final id in removeNodes) {
        _edit(RemoveNode(id));
      }
    } finally {
      undo.end();
    }
  }

  /// Connects [sourceHandle] of one node (a branch of an if-else, a class of a question classifier, ...) to another.
  void connect(String sourceId, String targetId, {String? sourceHandle}) {
    if (sourceId == targetId) return;
    _edit(
      event: HistoryEvent.nodeConnect,
      AddEdge(
        sourceHandle == null
            ? Edge(id: newId('e'), source: sourceId, target: targetId)
            : Edge(id: newId('e'), source: sourceId, sourceHandle: sourceHandle, target: targetId),
      ),
    );
  }

  void deleteEdge(String edgeId) {
    _edit(RemoveEdge(edgeId), event: HistoryEvent.edgeDelete);
    if (selectedEdgeId == edgeId) selectedEdgeId = null;
    notifyListeners();
  }

  /// Live references to [nodeId] from other nodes: what deleting it would break.
  List<({String node, FieldKey field, OutputRef ref, bool broken})> referencesTo(String nodeId) =>
      doc.referencesTo(nodeId).where((r) => !r.broken).toList();

  void deleteNode(String nodeId) {
    _rememberTitles();
    _edit(RemoveNode(nodeId), event: HistoryEvent.nodeDelete);
    if (selectedNodeId == nodeId) selectedNodeId = null;
    notifyListeners();
  }

  // ---- document-level registers (protocol 1.7) ---------------------------------------------------

  /// The document's environment variables, conversation variables (Dify JSON, in order) and features, as this client
  /// sees them now (local edits included). They live in the document under [Document.appNode] (`$app`) and are written
  /// with [insertItem] / [updateItem] / [removeItem] / [setConfig] on that node id. Like Dify, these edits are not
  /// part of the undo history.
  ({
    List<Map<String, Object?>> environmentVariables,
    List<Map<String, Object?>> conversationVariables,
    Map<String, Object?> features,
  })
  get appLists => (
    environmentVariables: AppRegisters.variables(doc, AppRegisters.environmentVariables),
    conversationVariables: AppRegisters.variables(doc, AppRegisters.conversationVariables),
    features: AppRegisters.featuresOf(doc),
  );

  /// Stores the plaintext of a secret environment variable on the server (`POST /v1/docs/{doc}/secrets`) and returns
  /// its reference and Dify's mask. Write the variable with `value` = [masked] and `secret_ref` = [ref]: the plaintext
  /// never enters the document, the log or anyone's view.
  Future<({String ref, String masked})> storeSecret(String value) => session.transport.storeSecret(value);

  // ---- notices -----------------------------------------------------------------------------------

  void reapply(Notice n) {
    final op = n.op;
    if (op == null) return;
    removeNotice(n);
    session.edit(op); // based on the latest version this time
  }

  void removeNotice(Notice n) {
    notices.remove(n);
    _byCseq.removeWhere((_, v) => v == n);
    notifyListeners();
  }

  void _addNotice(Notice n) {
    notices.add(n);
    if (n.cseq != null) _byCseq[n.cseq!] = n;
    while (notices.length > 6) {
      final old = notices.removeAt(0);
      _byCseq.removeWhere((_, v) => v == old);
    }
    notifyListeners();
  }

  void _onEvent(ClientEvent e) {
    switch (e) {
      case OpCommitted():
        break;
      case ConflictDetected(:final cseq, :final op, :final reason):
        final d = describeRefusal(op, reason, titleOf);
        _addNotice(
          Notice(
            id: _nextNoticeId++,
            kind: NoticeKind.conflict,
            message: d.message,
            detail: d.detail,
            op: op,
            reason: reason,
            cseq: cseq,
            awaitingVerdict: true,
          ),
        );
      case OpRejected(:final cseq, :final op, :final reason):
        final d = describeRefusal(op, reason, titleOf);
        final existing = _byCseq[cseq];
        if (existing != null) {
          existing.update(message: d.message, detail: d.detail, awaitingVerdict: false);
        } else {
          _addNotice(
            Notice(
              id: _nextNoticeId++,
              kind: reason is Conflict ? NoticeKind.conflict : NoticeKind.refused,
              message: d.message,
              detail: d.detail,
              op: op,
              reason: reason,
              cseq: cseq,
            ),
          );
        }
      case OpLost():
        _noteLost();
      case ClientIdReplaced(:final renumbered):
        // Notices that refer to ops by cseq follow them to their new numbers.
        final moved = <int, Notice>{};
        for (final MapEntry(key: old, value: now) in renumbered.entries) {
          final n = _byCseq[old];
          if (n != null) moved[now] = n;
        }
        _byCseq
          ..clear()
          ..addAll(moved);
        _addNotice(
          Notice(
            id: _nextNoticeId++,
            kind: NoticeKind.info,
            message:
                'Another window was using this session\'s id, so this window switched to a new one'
                '${renumbered.isEmpty ? '.' : ' and re-sent your ${renumbered.length} unsaved edit${renumbered.length == 1 ? '' : 's'}.'}',
            detail: 'Each unsaved edit was sent again as a new edit, with the version it was made on.',
          ),
        );
      case LocalInvalid(:final op, :final reason):
        // A stale edit refused on the spot (it began before a newer remote write) or an edit of something
        // that is gone: say so, and keep the op for "re-apply" when that makes sense.
        final d = describeRefusal(op, reason, titleOf);
        _addNotice(
          Notice(
            id: _nextNoticeId++,
            kind: reason is Conflict ? NoticeKind.conflict : NoticeKind.refused,
            message: d.message,
            detail: d.detail,
            op: op,
            reason: reason,
          ),
        );
    }
  }

  void _noteLost() {
    final recent = notices.where((n) => n.kind == NoticeKind.lost && DateTime.now().difference(n.at).inSeconds < 10);
    final Notice n;
    if (recent.isNotEmpty) {
      n = recent.first;
    } else {
      n = Notice(id: _nextNoticeId++, kind: NoticeKind.lost, message: '');
      _addNotice(n);
    }
    n.lostCount++;
    n.update(
      message:
          '${n.lostCount} edit${n.lostCount == 1 ? ' was' : 's were'} lost — they had not reached the server '
          'when the app closed.',
      detail: journaled
          ? null
          : 'This session runs without a local journal (volatile mode), so unsent edits cannot be recovered. '
                'Switch to journaled mode to keep them across crashes.',
    );
    notifyListeners();
  }

  // ---- plumbing ----------------------------------------------------------------------------------

  void _rememberTitles() {
    for (final n in doc.nodes.values) {
      _titles[n.id] = n.title;
    }
  }

  void _onChanged() {
    if (_disposed) return;
    _rememberTitles();
    if (selectedNodeId != null && !doc.nodes.containsKey(selectedNodeId)) selectedNodeId = null;
    if (selectedEdgeId != null && !doc.edges.containsKey(selectedEdgeId)) selectedEdgeId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    undo.dispose();
    unawaited(_events.cancel());
    unawaited(_changes.cancel());
    super.dispose();
  }
}
