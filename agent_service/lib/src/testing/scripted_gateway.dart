/// A scripted stand-in for the Swift server's inner endpoints, speaking the
/// contract's `POST /inner/agent/llm/invoke` (SSE of
/// `{"code":0,"message":"","data":<LLMResultChunk>}`, error envelopes `-429`
/// and `-500`) and the file requests. Used by the tests (in-process) and by
/// `bin/fake_gateway.dart` (local manual runs).
///
/// Script JSON:
///
/// ```jsonc
/// {"calls": [                       // consumed in order, one per model call
///   {"delay_ms": 0,                 // before the first chunk (pings sent)
///    "chunk_delay_ms": 0,           // between chunks
///    "http_status": 200,            // non-200: a JSON error body instead
///    "http_body": {…},              // that body (default scripted_http_error)
///    "chunks": [{"text": "…", "reasoning": "…", "tool_calls": […],
///                "usage": {…}, "finish_reason": "stop", "delay_ms": 0}
///               /* or {"raw": <LLMResultChunk>} */],
///    "error": {"code": -429, "message": "…"},   // after the chunks
///    "hang": false,                 // keep the stream open after the chunks
///    "responses_events": [{"type": "response.output_item.done", "item": {…}},
///                         {"type": "response.completed", "response": {…}}]}],
///                // a call of `POST /inner/agent/responses` (the `codex`
///                // style's native wire): Responses events sent as they are;
///                // a `response.completed` without `reasoning` echoes the
///                // request's
///  "files": {"<file_id>": {"mime_type": "image/png", "size": 3, "content": "…"}},
///                // or "content_base64": "…" for binary content
///  "codex_run_token": "…",          // the official Codex runtime's entry
///  "codex_call_limit": 6}           // (see below)
/// ```
///
/// `POST /inner/agent/codex/v1/responses` stands in for the gateway's Codex
/// entry: `Authorization: Bearer <codex_run_token>`, every POST numbered from
/// 1 and answered with the next call's `responses_events` (a
/// `response.completed` without `id` gets one), and beyond
/// `codex_call_limit` a 429 with `error.type: usage_limit_reached`.
/// `GET /debug/codex-requests` lists what Codex sent (headers and bodies).
///
/// ```jsonc
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ScriptedChunk {
  ScriptedChunk({
    this.text,
    this.reasoning,
    this.toolCalls,
    this.usage,
    this.finishReason,
    this.delayMs = 0,
    this.raw,
  });

  final String? text;
  final String? reasoning;
  final List<Map<String, Object?>>? toolCalls;
  final Map<String, Object?>? usage;
  final String? finishReason;
  final int delayMs;
  final Map<String, Object?>? raw;

  static ScriptedChunk fromJson(Map<String, Object?> j) => ScriptedChunk(
    text: j['text'] as String?,
    reasoning: j['reasoning'] as String?,
    toolCalls: (j['tool_calls'] as List?)
        ?.map((e) => (e as Map).cast<String, Object?>())
        .toList(),
    usage: (j['usage'] as Map?)?.cast<String, Object?>(),
    finishReason: j['finish_reason'] as String?,
    delayMs: j['delay_ms'] as int? ?? 0,
    raw: (j['raw'] as Map?)?.cast<String, Object?>(),
  );

  Map<String, Object?> toChunk(String model, int index) =>
      raw ??
      {
        'model': model,
        'prompt_messages': <Object?>[],
        'system_fingerprint': null,
        'delta': {
          'index': index,
          'message': {
            'role': 'assistant',
            'content': text ?? '',
            'name': null,
            'tool_calls': toolCalls ?? const <Object?>[],
            'reasoning_content': ?reasoning,
          },
          'usage': usage,
          'finish_reason': finishReason,
        },
      };
}

class ScriptedCall {
  ScriptedCall({
    this.chunks = const [],
    this.delayMs = 0,
    this.chunkDelayMs = 0,
    this.httpStatus = 200,
    this.httpBody,
    this.error,
    this.hang = false,
    this.responseEvents,
  });

  final List<ScriptedChunk> chunks;
  final int delayMs;
  final int chunkDelayMs;
  final int httpStatus;

  /// The JSON body of a non-200 answer.
  final Map<String, Object?>? httpBody;
  final Map<String, Object?>? error;
  final bool hang;

