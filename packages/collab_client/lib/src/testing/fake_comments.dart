import 'package:clock/clock.dart';

import '../auth/account.dart';
import '../auth/auth_session.dart';
import '../client/comments_api.dart';
import '../client/transport.dart';
import '../model/comments.dart';
import '../wire/messages.dart';
import 'fake_accounts.dart';
import 'fake_server.dart';
import 'fake_transport.dart';

/// A refusal of the in-memory comments server, with the HTTP status and error code the real server would answer.
final class FakeCommentsError implements Exception {
  const FakeCommentsError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'FakeCommentsError($status $code: $message)';
}

/// The canvas comments of one in-memory document, with the reference server's rules (docs/protocol.md, "Comments"):
/// Dify's content limits, author-only edit/move/delete (`403 not_author`), idempotent resolve, replies, mentions
/// filtered to members (or, without accounts, to valid ids) once each, newest first. Answers are wire JSON, exactly as
/// the server sends them. Every change is announced to the listeners (the stream's `event: comments`).
///
/// The `client` arguments name the acting author: an account id with accounts (protocol 1.8), a client id without.
class FakeComments {
  FakeComments(this._names, {Set<String>? Function()? members}) : _members = members ?? (() => null);

  /// Author id -> name and avatar at answer time.
  final Map<String, ({String name, String? avatarUrl})> Function() _names;

  /// The workspace members' account ids (mentions are filtered to them); null = no accounts (valid ids are kept).
  final Set<String>? Function() _members;
  final Map<String, _FakeComment> _byId = {};
  int _issued = 0;
  final List<void Function(CommentsEvent)> _listeners = [];

  void addListener(void Function(CommentsEvent) l) => _listeners.add(l);
  void removeListener(void Function(CommentsEvent) l) => _listeners.remove(l);

  int get length => _byId.length;

  /// `GET /comments`.
  List<Map<String, Object?>> list() {
    final all = _byId.values.toList()..sort((a, b) => b.order.compareTo(a.order));
    return [for (final c in all) _json(c)];
  }

  /// `GET /comments/{id}`.
  Map<String, Object?> get(String id) => _json(_find(id));

