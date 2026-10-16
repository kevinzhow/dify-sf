import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../model/ops.dart';
import '../model/templates.dart';
import '../wire/messages.dart';
import 'fake_server.dart';

/// The protocol served over real HTTP and SSE sockets, backed by in-memory [FakeServer]s (one per
/// document). Meant for exercising the real transport (and for running the CLI/app without the Swift
/// server). Its fault switches model the failures a real network produces: connections cut mid-stream,
/// streams that go silent without closing (half-open), swallowed responses, 5xx answers, chunked writes.
class HttpFakeServer {
  HttpFakeServer._(this._http, this.pingInterval);

  static Future<HttpFakeServer> start({
    int port = 0,
    Duration pingInterval = const Duration(seconds: 10),
    InternetAddress? address,
  }) async {
    final http = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    final s = HttpFakeServer._(http, pingInterval);
    http.listen(s._handle);
    return s;
  }

  final HttpServer _http;
  final Duration pingInterval;
  final Map<String, FakeServer> docs = {};
  final Random _random = Random(7);

  Uri get url => Uri.parse('http://${_http.address.address}:${_http.port}');

  // ---- fault switches ----------------------------------------------------------------------------

  /// Streams keep their socket open but write nothing (no events, no pings): a half-open connection. A
  /// stream that had events swallowed stays silent for good (as a stalled TCP connection would).
  bool stallStreams = false;

  /// Process POSTs but never answer them.
  bool swallowResponses = false;

  /// Answer this many POSTs with 503 *after* committing them (uncertain outcome), then behave.
  int failNextPosts = 0;

  /// Write stream frames in tiny random chunks (tests the SSE parser's reassembly).
  bool fragmentWrites = false;

  /// Extra delay before every POST answer.
  Duration postDelay = Duration.zero;

  // ---- observations ------------------------------------------------------------------------------

  /// `Last-Event-ID` / `lastEventId` of every stream request, in order (null = none).
  final List<int?> streamResumePoints = [];
  int postCount = 0;
  final List<Socket> _streams = [];

  FakeServer doc(String id, {String? template}) =>
      docs.putIfAbsent(id, () => FakeServer(initial: Templates.named(template) ?? Templates.example()));

  /// Abruptly closes every open stream socket.
  void dropStreams() {
    for (final s in List.of(_streams)) {
      s.destroy();
    }
    _streams.clear();
  }

  Future<void> close() async {
    dropStreams();
    await _http.close(force: true);
  }

  // ---- routing -----------------------------------------------------------------------------------

  /// Number of CORS preflight (`OPTIONS`) requests answered.
  int preflights = 0;

  /// Origins other than this one get no CORS headers (like a server with a restrictive allow-list). null = any.
  String? allowedOrigin;

  void _cors(HttpRequest req) {
    final origin = req.headers.value('origin');
    if (origin == null || (allowedOrigin != null && origin != allowedOrigin)) return;
    req.response.headers
      ..set('Access-Control-Allow-Origin', origin)
      ..set('Vary', 'Origin');
  }

