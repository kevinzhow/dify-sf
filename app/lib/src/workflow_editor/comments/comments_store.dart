/// The canvas comments of the open document, for the comments UI (Dify 1.17.1's use-workflow-comment.ts data side).
///
/// API (stable; the comments UI is built on it):
///
/// ```dart
/// CommentsStore({required CommentsApi api, required Stream<CommentsEvent> events, required String Function() clientId,
///               String Function()? userId})
/// CommentsStore.forSession(CollabSession session, {String? accountId})   // api: session.transport.comments, events:
///                                                                        // session.comments
///
/// // state (a ChangeNotifier: listeners run on every change below)
/// List<Comment> comments          // newest first (Dify's order), resolved ones included, replies inside (oldest first)
/// Comment? byId(String id)
/// String get clientId             // this client (the `author` argument of fakes without accounts)
/// String get currentUserId        // the signed-in account (protocol 1.8: authors are accounts); the client id without
///                                 // accounts
/// bool isAuthor(Comment c)        // Dify: only the author edits, moves or deletes (replies: CommentReply.createdBy)
/// Map<String, String> names       // the workspace members (account id -> name, /comments/mention-users): mention
///                                 // candidates and authors' names
/// Map<String, MentionUser> users  // the same members with their avatars
/// bool loaded, loading            // the first list arrived / a refetch is running
/// CommentsFailure? lastError      // the last refused or failed call (also on [failures]); clearError()
/// Stream<CommentsFailure> failures
///
/// // reads
/// Future<void> refresh()          // refetch the list (coalesced); runs by itself, see below
/// Future<void> refreshNames()     // refetch the mention candidates
///
/// // writes: complete with the server's answer, throw the TransportException when it refused (e.notAuthor: 403
/// // not_author) after recording it in lastError / failures
/// Future<Comment> create({required double x, required double y, required String content, List<String> mentions})
/// Future<Comment> update(String id, {required String content, List<String> mentions})  // mentions replace (Dify)
/// Future<Comment> move(String id, double x, double y)    // optimistic, rolled back if refused (as Dify)
/// Future<void> delete(String id)
/// Future<Comment> resolve(String id)                     // anyone; idempotent
/// Future<CommentReply> reply(String id, {required String content, List<String> mentions})
/// Future<CommentReply> editReply(String id, String replyId, {required String content, List<String> mentions})
/// Future<void> deleteReply(String id, String replyId)
///
/// CommentsScope.of(context) / CommentsScope.maybeOf(context)   // the editor's store (DifyWorkflowEditor provides it)
/// ```
///
/// Freshness (the server's list is the truth; notifications are best-effort): the store fetches the list when created,
/// on every `comments` notification of the session's event stream, and after every (re)connect of the stream (the
/// session's [CommentsAction.resync]); names are refetched with it. As in Dify, a move is optimistic (the pin moves at
/// once and goes back if the server refuses); other writes wait for the server, apply its answer, then refetch.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

/// A write or refetch that failed: what was attempted and the error (usually a [TransportException]).
@immutable
class CommentsFailure {
  const CommentsFailure(this.action, this.error, {this.commentId});

  /// `refresh`, `names`, `create`, `update`, `move`, `delete`, `resolve`, `reply`, `editReply`, `deleteReply`.
  final String action;
  final String? commentId;
  final Object error;

  /// Someone other than the author tried to edit, move or delete (`403 not_author`).
  bool get notAuthor => error is TransportException && (error as TransportException).notAuthor;

  @override
  String toString() => 'CommentsFailure($action${commentId == null ? '' : ' $commentId'}: $error)';
}

class CommentsStore extends ChangeNotifier {
  CommentsStore({
    required this._api,
    required Stream<CommentsEvent> events,
    required this._clientId,
    String Function()? userId,
  }) : _userId = userId ?? _clientId {
    _events = events.listen(_onEvent);
    unawaited(refresh());
    unawaited(refreshNames());
  }