  /// The Responses events of a `responses` call.
  final List<Map<String, Object?>>? responseEvents;

  /// A `responses` call answering [output] items, then
  /// `response.completed` with [usage] (Responses shape).
  factory ScriptedCall.responses(
    List<Map<String, Object?>> output, {
    Map<String, Object?>? usage,
    List<String> summary = const [],
    Map<String, Object?>? reasoningEcho,
  }) => ScriptedCall(
    responseEvents: [
      for (final t in summary)
        {'type': 'response.reasoning_summary_text.delta', 'delta': t},
      for (final item in output)
        {'type': 'response.output_item.done', 'item': item},
      {
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'reasoning': ?reasoningEcho,
          'usage':
              usage ??
              {
                'input_tokens': 100,
                'input_tokens_details': {'cached_tokens': 80},
                'output_tokens': 20,
                'output_tokens_details': {'reasoning_tokens': 12},
                'total_tokens': 120,
              },
        },
      },
    ],
  );

  /// A plain text answer with usage.
  factory ScriptedCall.text(
    String text, {
    Map<String, Object?>? usage,
    int delayMs = 0,
  }) => ScriptedCall(
    delayMs: delayMs,
    chunks: [
      ScriptedChunk(text: text),
      ScriptedChunk(usage: usage ?? defaultUsage(), finishReason: 'stop'),
    ],
  );

  /// One complete tool call (single delta) with usage.
  factory ScriptedCall.toolCall(
    String id,
    String name,
    Map<String, Object?> arguments, {
    String? text,
  }) => ScriptedCall(
    chunks: [
      ScriptedChunk(
        text: text,
        toolCalls: [
          toolCallDelta(id: id, name: name, arguments: jsonEncode(arguments)),
        ],
      ),
      ScriptedChunk(usage: defaultUsage(), finishReason: 'tool_calls'),
    ],
  );

  static ScriptedCall fromJson(Map<String, Object?> j) => ScriptedCall(
    chunks: [
      for (final c in (j['chunks'] as List?) ?? const [])
        ScriptedChunk.fromJson((c as Map).cast<String, Object?>()),
    ],
    delayMs: j['delay_ms'] as int? ?? 0,
    chunkDelayMs: j['chunk_delay_ms'] as int? ?? 0,
    httpStatus: j['http_status'] as int? ?? 200,
    httpBody: (j['http_body'] as Map?)?.cast<String, Object?>(),
    error: (j['error'] as Map?)?.cast<String, Object?>(),
    hang: j['hang'] as bool? ?? false,
    responseEvents: (j['responses_events'] as List?)
        ?.map((e) => (e as Map).cast<String, Object?>())
        .toList(),
  );
}

Map<String, Object?> defaultUsage({
  int prompt = 10,
  int completion = 5,
  int? reasoning,
}) => {
  'prompt_tokens': prompt,
  'completion_tokens': completion,
  'total_tokens': prompt + completion,
  'reasoning_tokens': ?reasoning,
  'currency': 'USD',
  'latency': 0.1,
};

Map<String, Object?> toolCallDelta({
  String? id,
  int? index,
  String? name,
  String? arguments,
}) => {
  'id': ?id,
  'index': ?index,
  'type': 'function',
  'function': {'name': name ?? '', 'arguments': arguments ?? ''},
};

/// One exchange with the gateway in arrival order, with what it answered:
/// a JSON body, the SSE envelopes of a model call, or file bytes.
class RecordedExchange {
  RecordedExchange(this.method, this.path, this.query, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> query;

  /// Request headers (lower-case names).
  final Map<String, String> headers;

  /// The JSON body, or the UTF-8 text of an upload PUT; null without a body.
  final Object? body;

  int? status;

  /// A JSON response body, or the text of a file download.
  Object? responseBody;

  /// The `data` envelopes of a model call's event stream, in sending order.
  List<Map<String, Object?>>? events;

  /// Whether the agent service closed a model call's stream before its end.
  bool closedByClient = false;
}

/// One request seen by the gateway.
class RecordedRequest {
  RecordedRequest(this.path, this.headers, this.body);
  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

/// What happened to one model call's connection.
class CallObservation {
  CallObservation(this.invocationId);
  final String invocationId;

