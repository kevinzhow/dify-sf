import '../wire/messages.dart';
import 'comments_api.dart';

/// How a [CollabSession](session.dart) talks to the server for one document. Implementations: the real
/// HTTP/SSE transport and the in-memory fake transport used by tests.
abstract interface class CollabTransport {
  /// `POST /v1/docs/{doc}/ops`. Throws [TransportException] on any failure (connect error, timeout, non-2xx).
  /// Resending the same request is always safe (ops are idempotent by `(client, cseq)`).
  Future<SubmitResponse> submit(SubmitRequest request, {required Duration timeout});

  /// `GET /v1/docs/{doc}/events`. The stream emits decoded events (including [PingEvent] for any inbound
  /// bytes that did not complete an event); it ends (done or error) when the connection ends. Cancelling the
  /// subscription closes the connection.
  Stream<StreamEvent> openStream(StreamOpen open);

  /// `POST /v1/docs/{doc}/clients` (protocol 1.1): a fresh, unique client id. Use one per client instance.
  /// [name] registers a display name for it (protocol 1.3).
  Future<String> issueClientId({String? name});

  /// `PUT /v1/docs/{doc}/clients/{client}` (protocol 1.3): names or renames [client].
  Future<void> setClientName(String client, String name);

  /// `POST /v1/docs/{doc}/secrets` (protocol 1.7): stores the plaintext of a secret environment variable on the server
  /// and returns its reference and Dify's mask. The variable is then written with ordinary item ops on `$app`
  /// (`value` = the mask, `secret_ref` = the reference); the plaintext never enters ops, the log or snapshots.
  Future<({String ref, String masked})> storeSecret(String value);

  /// The canvas comments of this document (docs/protocol.md, "Comments"). Their change notifications arrive on the
  /// event stream as [CommentsEvent]s (`CollabSession.comments`).
  CommentsApi get comments;

  /// Releases resources (open connections).
  void close();
}

class TransportException implements Exception {
  const TransportException(this.message, {this.statusCode, this.code, this.timeout = false});

  final String message;

  /// HTTP status, if the server answered.
  final int? statusCode;

  /// The server's error code (`bad_request`, `not_found`, `unavailable`, ...), if it sent one.
  final String? code;

  /// The request timed out (outcome unknown; resend).
  final bool timeout;

  bool get payloadTooLarge => statusCode == 413;

  /// Not signed in, or the access token is no longer valid (`401 unauthorized`, protocol 1.8). Requests through an
  /// `AuthSession` have already refreshed once; this means the user has to sign in again.
  bool get unauthorized => statusCode == 401;

  /// The caller's role does not allow this, or the client id belongs to another account (`403 forbidden`, protocol 1.8).
  bool get forbidden => statusCode == 403 && code == 'forbidden';

  /// A comment or reply was edited, moved or deleted by someone other than its author (`403 not_author`).
  bool get notAuthor => statusCode == 403 && code == 'not_author';

  @override
  String toString() =>
      'TransportException($message${statusCode == null ? '' : ', HTTP $statusCode'}'
      '${code == null ? '' : ', $code'}${timeout ? ', timeout' : ''})';
}