  /// The store of a session's document: its transport's comments, its stream's notifications, its client id, and the
  /// signed-in [accountId] as the current user (protocol 1.8; null: no accounts, the client id is the user).
  factory CommentsStore.forSession(CollabSession session, {String? accountId}) => CommentsStore(
    api: session.transport.comments,
    events: session.comments,
    clientId: () => session.clientId,
    userId: accountId == null ? null : () => accountId,
  );

  final CommentsApi _api;
  final String Function() _clientId;
  final String Function() _userId;
  late final StreamSubscription<CommentsEvent> _events;
  final _failures = StreamController<CommentsFailure>.broadcast();
  bool _disposed = false;

  List<Comment> _comments = const [];
  Map<String, String> _names = const {};
  Map<String, MentionUser> _users = const {};
  bool _loaded = false;
  CommentsFailure? _lastError;

  /// Moves sent but not answered yet: their pins stay where the user put them whatever a refetch says.
  final Map<String, ({double x, double y})> _moving = {};

  /// Newest first, resolved ones included.
  List<Comment> get comments => _comments;

  Comment? byId(String id) {
    for (final c in _comments) {
      if (c.id == id) return c;
    }
    return null;
  }

  String get clientId => _clientId();

  /// The signed-in account (authors are accounts, protocol 1.8); the client id when there are no accounts.
  String get currentUserId => _userId();

  bool isAuthor(Comment c) => c.createdBy == currentUserId;

  /// The workspace members, id -> name (`/comments/mention-users`): the mention candidates and authors' names.
  Map<String, String> get names => _names;

  /// The members with their avatars.
  Map<String, MentionUser> get users => _users;

  bool get loaded => _loaded;
  bool get loading => _refreshing != null;
  CommentsFailure? get lastError => _lastError;
  Stream<CommentsFailure> get failures => _failures.stream;

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  // ---- reads -------------------------------------------------------------------------------------

  Future<void>? _refreshing;
  bool _again = false;

  /// Refetches the list. Calls while one is running coalesce into one more fetch after it.
  Future<void> refresh() {
    if (_disposed) return Future.value();
    final running = _refreshing;
    if (running != null) {
      _again = true;
      return running;
    }
    final f = _refreshing = _refreshLoop();
    _notify();
    return f;
  }

  Future<void> _refreshLoop() async {
    try {
      do {
        _again = false;
        try {
          final list = await _api.list();
          if (_disposed) return;
          _comments = [for (final c in list) _withPendingMove(c)];
          _loaded = true;
        } on Object catch (e) {
          if (_disposed) return;
          _fail(CommentsFailure('refresh', e));
        }
      } while (_again && !_disposed);
    } finally {
      _refreshing = null;
      _notify();
    }
  }

  Future<void> refreshNames() async {
    try {
      final users = await _api.mentionUsers();
      if (_disposed) return;
      _users = Map.unmodifiable({for (final u in users) u.id: u});
      _names = Map.unmodifiable({for (final u in users) u.id: u.name});
      _notify();
    } on Object catch (e) {
      if (!_disposed) _fail(CommentsFailure('names', e));
    }
  }

  /// A notification from the stream (or its reconnect): the list, and the directory (clients come and go).
  void _onEvent(CommentsEvent e) {
    unawaited(refresh());
    unawaited(refreshNames());
  }

  Comment _withPendingMove(Comment c) {
    final m = _moving[c.id];
    return m == null ? c : c.copyWith(positionX: m.x, positionY: m.y);
  }

  // ---- writes ------------------------------------------------------------------------------------

  Future<Comment> create({
    required double x,
    required double y,
    required String content,
    List<String> mentions = const [],
  }) => _write('create', null, () async {
    final c = await _api.create(author: clientId, x: x, y: y, content: content, mentions: mentions);
    _put(c, front: true);
    return c;
  });

  /// Dify's handleCommentUpdate: content and the mention list (which replaces the mentions).
  Future<Comment> update(String id, {required String content, List<String> mentions = const []}) =>
      _write('update', id, () async {
        final c = await _api.update(id, author: clientId, content: content, mentions: mentions);
        _put(c);
        return c;
      });

