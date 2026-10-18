import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../model/app_registers.dart';
import '../model/document.dart';
import '../model/ops.dart';
import '../model/templates.dart';
import '../wire/messages.dart';
import 'fake_accounts.dart';
import 'fake_comments.dart';
import 'fake_server.dart';

/// The protocol served over real HTTP and SSE sockets, backed by in-memory [FakeServer]s (one per
/// document). Meant for exercising the real transport (and for running the CLI/app without the Swift
/// server). Its fault switches model the failures a real network produces: connections cut mid-stream,
/// streams that go silent without closing (half-open), swallowed responses, 5xx answers, chunked writes.
///
/// Accounts (protocol 1.8): with [accounts] it serves the account endpoints (`/v1/setup`, `/v1/auth/...`,
/// `/v1/account...`, `/v1/workspace/members...`, `/v1/activate...`) and every document endpoint requires
/// `Authorization: Bearer` (the event stream also `?access_token=`), with the reference server's roles and client-id
/// binding. Without [accounts] nothing is checked (pre-1.8 behaviour).
class HttpFakeServer {
  HttpFakeServer._(this._http, this.pingInterval, this.accounts);

  static Future<HttpFakeServer> start({
    int port = 0,
    Duration pingInterval = const Duration(seconds: 10),
    InternetAddress? address,
    FakeAccounts? accounts,
  }) async {
    final http = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    final s = HttpFakeServer._(http, pingInterval, accounts);
    http.listen(s._handle);
    return s;
  }

  final HttpServer _http;
  final Duration pingInterval;

  /// The workspace's accounts; null = no authentication.
  final FakeAccounts? accounts;
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

