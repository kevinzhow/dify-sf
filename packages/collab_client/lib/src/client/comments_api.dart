import '../model/comments.dart';

/// Canvas comments of one document (docs/protocol.md, section 2 "Comments"). Every call is one request; failures throw a
/// `TransportException` (`statusCode` 403 with `code` `not_author` when someone other than the author edits, moves or
/// deletes; 404 `not_found` for an unknown comment or reply; 400 `bad_request` for invalid content). [author] is the
/// acting client id (the session's `clientId`).
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
    required String author,
    required double x,
    required double y,
    required String content,
    List<String> mentions = const [],
  });

  /// `PUT /comments/{id}` (author only). Null fields stay as they are; [mentions] null keeps the mentions, a list
  /// (also empty) replaces them. A move is `update(..., x: .., y: ..)`.
  Future<Comment> update(
    String id, {
    required String author,
    String? content,
    double? x,
    double? y,
    List<String>? mentions,
  });

  /// `DELETE /comments/{id}?client=` (author only); the replies go with it.
  Future<void> delete(String id, {required String author});

  /// `POST /comments/{id}/resolve` (anyone; idempotent: the first resolver stays).
  Future<Comment> resolve(String id, {required String author});

  /// `POST /comments/{id}/replies` (anyone).
  Future<CommentReply> reply(
    String id, {
    required String author,
    required String content,
    List<String> mentions = const [],
  });

  /// `PUT /comments/{id}/replies/{replyId}` (author only). The mentions are replaced by [mentions] (Dify's behaviour).
  Future<CommentReply> editReply(
    String id,
    String replyId, {
    required String author,
    required String content,
    List<String> mentions = const [],
  });

  /// `DELETE /comments/{id}/replies/{replyId}?client=` (author only).
  Future<void> deleteReply(String id, String replyId, {required String author});

  /// `GET /clients` (protocol 1.3): client id -> display name of every client that registered one; the mention
  /// candidates.
  Future<Map<String, String>> clientNames();
}
