import '../wire/messages.dart';

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
  Future<String> issueClientId();

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

  @override
  String toString() =>
      'TransportException($message${statusCode == null ? '' : ', HTTP $statusCode'}'
      '${code == null ? '' : ', $code'}${timeout ? ', timeout' : ''})';
}
