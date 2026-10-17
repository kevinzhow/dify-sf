import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import 'graph_info.dart';

enum NoticeKind { conflict, refused, lost, info }

/// A non-modal message about the fate of an edit.
class Notice extends ChangeNotifier {
  Notice({
    required this.id,
    required this.kind,
    required this.message,
    this.detail,
    this.op,
    this.reason,
    this.cseq,
    this.awaitingVerdict = false,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final int id;
  final NoticeKind kind;
  String message;
  String? detail;
  final DateTime at;

  /// The edit that was not applied, so the user can re-apply it.
  final Op? op;
  final RejectReason? reason;
  final int? cseq;

  /// An early warning: the server has not confirmed the rejection yet.
  bool awaitingVerdict;

  /// For lost-write notices: how many edits were lost.
  int lostCount = 0;

  bool get canReapply => op != null && !awaitingVerdict && reason is Conflict;

  void update({String? message, String? detail, bool? awaitingVerdict}) {
    if (message != null) this.message = message;
    if (detail != null) this.detail = detail;
    if (awaitingVerdict != null) this.awaitingVerdict = awaitingVerdict;
    notifyListeners();
  }
}

/// The wording of a refused edit. [titleOf] resolves node ids (also of deleted nodes).
({String message, String? detail}) describeRefusal(
  Op op,
  RejectReason reason,
  String Function(String nodeId) titleOf, {
  DateTime? at,
}) {
  final when = ago(at ?? DateTime.now());
  String? valuePreview() => switch (op) {
    SetField(:final value) => 'Your value: ${previewValue(value)}',
    UpdateItem(:final value) => 'Your value: ${previewValue(value)}',
    MoveNode(:final x, :final y) => 'Your position: $x, $y',
    _ => null,
  };
  switch (reason) {
    case Conflict(:final field, :final by, :final byName, :final node):
      final who = byName ?? clientDisplayName(by);
      if (field == null) {
        final what = op is RemoveNode ? 'delete' : 'change';
        return (
          message: '$who changed ${titleOf(node)} $when — your $what wasn\'t applied',
          detail:
              'Their changes are kept. Re-apply to ${op is RemoveNode ? 'delete it anyway' : 'try again'} on the latest version.',
        );
      }
      return (
        message: '$who changed ${fieldLabel(field)} $when — your change wasn\'t applied',
        detail: [if (op.nodeId != null) 'In ${titleOf(op.nodeId!)}.', ?valuePreview()].join(' '),
      );
    case NodeDeleted(:final node):
      return (message: '${titleOf(node)} was deleted — your change wasn\'t applied', detail: valuePreview());
    case DanglingReference(:final node):
      return (
        message: 'The variable you picked from ${titleOf(node)} no longer exists — your change wasn\'t applied',
        detail: 'Pick another variable.',
      );
    case ItemDeleted():
      return (message: 'That item was removed by someone else — your change wasn\'t applied', detail: valuePreview());
    case NotDeleter(:final node, :final by):
      return (message: '${clientDisplayName(by)} deleted ${titleOf(node)} — only they can undo that', detail: null);
    case NodeNotFound(:final node):
      return (message: 'Node ${titleOf(node)} doesn\'t exist — your change wasn\'t applied', detail: null);
    case EdgeNotFound():
      return (message: 'That connection was already removed.', detail: null);
    case DuplicateEdge():
      return (message: 'Those nodes are already connected.', detail: null);
    case Invalid(:final message):
      return (message: 'Your change was refused: $message', detail: null);
    default:
      return (message: 'Your change wasn\'t applied (${reason.name}).', detail: valuePreview());
  }
}