  /// `POST /comments`.
  Map<String, Object?> create({
    required String? client,
    required Object? x,
    required Object? y,
    required Object? content,
    Object? mentions,
  }) {
    final by = _author(client);
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) _bad('position_x and position_y must be numbers');
    final text = _content(content);
    final now = clock.now().toUtc();
    final c = _FakeComment(
      id: _newId(now),
      order: ++_issued,
      x: x.toDouble(),
      y: y.toDouble(),
      content: text,
      createdBy: by,
      createdAt: now,
      mentions: _mentions(mentions) ?? const [],
    );
    _byId[c.id] = c;
    _announce(c.id, CommentsAction.created);
    return _json(c);
  }

  /// `PUT /comments/{id}`: author only; omitted (null) fields stay.
  Map<String, Object?> update(
    String id, {
    required String? client,
    Object? content,
    Object? x,
    Object? y,
    Object? mentions,
  }) {
    final by = _author(client);
    if ((x != null && (x is! num || !x.isFinite)) || (y != null && (y is! num || !y.isFinite))) {
      _bad('positions must be finite numbers');
    }
    final text = content == null ? null : _content(content);
    final m = mentions == null ? null : _mentions(mentions);
    final c = _find(id);
    _mustBeAuthor(c.createdBy, by, 'comment');
    if (text != null) c.content = text;
    if (x != null) c.x = (x as num).toDouble();
    if (y != null) c.y = (y as num).toDouble();
    if (m != null) c.mentions = m;
    c.updatedAt = clock.now().toUtc();
    _announce(id, CommentsAction.updated);
    return _json(c);
  }

  /// `DELETE /comments/{id}?client=`: author only.
  void delete(String id, {required String? client}) {
    final by = _author(client);
    _mustBeAuthor(_find(id).createdBy, by, 'comment');
    _byId.remove(id);
    _announce(id, CommentsAction.deleted);
  }

  /// `POST /comments/{id}/resolve`: anyone, idempotent.
  Map<String, Object?> resolve(String id, {required String? client}) {
    final by = _author(client);
    final c = _find(id);
    if (!c.resolved) {
      c
        ..resolved = true
        ..resolvedBy = by
        ..resolvedAt = clock.now().toUtc()
        ..updatedAt = c.resolvedAt!;
      _announce(id, CommentsAction.resolved);
    }
    return _json(c);
  }

  /// `POST /comments/{id}/replies`: anyone.
  Map<String, Object?> reply(String id, {required String? client, required Object? content, Object? mentions}) {
    final by = _author(client);
    final text = _content(content);
    final m = _mentions(mentions) ?? const [];
    final c = _find(id);
    final now = clock.now().toUtc();
    final r = _FakeReply(id: _newId(now), content: text, createdBy: by, createdAt: now, mentions: m);
    c.replies.add(r);
    _announce(id, CommentsAction.reply);
    return _replyJson(r);
  }

  /// `PUT /comments/{id}/replies/{rid}`: author only; the mentions are replaced (omitted = none, as Dify).
  Map<String, Object?> editReply(
    String id,
    String replyId, {
    required String? client,
    required Object? content,
    Object? mentions,
  }) {
    final by = _author(client);
    final text = _content(content);
    final m = _mentions(mentions) ?? const [];
    final r = _findReply(id, replyId);
    _mustBeAuthor(r.createdBy, by, 'reply');
    r
      ..content = text
      ..mentions = m
      ..updatedAt = clock.now().toUtc();
    _announce(id, CommentsAction.reply);
    return _replyJson(r);
  }

  /// `DELETE /comments/{id}/replies/{rid}?client=`: author only.
  void deleteReply(String id, String replyId, {required String? client}) {
    final by = _author(client);
    final r = _findReply(id, replyId);
    _mustBeAuthor(r.createdBy, by, 'reply');
    _byId[id]!.replies.remove(r);
    _announce(id, CommentsAction.reply);
  }

  // ---- rules ---------------------------------------------------------------------------------------

  static final _clientId = RegExp(r'^[A-Za-z0-9_.:\-]{1,64}$');

  static Never _bad(String message) => throw FakeCommentsError(400, 'bad_request', message);

  String _author(String? client) {
    if (client == null || !_clientId.hasMatch(client)) _bad('invalid or missing client id');
    return client;
  }

  String _content(Object? content) {
    if (content is! String) _bad('content must be a string');
    final problem = commentContentProblem(content);
    if (problem != null) _bad(problem);
    return content;
  }

  List<String>? _mentions(Object? ids) {
    if (ids == null) return null;
    if (ids is! List<Object?> || ids.any((e) => e is! String)) _bad('mentioned_user_ids must be a list of strings');
    final members = _members();
    final seen = <String>{};
    return [
      for (final id in ids.cast<String>())
        if ((members == null ? _clientId.hasMatch(id) : members.contains(id)) && seen.add(id)) id,
    ];
  }

  void _mustBeAuthor(String author, String by, String what) {
    if (author != by) throw FakeCommentsError(403, 'not_author', 'only the author may change or delete this $what');
  }

  _FakeComment _find(String id) => _byId[id] ?? (throw const FakeCommentsError(404, 'not_found', 'unknown comment'));

  _FakeReply _findReply(String id, String replyId) {
    final c = _byId[id];
    for (final r in c?.replies ?? const <_FakeReply>[]) {
      if (r.id == replyId) return r;
    }
    throw const FakeCommentsError(404, 'not_found', 'unknown reply');
  }

  /// A UUID version 7 (time-ordered, as the server's), unique by a counter in the random bits.
  String _newId(DateTime now) {
    final ms = now.millisecondsSinceEpoch.toRadixString(16).padLeft(12, '0');
    final n = (++_issued).toRadixString(16).padLeft(15, '0');
    return '${ms.substring(0, 8)}-${ms.substring(8)}-7000-8${n.substring(0, 3)}-${n.substring(3)}';
  }

  void _announce(String id, CommentsAction action) {
    final e = CommentsEvent(comment: id, action: action);
    for (final l in List.of(_listeners)) {
      l(e);
    }
  }

  // ---- wire JSON -----------------------------------------------------------------------------------

  Map<String, Object?> _mention(String id, Map<String, ({String name, String? avatarUrl})> names) => {
    'account': id,
    'name': ?names[id]?.name,
    'avatar_url': ?names[id]?.avatarUrl,
  };

  Map<String, Object?> _replyJson(_FakeReply r, [Map<String, ({String name, String? avatarUrl})>? names]) {
    final n = names ?? _names();
    return {
      'id': r.id,
      'content': r.content,
      'created_by': r.createdBy,
      'created_by_name': ?n[r.createdBy]?.name,
      'created_by_avatar_url': ?n[r.createdBy]?.avatarUrl,
      'created_at': r.createdAt.toIso8601String(),
      'updated_at': r.updatedAt.toIso8601String(),
      'mentions': [for (final m in r.mentions) _mention(m, n)],
    };
  }

  Map<String, Object?> _json(_FakeComment c) {
    final n = _names();
    return {
      'id': c.id,
      'position_x': c.x,
      'position_y': c.y,
      'content': c.content,
      'created_by': c.createdBy,
      'created_by_name': ?n[c.createdBy]?.name,
      'created_by_avatar_url': ?n[c.createdBy]?.avatarUrl,
      'created_at': c.createdAt.toIso8601String(),
      'updated_at': c.updatedAt.toIso8601String(),
      'resolved': c.resolved,
      'resolved_by': ?c.resolvedBy,
      'resolved_by_name': ?(c.resolvedBy == null ? null : n[c.resolvedBy]?.name),
      'resolved_by_avatar_url': ?(c.resolvedBy == null ? null : n[c.resolvedBy]?.avatarUrl),
      'resolved_at': ?c.resolvedAt?.toIso8601String(),
      'mentions': [for (final m in c.mentions) _mention(m, n)],
      'replies': [for (final r in c.replies) _replyJson(r, n)],
      'reply_count': c.replies.length,
    };
  }
}