  /// Completes when the agent service closed the connection early.
  final Completer<void> closedByClient = Completer();
  bool completed = false;
}

/// The gateway's Codex Responses entry (official Codex runtime).
const codexResponsesPath = '/inner/agent/codex/v1/responses';

class ScriptedGateway {
  ScriptedGateway({
    List<ScriptedCall> calls = const [],
    Map<String, Map<String, Object?>> files = const {},
    this.serviceKey,
    this.log,
    this.codexRunToken,
    this.codexCallLimit,
  }) : _calls = List.of(calls),
       files = Map.of(files);

  factory ScriptedGateway.fromJson(
    Map<String, Object?> script, {
    String? serviceKey,
    void Function(String)? log,
  }) => ScriptedGateway(
    calls: [
      for (final c in (script['calls'] as List?) ?? const [])
        ScriptedCall.fromJson((c as Map).cast<String, Object?>()),
    ],
    files: {
      for (final e in ((script['files'] as Map?) ?? const {}).entries)
        e.key as String: (e.value as Map).cast<String, Object?>(),
    },
    serviceKey: serviceKey,
    log: log,
    codexRunToken: script['codex_run_token'] as String?,
    codexCallLimit: script['codex_call_limit'] as int?,
  );

  final List<ScriptedCall> _calls;

  /// The run token the Codex entry expects (any bearer when null).
  final String? codexRunToken;

  /// POSTs the Codex entry answers before `usage_limit_reached`.
  final int? codexCallLimit;
  int codexCalls = 0;
  final Map<String, Map<String, Object?>> files;
  final String? serviceKey;
  final void Function(String)? log;

  final List<RecordedRequest> requests = [];

  /// Every exchange (also file downloads and upload PUTs) in arrival order.
  final List<RecordedExchange> exchanges = [];
  final List<CallObservation> observations = [];
  final Set<String> _invocationIds = {};
  final Map<String, List<int>> uploads = {};

  /// Status answered to upload PUTs (a failing upload when not 2xx).
  int uploadStatus = 200;
  HttpServer? _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}');

  /// Native model calls (raw Responses bodies) in arrival order.
  List<Map<String, Object?>> get responsesRequests => [
    for (final r in requests)
      if (r.path == '/inner/agent/responses') r.body,
  ];

  /// The headers of the native model calls (lower-case names).
  List<Map<String, String>> get responsesHeaders => [
    for (final r in requests)
      if (r.path == '/inner/agent/responses') r.headers,
  ];

  /// Model calls (`llm/invoke` bodies) in arrival order.
  List<Map<String, Object?>> get llmRequests => [
    for (final r in requests)
      if (r.path == '/inner/agent/llm/invoke') r.body,
  ];

  void enqueue(ScriptedCall call) => _calls.add(call);

  /// Base of the file URLs handed out: this gateway's own address when it
  /// listens on loopback, else none (relative URLs, which the agent service
  /// resolves against its inner base URL, as in a compose network).
  String _fileBase = '';

  Future<Uri> start({Object address = '127.0.0.1', int port = 0}) async {
    final server = _server = await HttpServer.bind(address, port);
    final loopback = address is InternetAddress
        ? address.isLoopback
        : address == '127.0.0.1' || address == 'localhost';
    _fileBase = loopback ? '$url' : '';
    server.listen((r) => unawaited(_handle(r)));
    return url;
  }