  FakeServer doc(String id, {String? template}) => docs.putIfAbsent(
    id,
    () => FakeServer(initial: Templates.named(template) ?? Templates.example(), accounts: accounts),
  );

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
          ..headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
          ..headers.set(
            'Access-Control-Allow-Headers',
            'Content-Type, Accept, Authorization, Last-Event-ID, Cache-Control',
          )
          ..headers.set('Access-Control-Max-Age', '600');
        return await req.response.close();
      }
      final seg = req.uri.pathSegments;
      if (req.method == 'GET' && req.uri.path == '/healthz') return await _json(req, 200, {'status': 'ok'});
      if (accounts != null && seg.length >= 2 && seg[0] == 'v1' && seg[1] != 'docs') return await _auth(req, seg);
      if (seg.length >= 2 && seg[0] == 'v1' && seg[1] == 'docs') {
        // Protocol 1.8: who is asking (401 without a valid token; 403 for writes by read-only roles).
        String? account;
        if (accounts != null) {
          final isStream = seg.length == 4 && seg[3] == 'events';
          final token = _bearer(req) ?? (isStream ? req.uri.queryParameters['access_token'] : null);
          final write = _isWrite(req.method, seg);
          final exportSecret =
              seg.length == 4 && seg[3] == 'export' && req.uri.queryParameters['include_secret'] == 'true';
          try {
            account = accounts!.principal(token, edit: write, privileged: exportSecret).id;
          } on FakeAuthError catch (e) {
            await utf8.decoder.bind(req).join();
            return await _error(req, e.status, e.code, e.message);
          }
        }
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
        if (seg.length == 4 && seg[3] == 'ops' && req.method == 'POST') return await _ops(req, seg[2], account);
        if (seg.length == 4 && seg[3] == 'clients' && req.method == 'POST') {
          final d = docs[seg[2]];
          if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
          final body = await utf8.decoder.bind(req).join();
          if (account != null) {
            final id = d.issueClientId(account: account);
            return await _json(req, 201, {'client': id, 'account': account, 'name': accounts!.byId[account]!.name});
          }
          final (:name, :bad) = _name(body);
          if (bad) return await _error(req, 400, 'bad_request', 'name must be 1-64 bytes without control characters');
          return await _json(req, 201, {'client': d.issueClientId(name: name), 'name': ?name});
        }
        if (seg.length == 4 && seg[3] == 'clients' && req.method == 'GET') {
          final d = docs[seg[2]];
          if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
          return await _json(req, 200, {'clients': d.directory()});
        }
        if (seg.length == 5 && seg[3] == 'clients' && req.method == 'PUT') {
          final d = docs[seg[2]];
          if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
          final body = await utf8.decoder.bind(req).join();
          if (account != null) {
            try {
              d.requireOwnClient(seg[4], account);
            } on FakeAuthError catch (e) {
              return await _error(req, e.status, e.code, e.message);
            }
            return await _json(req, 200, {'client': seg[4], 'account': account, 'name': accounts!.byId[account]!.name});
          }
          final (:name, :bad) = _name(body);
          if (bad || name == null) {
            return await _error(req, 400, 'bad_request', 'name must be 1-64 bytes without control characters');
          }
          d.setClientName(seg[4], name);
          return await _json(req, 200, {'client': seg[4], 'name': name});
        }
        if (seg.length == 4 && seg[3] == 'events' && req.method == 'GET') return await _events(req, seg[2], account);
        if (seg.length == 4 && seg[3] == 'secrets' && req.method == 'POST') return await _storeSecret(req, seg[2]);
        if (seg.length >= 4 && seg.length <= 7 && seg[3] == 'comments') return await _comments(req, seg, account);
        if (seg.length == 4 && seg[3] == 'meta' && req.method == 'GET') {
          final d = docs[seg[2]];
          if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
          return await _json(req, 200, appMeta(seg[2], d.doc));
        }
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

  /// `POST /v1/docs/{doc}/secrets` (protocol 1.7): `{"value": "..."}` -> `201 {"ref", "masked"}`.
  Future<void> _storeSecret(HttpRequest req, String docId) async {
    final body = await utf8.decoder.bind(req).join();
    Object? value;
    try {
      final json = jsonDecode(body);
      if (json is Map<String, Object?>) value = json['value'];
    } on FormatException {
      value = null;
    }
    if (value is! String) return await _error(req, 400, 'bad_request', 'body must be {"value": string}');
    final d = docs[docId];
    if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
    final (:ref, :masked) = d.storeSecret(value);
    await _json(req, 201, {'ref': ref, 'masked': masked});
  }

  /// The canvas comments routes (`/v1/docs/{doc}/comments...`), on the document's [FakeServer.comments].
  Future<void> _comments(HttpRequest req, List<String> seg, String? account) async {
    final d = docs[seg[2]];
    final text = await utf8.decoder.bind(req).join();
    if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
    Map<String, Object?> body = const {};
    if (text.trim().isNotEmpty) {
      try {
        final json = jsonDecode(text);
        if (json is! Map<String, Object?>) return await _error(req, 400, 'bad_request', 'body must be an object');
        body = json;
      } on FormatException {
        return await _error(req, 400, 'bad_request', 'malformed JSON');
      }
    }
    // 1.8: the author is the caller's account; without accounts, the `client` of the body or query.
    final c = d.comments, m = req.method;
    final client = account ?? body['client'] as String?, query = account ?? req.uri.queryParameters['client'];
    final mentions = body.containsKey('mentioned_user_ids') ? body['mentioned_user_ids'] : body['mentioned_client_ids'];
    final id = seg.length > 4 ? seg[4] : null;
    try {
      switch ((seg.length, m)) {
        case (4, 'GET'):
          return await _json(req, 200, {'comments': c.list()});
        case (5, 'GET') when id == 'mention-users':
          final a = accounts;
          return await _json(req, 200, {
            'users': a == null
                ? [
                    for (final e in d.names.entries) {'id': e.key, 'name': e.value, 'email': '', 'role': ''},
                  ]
                : a.mentionUsers(_bearer(req)),
          });
        case (4, 'POST'):
          return await _json(
            req,
            201,
            c.create(
              client: client,
              x: body['position_x'],
              y: body['position_y'],
              content: body['content'],
              mentions: mentions,
            ),
          );
        case (5, 'GET'):
          return await _json(req, 200, c.get(id!));
        case (5, 'PUT'):
          return await _json(
            req,
            200,
            c.update(
              id!,
              client: client,
              content: body['content'],
              x: body['position_x'],
              y: body['position_y'],
              mentions: mentions,
            ),
          );
        case (5, 'DELETE'):
          c.delete(id!, client: query);
          req.response.statusCode = 204;
          return await req.response.close();
        case (6, 'POST') when seg[5] == 'resolve':
          return await _json(req, 200, c.resolve(id!, client: client));
        case (6, 'POST') when seg[5] == 'replies':
          return await _json(
            req,
            201,
            c.reply(id!, client: client, content: body['content'], mentions: mentions),
          );
        case (7, 'PUT') when seg[5] == 'replies':
          return await _json(
            req,
            200,
            c.editReply(id!, seg[6], client: client, content: body['content'], mentions: mentions),
          );
        case (7, 'DELETE') when seg[5] == 'replies':
          c.deleteReply(id!, seg[6], client: query);
          req.response.statusCode = 204;
          return await req.response.close();
      }
    } on FakeCommentsError catch (e) {
      return await _error(req, e.status, e.code, e.message);
    } on TypeError {
      return await _error(req, 400, 'bad_request', 'malformed body');
    }
    await _error(req, 404, 'not_found', 'no such route');
  }

  /// `GET /v1/docs/{doc}/meta` for a document that was not imported: the defaults of the reference server, with the
  /// variables and features of the document at head (protocol 1.7; secrets masked, never a `secret_ref`).
  static Map<String, Object?> appMeta(String docId, Document doc) => {
    'app': {
      'name': docId,
      'mode': 'workflow',
      'description': '',
      'icon': '🤖',
      'icon_background': '#FFEAD5',
      'use_icon_as_answer_icon': false,
    },
    'kind': 'app',
    'version': '0.3.1',
    'dependencies': const <Object?>[],
    AppRegisters.environmentVariables: [
      for (final v in AppRegisters.variables(doc, AppRegisters.environmentVariables))
        {...v}..remove(AppRegisters.secretRef),
    ],
    AppRegisters.conversationVariables: AppRegisters.variables(doc, AppRegisters.conversationVariables),
    AppRegisters.features: AppRegisters.featuresOf(doc),
  };

  Future<void> _createDoc(HttpRequest req, String? id) async {
    final body = await utf8.decoder.bind(req).join();
    final template = body.isEmpty ? null : (jsonDecode(body) as Map<String, Object?>)['template'] as String?;
    final docId = id ?? 'doc-${_random.nextInt(1 << 30).toRadixString(36)}';
    final existed = docs.containsKey(docId);
    final d = doc(docId, template: template);
    await _json(req, existed ? 200 : 201, {'id': docId, 'head': d.head, 'created': !existed});
  }

  Future<void> _ops(HttpRequest req, String docId, String? account) async {
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
    if (account != null) {
      try {
        d.requireOwnClient(request.client, account);
      } on FakeAuthError catch (e) {
        return await _error(req, e.status, e.code, e.message);
      }
    }
    final response = d.submit(request);
    if (postDelay > Duration.zero) await Future<void>.delayed(postDelay);
    if (swallowResponses) return; // the client will time out
    if (failNextPosts > 0) {
      failNextPosts--;
      return await _error(req, 503, 'unavailable', 'commit outcome uncertain');
    }
    await _json(req, 200, response.toJson());
  }

  Future<void> _events(HttpRequest req, String docId, String? account) async {
    final d = docs[docId];
    if (d == null) return await _error(req, 404, 'not_found', 'unknown document');
    final client = req.uri.queryParameters['client'];
    if (account != null && client != null) {
      try {
        d.requireOwnClient(client, account, bind: false);
      } on FakeAuthError catch (e) {
        return await _error(req, e.status, e.code, e.message);
      }
    }
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

    final proto = req.uri.queryParameters['proto'];
    void onCommit(LogEntry e) {
      if (!StreamCompat.streamCarries(e.op, proto)) {
        // An older client cannot decode this op: end its stream (it reconnects and is caught up with a snapshot).
        closed = true;
        markGone();
        return;
      }
      write(_frame('commit', e.seq, e.toJson()));
    }

    write('retry: 1000\n\n');
    final from = int.tryParse(req.uri.queryParameters['from'] ?? '');
    final catchUp = d.catchUp(lastEventId: last, client: req.uri.queryParameters['client'], from: from, proto: proto);
    for (final ev in catchUp) {
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
        case PingEvent() || CommentsEvent():
          break;
      }
    }
    d.addListener(onCommit);
    // Comment notifications: no `id:` (they never move the resume point).
    void onComments(CommentsEvent e) =>
        write(_frame('comments', null, {'comment': e.comment, 'action': e.action.name}));
    d.comments.addListener(onComments);
    final ping = Timer.periodic(pingInterval, (_) => write(': ping\n\n'));
    try {
      await gone.future;
    } on Object {
      // client went away
    } finally {
      closed = true;
      ping.cancel();
      d.removeListener(onCommit);
      d.comments.removeListener(onComments);
      _streams.remove(socket);
      socket.destroy();
    }
  }

  /// The account endpoints (with [accounts]).
  Future<void> _auth(HttpRequest req, List<String> seg) async {
    final a = accounts!;
    final text = await utf8.decoder.bind(req).join();
    Map<String, Object?> body = const {};
    if (text.trim().isNotEmpty) {
      try {
        final json = jsonDecode(text);
        if (json is Map<String, Object?>) body = json;
      } on FormatException {
        return await _error(req, 400, 'bad_request', 'malformed JSON');
      }
    }
    final token = _bearer(req), m = req.method, path = seg.skip(1).join('/');
    try {
      switch ((m, path)) {
        case ('GET', 'setup'):
          return await _json(req, 200, {'step': a.setupStatus()});
        case ('POST', 'setup'):
          return await _json(
            req,
            201,
            a.setup(
              email: body['email'],
              name: body['name'],
              password: body['password'],
              language: body['interface_language'] ?? body['language'],
              timezone: body['timezone'],
            ),
          );
        case ('POST', 'auth/login'):
          return await _json(
            req,
            200,
            a.login(email: body['email'], password: body['password'], inviteToken: body['invite_token']),
          );
        case ('POST', 'auth/refresh'):
          return await _json(req, 200, a.refresh(body['refresh_token']));
        case ('POST', 'auth/logout'):
          a.logout(token);
          req.response.statusCode = 204;
          return await req.response.close();
        case ('GET', 'account'):
          return await _json(req, 200, a.account(token));
        case ('PUT', 'account/name'):
          return await _json(req, 200, a.updateName(token, body['name']));
        case ('PUT', 'account/password'):
          a.updatePassword(
            token,
            password: body['password'],
            newPassword: body['new_password'],
            repeatNewPassword: body['repeat_new_password'],
          );
          req.response.statusCode = 204;
          return await req.response.close();
        case ('GET', 'workspace/members'):
          return await _json(req, 200, {'accounts': a.members(token)});
        case ('POST', 'workspace/members/invite-email'):
          return await _json(req, 201, {
            'invitation_results': a.invite(token, emails: body['emails'], role: body['role']),
          });
        case ('POST', 'activate/check'):
          return await _json(req, 200, a.checkInvitation(body['token']));
        case ('GET', 'activate/check'):
          return await _json(req, 200, a.checkInvitation(req.uri.queryParameters['token']));
        case ('POST', 'activate'):
          return await _json(
            req,
            200,
            a.activate(
              token: body['token'],
              name: body['name'],
              password: body['password'],
              interfaceLanguage: body['interface_language'],
              timezone: body['timezone'],
            ),
          );
      }
      if (seg.length == 5 && seg[1] == 'workspace' && seg[2] == 'members' && seg[4] == 'update-role' && m == 'PUT') {
        a.updateRole(token, seg[3], body['role']);
        return await _json(req, 200, {'result': 'success'});
      }
      if (seg.length == 4 && seg[1] == 'workspace' && seg[2] == 'members' && m == 'DELETE') {
        a.removeMember(token, seg[3]);
        return await _json(req, 200, {'result': 'success'});
      }
    } on FakeAuthError catch (e) {
      return await _error(req, e.status, e.code, e.message);
    }
    await _error(req, 404, 'not_found', 'no such route');
  }

  static String? _bearer(HttpRequest req) {
    final h = req.headers.value('authorization');
    if (h == null || !h.toLowerCase().startsWith('bearer ')) return null;
    final t = h.substring(7).trim();
    return t.isEmpty ? null : t;
  }

  /// Whether a document request needs the edit role (protocol 1.8).
  static bool _isWrite(String method, List<String> seg) {
    if (seg.length == 2) return method == 'POST'; // create
    if (seg.length == 3) return method == 'PUT' || (seg[2] == 'import' && method == 'POST');
    final what = seg[3];
    if (what == 'clients' || what == 'events' || what == 'snapshot' || what == 'meta' || what == 'export') return false;
    if (what == 'comments') return method != 'GET';
    return method != 'GET'; // ops, secrets, import
  }

  static String _frame(String event, int? id, Object? data) =>
      '${id == null ? '' : 'id: $id\n'}event: $event\ndata: ${jsonEncode(data)}\n\n';

  /// The optional `name` of a clients request body (protocol 1.3), validated like the reference server.
  static ({String? name, bool bad}) _name(String body) {
    if (body.trim().isEmpty) return (name: null, bad: false);
    final m = jsonDecode(body);
    final n = m is Map<String, Object?> ? m['name'] : null;
    if (n == null) return (name: null, bad: false);
    if (n is! String || n.isEmpty || utf8.encode(n).length > 64 || n.runes.any((r) => r < 0x20 || r == 0x7f)) {
      return (name: null, bad: true);
    }
    return (name: n, bad: false);
  }

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