class _FakeComment {
  _FakeComment({
    required this.id,
    required this.order,
    required this.x,
    required this.y,
    required this.content,
    required this.createdBy,
    required this.createdAt,
    required this.mentions,
  }) : updatedAt = createdAt;

  final String id;
  final int order;
  double x, y;
  String content;
  final String createdBy;
  final DateTime createdAt;
  DateTime updatedAt;
  bool resolved = false;
  String? resolvedBy;
  DateTime? resolvedAt;
  List<String> mentions;
  final List<_FakeReply> replies = [];
}

class _FakeReply {
  _FakeReply({
    required this.id,
    required this.content,
    required this.createdBy,
    required this.createdAt,
    required this.mentions,
  }) : updatedAt = createdAt;

  final String id;
  String content;
  final String createdBy;
  final DateTime createdAt;
  DateTime updatedAt;
  List<String> mentions;
}

/// [CommentsApi] on an in-memory [FakeServer] (its [FakeServer.comments]), through the reachability of a [FakeNetwork]
/// (refused or partitioned: the call fails like a connect error). Refusals become [TransportException]s with the
/// status and code of the real server. With accounts on the server (protocol 1.8) the author is the account of [auth]'s
/// token (a `401` refreshes once), reads need a member and writes the edit role; without, the `author` arguments are the
/// author ids.
class FakeCommentsApi implements CommentsApi {
  FakeCommentsApi(this.server, {FakeNetwork? network, this.auth}) : network = network ?? FakeNetwork();

  final FakeServer server;
  final FakeNetwork network;
  final TokenProvider? auth;

  /// Requests that reached the server (for assertions about refetches).
  int requests = 0;

  /// One request: [f] gets the comments and the acting author id (the account with accounts, else [author]).
  Future<T> _call<T>(String? author, T Function(FakeComments c, String? by) f, {bool write = false}) async {
    await Future<void>.microtask(() {}); // asynchronous like a request (no timer: widget tests stay clean)
    if (network.refused || network.partitioned) throw const TransportException('connection refused');
    requests++;
    final accounts = server.accounts;
    String? by = author;
    if (accounts != null) {
      final token = auth?.accessToken;
      try {
        by = accounts.principal(token, edit: write).id;
      } on FakeAuthError catch (e) {
        if (e.status == 401 && auth != null && token != null && await auth!.refresh(failedToken: token)) {
          return _call(author, f, write: write);
        }
        throw e.toTransport();
      }
    }
    try {
      return f(server.comments, by);
    } on FakeCommentsError catch (e) {
      throw TransportException(e.message, statusCode: e.status, code: e.code);
    }
  }

  @override
  Future<List<Comment>> list() => _call(null, (c, _) => [for (final j in c.list()) Comment.fromJson(j)]);

  @override
  Future<Comment> get(String id) => _call(null, (c, _) => Comment.fromJson(c.get(id)));

  @override
  Future<Comment> create({
    String? author,
    required double x,
    required double y,
    required String content,
    List<String> mentions = const [],
  }) => _call(
    author,
    (c, by) => Comment.fromJson(c.create(client: by, x: x, y: y, content: content, mentions: mentions)),
    write: true,
  );

  @override
  Future<Comment> update(String id, {String? author, String? content, double? x, double? y, List<String>? mentions}) =>
      _call(
        author,
        (c, by) => Comment.fromJson(c.update(id, client: by, content: content, x: x, y: y, mentions: mentions)),
        write: true,
      );

  @override
  Future<void> delete(String id, {String? author}) => _call(author, (c, by) => c.delete(id, client: by), write: true);

  @override
  Future<Comment> resolve(String id, {String? author}) =>
      _call(author, (c, by) => Comment.fromJson(c.resolve(id, client: by)), write: true);

  @override
  Future<CommentReply> reply(String id, {String? author, required String content, List<String> mentions = const []}) =>
      _call(
        author,
        (c, by) => CommentReply.fromJson(c.reply(id, client: by, content: content, mentions: mentions)),
        write: true,
      );

  @override
  Future<CommentReply> editReply(
    String id,
    String replyId, {
    String? author,
    required String content,
    List<String> mentions = const [],
  }) => _call(
    author,
    (c, by) => CommentReply.fromJson(c.editReply(id, replyId, client: by, content: content, mentions: mentions)),
    write: true,
  );

  @override
  Future<void> deleteReply(String id, String replyId, {String? author}) =>
      _call(author, (c, by) => c.deleteReply(id, replyId, client: by), write: true);

  @override
  Future<List<MentionUser>> mentionUsers() => _call(null, (_, _) {
    final a = server.accounts;
    if (a == null) {
      return [for (final e in server.names.entries) MentionUser(id: e.key, name: e.value, email: '', role: '')];
    }
    return [for (final u in a.mentionUsers(auth?.accessToken)) MentionUser.fromJson(u)];
  });

  @override
  Future<Map<String, ClientIdentity>> clientDirectory() => _call(
    null,
    (_, _) => {for (final e in server.directory().entries) e.key: ClientIdentity.fromJson(e.value)},
  );

  @override
  Future<Map<String, String>> clientNames() async =>
      (await clientDirectory()).map((client, who) => MapEntry(client, who.name));
}