  /// Dify's handleCommentPositionUpdate: the pin moves at once; a refusal (not the author, gone, offline) puts it back.
  Future<Comment> move(String id, double x, double y) async {
    final before = byId(id);
    _moving[id] = (x: x, y: y);
    if (before != null) _put(before.copyWith(positionX: x, positionY: y));
    try {
      return await _write('move', id, () async {
        final c = await _api.update(id, author: clientId, x: x, y: y);
        _moving.remove(id);
        _put(c);
        return c;
      });
    } on Object {
      _moving.remove(id);
      final now = byId(id);
      if (before != null && now != null) _put(now.copyWith(positionX: before.positionX, positionY: before.positionY));
      rethrow;
    }
  }

  Future<void> delete(String id) => _write('delete', id, () async {
    await _api.delete(id, author: clientId);
    _comments = [
      for (final c in _comments)
        if (c.id != id) c,
    ];
  });

  Future<Comment> resolve(String id) => _write('resolve', id, () async {
    final c = await _api.resolve(id, author: clientId);
    _put(c);
    return c;
  });

  Future<CommentReply> reply(String id, {required String content, List<String> mentions = const []}) =>
      _write('reply', id, () async {
        final r = await _api.reply(id, author: clientId, content: content, mentions: mentions);
        final c = byId(id);
        if (c != null) _put(c.copyWith(replies: [...c.replies, r]));
        return r;
      });

  Future<CommentReply> editReply(
    String id,
    String replyId, {
    required String content,
    List<String> mentions = const [],
  }) => _write('editReply', id, () async {
    final r = await _api.editReply(id, replyId, author: clientId, content: content, mentions: mentions);
    final c = byId(id);
    if (c != null) _put(c.copyWith(replies: [for (final x in c.replies) x.id == replyId ? r : x]));
    return r;
  });

  Future<void> deleteReply(String id, String replyId) => _write('deleteReply', id, () async {
    await _api.deleteReply(id, replyId, author: clientId);
    final c = byId(id);
    if (c != null) {
      _put(
        c.copyWith(
          replies: [
            for (final x in c.replies)
              if (x.id != replyId) x,
          ],
        ),
      );
    }
  });

  /// Runs a write: on success its local effect is shown and the list refetched (as Dify reloads after each write); on
  /// failure the error is recorded and rethrown.
  Future<T> _write<T>(String action, String? id, Future<T> Function() body) async {
    try {
      final result = await body();
      if (!_disposed) {
        _notify();
        unawaited(refresh());
      }
      return result;
    } on Object catch (e) {
      if (!_disposed) _fail(CommentsFailure(action, e, commentId: id));
      rethrow;
    }
  }

  /// Replaces the comment with the same id (or adds it: at the front for a new one).
  void _put(Comment c, {bool front = false}) {
    if (_disposed) return;
    final i = _comments.indexWhere((x) => x.id == c.id);
    _comments = i >= 0
        ? [..._comments.take(i), c, ..._comments.skip(i + 1)]
        : (front ? [c, ..._comments] : [..._comments, c]);
    _notify();
  }

  void _fail(CommentsFailure f) {
    _lastError = f;
    if (!_failures.isClosed) _failures.add(f);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_events.cancel());
    unawaited(_failures.close());
    super.dispose();
  }
}

/// Provides the editor's [CommentsStore] to the comments UI (and rebuilds dependents when it changes).
class CommentsScope extends InheritedNotifier<CommentsStore> {
  const CommentsScope({super.key, required CommentsStore store, required super.child}) : super(notifier: store);

  /// The store, rebuilding the caller on every change.
  static CommentsStore of(BuildContext context) => maybeOf(context)!;

  static CommentsStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CommentsScope>()?.notifier;

  /// The store without subscribing to its changes (for callbacks).
  static CommentsStore? read(BuildContext context) => context.getInheritedWidgetOfExactType<CommentsScope>()?.notifier;
}