  String _corsHeaderLine(HttpRequest req) {
    final origin = req.headers.value('origin');
    if (origin == null || (allowedOrigin != null && origin != allowedOrigin)) return '';
    return 'Access-Control-Allow-Origin: $origin\r\nVary: Origin\r\n';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      _cors(req);
      if (req.method == 'OPTIONS') {
        preflights++;
        req.response
          ..statusCode = 204
          ..headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
          ..headers.set('Access-Control-Allow-Headers', 'Content-Type, Accept, Last-Event-ID, Cache-Control')
          ..headers.set('Access-Control-Max-Age', '600');
        return await req.response.close();
      }
      final seg = req.uri.pathSegments;
      if (req.method == 'GET' && req.uri.path == '/healthz') return await _json(req, 200, {'status': 'ok'});
      if (seg.length >= 2 && seg[0] == 'v1' && seg[1] == 'docs') {
        if (seg.length == 2 && req.method == 'POST') return await _createDoc(req, null);
        if (seg.length == 3 && req.method == 'PUT') return await _createDoc(req, seg[2]);
        if (seg.length == 3 && req.method == 'GET') {
          final d = docs[seg[2]];
          return d == null
              ? await _error(req, 404, 'not_found', 'unknown document')
              : await _json(req, 200, {'id': seg[2], 'head': d.head});
        }
        if (seg.length == 4 && seg[3] == 'snapshot' && req.method == 'GET') {
          final d = docs[seg[2]];
          if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
          return await _json(req, 200, {'seq': d.head, 'doc': d.doc.toJson()});
        }
        if (seg.length == 4 && seg[3] == 'ops' && req.method == 'POST') return await _ops(req, seg[2]);
        if (seg.length == 4 && seg[3] == 'clients' && req.method == 'POST') {
          final d = docs[seg[2]];
          if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
          return await _json(req, 201, {'client': d.issueClientId()});
        }
        if (seg.length == 4 && seg[3] == 'events' && req.method == 'GET') return await _events(req, seg[2]);
      }
      await _error(req, 404, 'not_found', 'no such route');
    } on Object catch (e) {
      try {
        await _error(req, 500, 'internal', '$e');
      } on Object {
        // socket already gone
      }
    }
  }

  Future<void> _createDoc(HttpRequest req, String? id) async {
    final body = await utf8.decoder.bind(req).join();
    final template = body.isEmpty ? null : (jsonDecode(body) as Map<String, Object?>)['template'] as String?;
    final docId = id ?? 'doc-${_random.nextInt(1 << 30).toRadixString(36)}';
    final existed = docs.containsKey(docId);
    final d = doc(docId, template: template);
    await _json(req, existed ? 200 : 201, {'id': docId, 'head': d.head, 'created': !existed});
  }

  Future<void> _ops(HttpRequest req, String docId) async {
    final d = docs[docId];
    if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
    final text = await utf8.decoder.bind(req).join();
    postCount++;
    final Map<String, Object?> json;
    try {
      json = jsonDecode(text) as Map<String, Object?>;
    } on FormatException {
      return await _error(req, 400, 'bad_request', 'malformed JSON');
    }
    final ops = (json['ops']! as List<Object?>).cast<Map<String, Object?>>();
    final request = SubmitRequest(
      client: json['client']! as String,
      floor: json['floor'] as int?,
      resolveFrom: json['resolveFrom'] as int?,
      ops: [
        for (final o in ops) OutgoingOp(cseq: o['cseq']! as int, base: o['base']! as int, op: Op.fromJson(o['op'])),
      ],
    );
    final response = d.submit(request);
    if (postDelay > Duration.zero) await Future<void>.delayed(postDelay);
    if (swallowResponses) return; // the client will time out
    if (failNextPosts > 0) {
      failNextPosts--;
      return await _error(req, 503, 'unavailable', 'commit outcome uncertain');
    }
    await _json(req, 200, response.toJson());
  }

  Future<void> _events(HttpRequest req, String docId) async {
    final d = docs[docId];
    if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
    final header = req.headers.value('last-event-id');
    final last = int.tryParse(header ?? req.uri.queryParameters['lastEventId'] ?? '');
    streamResumePoints.add(last);
    // Take over the socket: SSE is a raw `Connection: close` body, and a detached socket can be reset or
    // left silent (half-open) at will.
    final socket = await req.response.detachSocket(writeHeaders: false);
    socket.write(
      'HTTP/1.1 200 OK\r\n'
      'Content-Type: text/event-stream; charset=utf-8\r\n'
      'Cache-Control: no-store\r\n'
      'X-Accel-Buffering: no\r\n'
      '${_corsHeaderLine(req)}'
      'Connection: close\r\n\r\n',
    );
    _streams.add(socket);
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {})); // write errors after a reset are expected
    final gone = Completer<void>();
    void markGone() {
      if (!gone.isCompleted) gone.complete();
    }

    socket.listen((_) {}, onDone: markGone, onError: (Object _) => markGone(), cancelOnError: true);
    var closed = false;
    var dead = false; // bytes were swallowed: like a stalled TCP connection, nothing more ever arrives
    void write(String frame) {
      if (closed || dead) return;
      if (stallStreams) {
        if (!frame.startsWith(':')) dead = true; // a swallowed keep-alive is harmless; a swallowed event is not
        return;
      }
      try {
        if (fragmentWrites) {
          var i = 0;
          while (i < frame.length) {
            final n = 1 + _random.nextInt(7);
            socket.write(frame.substring(i, min(frame.length, i + n)));
            i += n;
          }
        } else {
          socket.write(frame);
        }
      } on Object {
        closed = true;
      }
    }

    void onCommit(LogEntry e) => write(_frame('commit', e.seq, e.toJson()));
    write('retry: 1000\n\n');
    final from = int.tryParse(req.uri.queryParameters['from'] ?? '');
    for (final ev in d.catchUp(lastEventId: last, client: req.uri.queryParameters['client'], from: from)) {
      switch (ev) {
        case SnapshotEvent():
          write(
            _frame('snapshot', ev.seq, {
              'seq': ev.seq,
              'doc': ev.doc.toJson(),
              'committed': {for (final e in ev.committed.entries) '${e.key}': e.value},
            }),
          );
        case CommitEvent(:final entry):
          onCommit(entry);
        case ReadyEvent(:final head):
          write(_frame('ready', null, {'head': head}));
        case PingEvent():
          break;
      }
    }
    d.addListener(onCommit);
    final ping = Timer.periodic(pingInterval, (_) => write(': ping\n\n'));
    try {
      await gone.future;
    } on Object {
      // client went away
    } finally {
      closed = true;
      ping.cancel();
      d.removeListener(onCommit);
      _streams.remove(socket);
      socket.destroy();
    }
  }

  static String _frame(String event, int? id, Object? data) =>
      '${id == null ? '' : 'id: $id\n'}event: $event\ndata: ${jsonEncode(data)}\n\n';

  Future<void> _json(HttpRequest req, int status, Object? body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _error(HttpRequest req, int status, String code, String message) => _json(req, status, {
    'error': {'code': code, 'message': message},
  });
}
