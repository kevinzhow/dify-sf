import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../client/comments_api.dart';
import '../client/transport.dart';
import '../wire/messages.dart';
import 'http_comments_api.dart';
import 'sse_parser.dart';

/// Real transport: `POST` for ops, a hand-rolled SSE reader for the event stream. Works on the Dart VM and
/// in the browser (package:http streams response bodies with `fetch` on the web).
///
/// All resilience policy (silence watchdog, backoff, resume) lives in the client state machine; this class
/// only moves bytes and reports failures:
///
/// * [submit] fails with [TransportException] on connect errors, timeouts and non-2xx answers.
/// * [openStream] emits a [PingEvent] for every inbound chunk (keep-alive comments included) so the
///   machine can run its "no bytes for N seconds" watchdog; it ends with an error or done when the
///   connection ends or the server sends something unparseable.
class HttpTransport implements CollabTransport {
  HttpTransport({
    required Uri baseUrl,
    required this.docId,
    http.Client? client,
    this.connectTimeout = const Duration(seconds: 10),
    this.lastEventIdInQuery = false,
  }) : _base = baseUrl,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String docId;
  final http.Client _client;
  final bool _ownsClient;

  /// How long to wait for response headers when opening the stream.
  final Duration connectTimeout;

  /// Send the resume point as `?lastEventId=` instead of the `Last-Event-ID` header. Not needed any more: since
  /// protocol 1.1 the server answers CORS preflights and allows `Last-Event-ID`, so browsers can use the header
  /// like everybody else. Kept for servers that predate 1.1.
  final bool lastEventIdInQuery;

  Uri _url(String suffix, [Map<String, String>? query]) => _base.replace(
    path:
        '${_base.path.endsWith('/') ? _base.path.substring(0, _base.path.length - 1) : _base.path}/v1/docs/$docId$suffix',
    queryParameters: query,
  );

  @override
  late final CommentsApi comments = HttpCommentsApi(
    baseUrl: _base,
    docId: docId,
    client: _client,
    timeout: connectTimeout,
  );

  @override
  Future<SubmitResponse> submit(SubmitRequest request, {required Duration timeout}) async {
    final abort = Completer<void>();
    final req = http.AbortableRequest('POST', _url('/ops'), abortTrigger: abort.future)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(request.toJson());
    try {
      return await _sendAndRead(req, abort, timeout);
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('POST failed: $e');
    }
  }

  Future<SubmitResponse> _sendAndRead(http.AbortableRequest req, Completer<void> abort, Duration timeout) async {
    final work = () async {
      final res = await _client.send(req);
      final body = await res.stream.bytesToString();
      if (res.statusCode != 200) throw _errorFrom(res.statusCode, body);
      return SubmitResponse.fromJson(jsonDecode(body));
    }();
    try {
      return await work.timeout(timeout);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      unawaited(work.then<void>((_) {}, onError: (Object _) {}));
      throw const TransportException('POST timed out', timeout: true);
    }
  }

