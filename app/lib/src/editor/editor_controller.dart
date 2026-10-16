import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import '../ids.dart';
import 'notices.dart';

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
      _addNotice(Notice(
        id: _nextNoticeId++,
        kind: NoticeKind.info,
        message: 'Recovered $recovered unsent edit${recovered == 1 ? '' : 's'} from your last session — sending '
            '${recovered == 1 ? 'it' : 'them'} now.',
      ));
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

  /// A `moveNode` op: layout is last-writer-wins, so it never conflicts.
  void moveNode(String id, int x, int y) => session.edit(MoveNode(id, x, y));

  void setTitle(String nodeId, String title, {required int base}) {
    session.edit(SetField(nodeId, const TitleKey(), VString(title)), base: base);
  }

  void setConfig(String nodeId, List<String> path, Value value, {int? base}) {
    session.edit(SetField(nodeId, ConfigKey(path), value), base: base);
  }

  void insertItem(String nodeId, List<String> path, Value value, {String? after}) {
    session.edit(InsertItem(nodeId, path, Item(newId('i'), value), after));
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
    session.edit(AddNode(Node(id: id, type: type, title: title, x: x, y: y)));
    selectNode(id);
    return id;
  }

  void connect(String sourceId, String targetId) {
    if (sourceId == targetId) return;
    session.edit(AddEdge(Edge(id: newId('e'), source: sourceId, target: targetId)));
  }

  void deleteEdge(String edgeId) {
    session.edit(RemoveEdge(edgeId));
    if (selectedEdgeId == edgeId) selectedEdgeId = null;
    notifyListeners();
  }

  /// Live references to [nodeId] from other nodes: what deleting it would break.
  List<({String node, FieldKey field, OutputRef ref, bool broken})> referencesTo(String nodeId) =>
      doc.referencesTo(nodeId).where((r) => !r.broken).toList();

  void deleteNode(String nodeId) {
    _rememberTitles();
    session.edit(RemoveNode(nodeId));
    if (selectedNodeId == nodeId) selectedNodeId = null;
    notifyListeners();
  }

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
        _addNotice(Notice(
          id: _nextNoticeId++,
          kind: NoticeKind.conflict,
          message: d.message,
          detail: d.detail,
          op: op,
          reason: reason,
          cseq: cseq,
          awaitingVerdict: true,
        ));
      case OpRejected(:final cseq, :final op, :final reason):
        final d = describeRefusal(op, reason, titleOf);
        final existing = _byCseq[cseq];
        if (existing != null) {
          existing.update(message: d.message, detail: d.detail, awaitingVerdict: false);
        } else {
          _addNotice(Notice(
            id: _nextNoticeId++,
            kind: reason is Conflict ? NoticeKind.conflict : NoticeKind.refused,
            message: d.message,
            detail: d.detail,
            op: op,
            reason: reason,
            cseq: cseq,
          ));
        }
      case OpLost():
        _noteLost();
      case LocalInvalid(:final op, :final reason):
        // A stale edit refused on the spot (it began before a newer remote write) or an edit of something
        // that is gone: say so, and keep the op for "re-apply" when that makes sense.
        final d = describeRefusal(op, reason, titleOf);
        _addNotice(Notice(
          id: _nextNoticeId++,
          kind: reason is Conflict ? NoticeKind.conflict : NoticeKind.refused,
          message: d.message,
          detail: d.detail,
          op: op,
          reason: reason,
        ));
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
      message: '${n.lostCount} edit${n.lostCount == 1 ? ' was' : 's were'} lost — they had not reached the server '
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
    unawaited(_events.cancel());
    unawaited(_changes.cancel());
    super.dispose();
  }
}