  Future<void> close() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final headers = <String, String>{};
    request.headers.forEach((k, v) => headers[k] = v.join(','));
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path.startsWith('/files/')) {
        final file = files[path.substring('/files/'.length)];
        final content = file?['content'];
        final b64 = file?['content_base64'];
        final bytes = b64 is String
            ? base64.decode(b64)
            : utf8.encode(content is String ? content : 'fake-bytes');
        final text = b64 is String
            ? '<${bytes.length} bytes>'
            : utf8.decode(bytes);
        exchanges.add(
          RecordedExchange(
              'GET',
              path,
              request.uri.queryParameters,
              headers,
              null,
            )
            ..status = 200
            ..responseBody = text,
        );
        res.headers.contentType = ContentType.binary;
        res.add(bytes);
        return await res.close();
      }
      if (request.method == 'PUT' && path.startsWith('/uploads/')) {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        exchanges.add(
          RecordedExchange(
            'PUT',
            path,
            request.uri.queryParameters,
            headers,
            utf8.decode(bytes, allowMalformed: true),
          )..status = uploadStatus,
        );
        if (uploadStatus >= 200 && uploadStatus < 300) {
          uploads[path.substring('/uploads/'.length)] = bytes;
        }
        res.statusCode = uploadStatus;
        return await res.close();
      }
      if (request.method == 'GET' && path == '/debug/codex-requests') {
        return await _jsonResponse(res, 200, {
          'requests': [
            for (final e in exchanges)
              if (e.path == codexResponsesPath)
                {
                  'headers': e.headers,
                  'body': e.body,
                  'status': e.status,
                  'closed_by_client': e.closedByClient,
                },
          ],
        });
      }
      final text = await utf8.decodeStream(request);
      final body = text.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(text) as Map).cast<String, Object?>();
      requests.add(RecordedRequest(path, headers, body));
      final exchange = RecordedExchange(
        request.method,
        path,
        request.uri.queryParameters,
        headers,
        text.isEmpty ? null : body,
      );
      exchanges.add(exchange);
      log?.call('${request.method} $path');
      if (path == codexResponsesPath) {
        return await _codexResponses(res, body, exchange);
      }
      if (serviceKey != null &&
          request.headers.value('authorization') != 'Bearer $serviceKey') {
        return await _jsonResponse(res, 401, {
          'error': 'unauthorized',
        }, exchange);
      }
      switch (path) {
        case '/inner/agent/llm/invoke':
          return await _invoke(res, body, exchange);
        case '/inner/agent/responses':
          return await _responses(res, body, exchange);
        case '/inner/agent/files/download-request':
          final id = body['file_id'];
          final f = files[id];
          if (f == null) {
            return await _jsonResponse(res, 404, {
              'error': 'file_not_found',
            }, exchange);
          }
          return await _jsonResponse(res, 200, {
            'url': '$_fileBase/files/$id?sig=${requests.length}',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
            'mime_type': f['mime_type'] ?? 'application/octet-stream',
            'size': f['size'] ?? 0,
          }, exchange);
        case '/inner/agent/files/upload-request':
          final id = 'up${requests.length}';
          return await _jsonResponse(res, 200, {
            'url': '$_fileBase/uploads/$id',
            'upload_id': id,
          }, exchange);
        default:
          return await _jsonResponse(res, 404, {
            'error': 'not_found',
          }, exchange);
      }
    } catch (e) {
      log?.call('fake gateway error: $e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _jsonResponse(
    HttpResponse res,
    int status,
    Map<String, Object?> body, [
    RecordedExchange? exchange,
  ]) async {
    exchange
      ?..status = status
      ..responseBody = body;
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await res.close();
  }

  Future<void> _invoke(
    HttpResponse res,
    Map<String, Object?> body,
    RecordedExchange exchange,
  ) async {
    final caller = (body['caller'] as Map?) ?? const {};
    final target = (body['target'] as Map?) ?? const {};
    final invocationId = caller['invocation_id'] as String? ?? '';
    // A retry is the same invocation with a higher `caller.attempt`.
    if (!_invocationIds.add('$invocationId#${caller['attempt'] ?? 1}')) {
      return _jsonResponse(res, 409, {
        'error': 'invocation_repeated',
        'message': 'invocation_id $invocationId was already used',
      }, exchange);
    }
    // Files in prompt messages must be `dify-sf-file:<id>` references to
    // files of the execution, as the Swift gateway checks them: its inputs
    // and, once received, its uploads (Swift's `grantFiles`).
    for (final m in (target['prompt_messages'] as List? ?? const [])) {
      final content = m is Map ? m['content'] : null;
      if (content is! List) continue;
      for (final part in content) {
        if (part is! Map || part['type'] == 'text') continue;
        final u = part['url'];
        final id = u is String && u.startsWith('dify-sf-file:')
            ? u.substring('dify-sf-file:'.length)
            : null;
        if (id == null || !(files.containsKey(id) || uploads.containsKey(id))) {
          return _jsonResponse(res, 422, {
            'error': 'file_error',
            'message': 'not a file of this execution: $u',
          }, exchange);
        }
      }
    }
    final obs = CallObservation(invocationId);
    observations.add(obs);
    if (_calls.isEmpty) {
      return _sse(
        res,
        obs,
        ScriptedCall(error: {'code': -500, 'message': 'script exhausted'}),
        '',
        exchange,
      );
    }
    final call = _calls.removeAt(0);
    if (call.httpStatus != 200) {
      obs.completed = true;
      return _jsonResponse(
        res,
        call.httpStatus,
        call.httpBody ??
            {
              'error': 'scripted_http_error',
              'message': 'scripted HTTP ${call.httpStatus}',
            },
        exchange,
      );
    }
    return _sse(res, obs, call, target['model'] as String? ?? '', exchange);
  }

  /// `POST /inner/agent/responses`: the body is the raw Responses request;
  /// `X-Agent-Call-Index`, `X-Agent-Invocation-ID` and `X-Agent-Attempt`
  /// describe the call. Answers the scripted Responses events of the next
  /// call, with `X-Dify-SF-Forwarded-Reasoning` set from the request.
  Future<void> _responses(
    HttpResponse res,
    Map<String, Object?> body,
    RecordedExchange exchange,
  ) async {
    final invocationId = exchange.headers['x-agent-invocation-id'] ?? '';
    final attempt = exchange.headers['x-agent-attempt'] ?? '';
    if (invocationId.isEmpty ||
        int.tryParse(exchange.headers['x-agent-call-index'] ?? '') == null ||
        int.tryParse(attempt) == null) {
      return _jsonResponse(res, 400, {
        'error': 'invalid_request',
        'message':
            'X-Agent-Call-Index, X-Agent-Invocation-ID and '
            'X-Agent-Attempt are required',
      }, exchange);
    }
    if (!_invocationIds.add('$invocationId#$attempt')) {
      return _jsonResponse(res, 409, {
        'error': 'invocation_repeated',
        'message': 'invocation_id $invocationId was already used',
      }, exchange);
    }
    String? unknown;
    void walk(Object? v) {
      if (v is Map) v.values.forEach(walk);
      if (v is List) v.forEach(walk);
      if (v is String && v.startsWith('dify-sf-file:')) {
        final id = v.substring('dify-sf-file:'.length);
        if (!(files.containsKey(id) || uploads.containsKey(id))) unknown = v;
      }
    }

    walk(body);
    if (unknown != null) {
      return _jsonResponse(res, 422, {
        'error': 'file_error',
        'message': 'not a file of this execution: $unknown',
      }, exchange);
    }
    final obs = CallObservation(invocationId);
    observations.add(obs);
    final call = _calls.isEmpty
        ? ScriptedCall(
            responseEvents: [
              {
                'type': 'response.failed',
                'response': {
                  'error': {
                    'code': 'server_error',
                    'message': 'script exhausted',
                  },
                },
              },
            ],
          )
        : _calls.removeAt(0);
    if (call.httpStatus != 200) {
      obs.completed = true;
      return _jsonResponse(
        res,
        call.httpStatus,
        call.httpBody ??
            {
              'error': 'scripted_http_error',
              'message': 'scripted HTTP ${call.httpStatus}',
            },
        exchange,
      );
    }
    final reasoning = body['reasoning'];
    final effort = reasoning is Map ? reasoning['effort'] : null;
    if (effort is String) {
      res.headers.set('X-Dify-SF-Forwarded-Reasoning', effort);
    }
    final events = [
      for (final e in call.responseEvents ?? const <Map<String, Object?>>[])
        if (e['type'] == 'response.completed' &&
            e['response'] is Map &&
            !(e['response'] as Map).containsKey('reasoning'))
          {
            ...e,
            'response': {...e['response'] as Map, 'reasoning': reasoning},
          }
        else
          e,
    ];
    return _sse(res, obs, call, '', exchange, responseEvents: events);
  }

  /// `POST /inner/agent/codex/v1/responses` (see the library comment).
  Future<void> _codexResponses(
    HttpResponse res,
    Map<String, Object?> body,
    RecordedExchange exchange,
  ) async {
    final token = codexRunToken;
    final auth = exchange.headers['authorization'] ?? '';
    if (!auth.startsWith('Bearer ') ||
        (token != null && auth != 'Bearer $token')) {
      return _jsonResponse(res, 401, {
        'error': {
          'type': 'invalid_request_error',
          'code': 'invalid_run_token',
          'message': 'unknown run token',
        },
      }, exchange);
    }
    final index = ++codexCalls;
    final limit = codexCallLimit;
    if (limit != null && index > limit) {
      return _jsonResponse(res, 429, {
        'error': {
          'type': 'usage_limit_reached',
          'code': 'agent_call_limit',
          'message': 'agent call limit reached',
        },
      }, exchange);
    }
    final obs = CallObservation('codex:$index');
    observations.add(obs);
    final call = _calls.isEmpty
        ? ScriptedCall(
            responseEvents: [
              {
                'type': 'response.failed',
                'response': {
                  'id': 'resp_$index',
                  'error': {
                    'code': 'server_error',
                    'message': 'script exhausted',
                  },
                },
              },
            ],
          )
        : _calls.removeAt(0);
    if (call.httpStatus != 200) {
      obs.completed = true;
      return _jsonResponse(
        res,
        call.httpStatus,
        call.httpBody ??
            {
              'error': {
                'type': 'server_error',
                'message': 'scripted HTTP ${call.httpStatus}',
              },
            },
        exchange,
      );
    }
    final events = [
      for (final e in call.responseEvents ?? const <Map<String, Object?>>[])
        if (e['response'] is Map && !(e['response'] as Map).containsKey('id'))
          {
            ...e,
            'response': {...e['response'] as Map, 'id': 'resp_$index'},
          }
        else
          e,
    ];
    return _sse(res, obs, call, '', exchange, responseEvents: events);
  }

  Future<void> _sse(
    HttpResponse res,
    CallObservation obs,
    ScriptedCall call,
    String model,
    RecordedExchange exchange, {
    List<Map<String, Object?>>? responseEvents,
  }) async {
    exchange
      ..status = 200
      ..events = [];
    res.statusCode = 200;
    res.headers
      ..contentType = ContentType('text', 'event-stream')
      ..chunkedTransferEncoding = true
      ..persistentConnection = false;
    // A detached socket reports the peer closing the connection, which an
    // HttpResponse does not reliably do while nothing is read from it.
    final socket = await res.detachSocket(writeHeaders: true);
    var closed = false;
    void markClosed() {
      if (closed) return;
      closed = true;
      // Our half of the connection, too; an open one keeps the isolate alive.
      socket.destroy();
      if (!obs.completed && !obs.closedByClient.isCompleted) {
        exchange.closedByClient = true;
        obs.closedByClient.complete();
      }
    }

    socket.listen(
      (_) {},
      onDone: markClosed,
      onError: (_) => markClosed(),
      cancelOnError: true,
    );

    Future<bool> send(String text) async {
      if (closed) return false;
      try {
        // Chunked framing written by hand on the detached socket.
        final bytes = utf8.encode(text);
        socket
          ..write('${bytes.length.toRadixString(16)}\r\n')
          ..add(bytes)
          ..write('\r\n');
        await socket.flush();
        return !closed;
      } catch (_) {
        markClosed();
        return false;
      }
    }

    // Waits while pinging, so a closed connection is noticed.
    Future<bool> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        if (!await send(': ping\n\n')) return false;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return !closed;
    }

    // An envelope is recorded when it is written to an open connection.
    Future<bool> envelope(int code, String message, Object? data) async {
      if (closed) return false;
      final e = {'code': code, 'message': message, 'data': data};
      exchange.events!.add(e);
      return send('data: ${jsonEncode(e)}\n\n');
    }

    if (!await wait(call.delayMs)) return;
    if (responseEvents != null) {
      for (var i = 0; i < responseEvents.length; i++) {
        final e = responseEvents[i];
        if (i > 0 && !await wait(call.chunkDelayMs)) return;
        exchange.events!.add(e);
        if (!await send('event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n')) {
          return;
        }
      }
    }
    for (var i = 0; responseEvents == null && i < call.chunks.length; i++) {
      final c = call.chunks[i];
      if (i > 0 && !await wait(call.chunkDelayMs + c.delayMs)) return;
      if (!await envelope(0, '', c.toChunk(model, i))) return;
    }
    final error = call.error;
    if (error != null) {
      final message = jsonEncode({
        'error_type': error['error_type'] ?? 'ScriptedError',
        'message': error['message'] ?? 'scripted error',
      });
      if (!await envelope(error['code'] as int? ?? -500, message, null)) {
        return;
      }
    }
    if (call.hang) {
      while (await wait(200)) {}
      return;
    }
    obs.completed = true;
    try {
      socket.write('0\r\n\r\n');
      await socket.close();
    } catch (_) {}
  }
}