  @override
  Future<String> issueClientId({String? name}) async {
    final abort = Completer<void>();
    final req = http.AbortableRequest('POST', _url('/clients'), abortTrigger: abort.future)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'name': ?name});
    try {
      final res = await _client.send(req).timeout(connectTimeout);
      final body = await res.stream.bytesToString();
      if (res.statusCode != 201 && res.statusCode != 200) throw _errorFrom(res.statusCode, body);
      final id = (jsonDecode(body) as Map<String, Object?>)['client'];
      if (id is! String || id.isEmpty) throw const TransportException('server issued no client id');
      return id;
    } on TransportException {
      rethrow;
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const TransportException('client id request timed out', timeout: true);
    } on Object catch (e) {
      throw TransportException('client id request failed: $e');
    }
  }

  @override
  Future<({String ref, String masked})> storeSecret(String value) async {
    final abort = Completer<void>();
    final req = http.AbortableRequest('POST', _url('/secrets'), abortTrigger: abort.future)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'value': value});
    try {
      final res = await _client.send(req).timeout(connectTimeout);
      final body = await res.stream.bytesToString();
      if (res.statusCode != 201 && res.statusCode != 200) throw _errorFrom(res.statusCode, body);
      final json = jsonDecode(body) as Map<String, Object?>;
      final ref = json['ref'], masked = json['masked'];
      if (ref is! String || masked is! String) throw const TransportException('server stored no secret');
      return (ref: ref, masked: masked);
    } on TransportException {
      rethrow;
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const TransportException('secret request timed out', timeout: true);
    } on Object catch (e) {
      throw TransportException('secret request failed: $e');
    }
  }

  @override
  Future<void> setClientName(String client, String name) async {
    final abort = Completer<void>();
    final req =
        http.AbortableRequest('PUT', _url('/clients/${Uri.encodeComponent(client)}'), abortTrigger: abort.future)
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({'name': name});
    try {
      final res = await _client.send(req).timeout(connectTimeout);
      final body = await res.stream.bytesToString();
      if (res.statusCode != 200) throw _errorFrom(res.statusCode, body);
    } on TransportException {
      rethrow;
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const TransportException('client name request timed out', timeout: true);
    } on Object catch (e) {
      throw TransportException('client name request failed: $e');
    }
  }

  @override
  Stream<StreamEvent> openStream(StreamOpen open) {
    final abort = Completer<void>();
    StreamSubscription<String>? sub;
    late final StreamController<StreamEvent> out;

    Future<void> connect() async {
      try {
        final query = {
          if (open.client != null) 'client': open.client!,
          if (open.from != null) 'from': '${open.from}',
          if (open.lastEventId != null && lastEventIdInQuery) 'lastEventId': '${open.lastEventId}',
          if (open.proto != null) 'proto': open.proto!,
        };
        final req =
            http.AbortableRequest('GET', _url('/events', query.isEmpty ? null : query), abortTrigger: abort.future)
              ..headers['Accept'] = 'text/event-stream'
              ..headers['Cache-Control'] = 'no-store';
        if (open.lastEventId != null && !lastEventIdInQuery) req.headers['Last-Event-ID'] = '${open.lastEventId}';
        final res = await _client.send(req).timeout(connectTimeout);
        if (res.statusCode != 200) throw _errorFrom(res.statusCode, await res.stream.bytesToString());
        final parser = SseParser();
        sub = utf8.decoder
            .bind(res.stream)
            .listen(
              (text) {
                if (out.isClosed) return;
                out.add(const PingEvent()); // any inbound byte proves the connection is alive
                try {
                  for (final m in parser.add(text)) {
                    final e = StreamEvent.parse(m.event, m.data);
                    if (e != null) out.add(e);
                  }
                } on FormatException catch (e) {
                  _fail(out, TransportException('bad event from server: ${e.message}'));
                }
              },
              onError: (Object e) => _fail(out, TransportException('stream error: $e')),
              onDone: () {
                if (!out.isClosed) unawaited(out.close());
              },
              cancelOnError: true,
            );
      } on TransportException catch (e) {
        _fail(out, e);
      } on TimeoutException {
        if (!abort.isCompleted) abort.complete();
        _fail(out, const TransportException('stream connect timed out', timeout: true));
      } on Object catch (e) {
        _fail(out, TransportException('stream connect failed: $e'));
      }
    }

    out = StreamController<StreamEvent>(
      onListen: () => unawaited(connect()),
      onCancel: () async {
        if (!abort.isCompleted) abort.complete();
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  static void _fail(StreamController<StreamEvent> c, TransportException e) {
    if (c.isClosed) return;
    c.addError(e);
    unawaited(c.close());
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

TransportException _errorFrom(int status, String body) {
  String? code;
  var message = 'HTTP $status';
  try {
    final j = jsonDecode(body);
    if (j is Map<String, Object?> && j['error'] is Map<String, Object?>) {
      final e = j['error']! as Map<String, Object?>;
      code = e['code'] as String?;
      message = '${e['message'] ?? message}';
    }
  } on FormatException {
    // not JSON: keep the generic message
  }
  return TransportException(message, statusCode: status, code: code);
}
