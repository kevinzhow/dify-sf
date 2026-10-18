import '../auth/account.dart';
import '../model/comments.dart';

/// Canvas comments of one document (docs/protocol.md, section 2 "Comments"). Every call is one request; failures throw a
/// `TransportException` (`statusCode` 403 with `code` `not_author` when someone other than the author edits, moves or
/// deletes; `403 forbidden` for a write by a read-only role; 404 `not_found` for an unknown comment or reply; 400
/// `bad_request` for invalid content; 401 when not signed in).
///
/// Protocol 1.8: the author is the **signed-in account** (the request's bearer token): comments, replies, resolvers and
/// mentions are account ids, and any client of the author's account may edit. [author] is ignored by real servers and by
/// fakes with accounts; fakes without accounts (`FakeServer()` alone) still use it as the author id.
/// [mentions] are account ids of workspace members ([mentionUsers]).
///
/// Implementations: `HttpCommentsApi` (the real server) and `FakeCommentsApi` (an in-memory `FakeServer`); a
/// transport hands out the one for its document (`CollabTransport.comments`).
abstract interface class CommentsApi {
  /// `GET /comments`: all comments with their replies, newest first, resolved ones included.
  Future<List<Comment>> list();

  /// `GET /comments/{id}`.
  Future<Comment> get(String id);

  /// `POST /comments`.
  Future<Comment> create({
    String? author,
    required double x,
    required double y,
    required String content,
    List<String> mentions = const [],
  });

  /// `PUT /comments/{id}` (author only). Null fields stay as they are; [mentions] null keeps the mentions, a list
  /// (also empty) replaces them. A move is `update(..., x: .., y: ..)`.
  Future<Comment> update(String id, {String? author, String? content, double? x, double? y, List<String>? mentions});

  /// `DELETE /comments/{id}` (author only); the replies go with it.
  Future<void> delete(String id, {String? author});

  /// `POST /comments/{id}/resolve` (any editor; idempotent: the first resolver stays).
  Future<Comment> resolve(String id, {String? author});

  /// `POST /comments/{id}/replies` (any editor).
  Future<CommentReply> reply(String id, {String? author, required String content, List<String> mentions = const []});

  /// `PUT /comments/{id}/replies/{replyId}` (author only). The mentions are replaced by [mentions] (Dify's behaviour).
  Future<CommentReply> editReply(
    String id,
    String replyId, {
    String? author,
    required String content,
    List<String> mentions = const [],
  });

  /// `DELETE /comments/{id}/replies/{replyId}` (author only).
  Future<void> deleteReply(String id, String replyId, {String? author});

  /// `GET /comments/mention-users` (protocol 1.8): the workspace members, Dify's mention candidates.
  Future<List<MentionUser>> mentionUsers();

  /// `GET /clients` (protocol 1.8): client id -> the account it belongs to. Online users are accounts: several client
  /// ids of one account are one user.
  Future<Map<String, ClientIdentity>> clientDirectory();

  /// Client id -> account name, from [clientDirectory]. (Before 1.8: the clients' display names.)
  Future<Map<String, String>> clientNames();
}
