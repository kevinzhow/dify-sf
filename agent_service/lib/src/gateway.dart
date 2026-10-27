/// Client of the Swift server's inner endpoints for the agent service:
/// `POST /inner/agent/llm/invoke` (SSE of Dify `LLMResultChunk`s) and the
/// file requests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// A failure of an inner call, classified by the run's `error_type`.
class GatewayException implements Exception {
  GatewayException(this.errorType, this.message);

  /// `model_error`, `model_quota` or `file_error`.
  final String errorType;
  final String message;

  @override
  String toString() => 'GatewayException($errorType: $message)';
}

/// A non-200 answer of `llm/invoke` (the `codex` style's retries read the
/// status, the error code and `Retry-After`).
class GatewayHttpException extends GatewayException {
  GatewayHttpException(
    super.errorType,
    super.message, {
    required this.status,
    this.errorCode,
    this.retryAfter,
  });
  final int status;
  final String? errorCode;
  final String? retryAfter;
}

/// An error envelope in the stream of `llm/invoke` (`code` -429 or -500;
/// [difyErrorType] from its message).
class GatewayEnvelopeException extends GatewayException {
  GatewayEnvelopeException(
    super.errorType,
    super.message, {
    required this.code,
    this.difyErrorType,
  });
  final int code;
  final String? difyErrorType;
}

/// Per-run client of the inner endpoints. [close] aborts every call in
/// flight (the Swift server then cancels the plugin call on its side).
class InnerClient {
  InnerClient({
    required this.baseUrl,
    required this.serviceKey,
    required this.runToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String serviceKey;
  final String? runToken;
  final http.Client _client;
  final Set<String> _invocationIds = {};
  bool _closed = false;

  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }

  Uri _url(String path) {
    final base = baseUrl.toString();
    return Uri.parse(
      base.endsWith('/')
          ? '${base.substring(0, base.length - 1)}$path'
          : '$base$path',
    );
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $serviceKey',
    'X-Agent-Run-Token': ?runToken,
    'Content-Type': 'application/json; charset=utf-8',
  };

  /// Streams the `data` of every chunk envelope of one model call. An error
  /// envelope (`-429`, `-500`) or a non-200 answer throws [GatewayException].
  /// An `invocation_id` is never sent twice.
  Stream<Map<String, Object?>> invokeLlm(Map<String, Object?> body) async* {
    final caller = body['caller'] as Map;
    final invocationId = caller['invocation_id'] as String;
    // A retry (the `codex` style) is the same invocation with a higher
    // `caller.attempt` (absent = 1).
    final key = '$invocationId#${caller['attempt'] ?? 1}';
    if (!_invocationIds.add(key)) {
      throw StateError('invocation_id $invocationId was already sent');
    }
    final request = http.Request('POST', _url('/inner/agent/llm/invoke'))
      ..headers.addAll(_headers)
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode(body);
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final text = await response.stream.bytesToString();
      throw GatewayHttpException(
        switch (response.statusCode) {
          429 => 'model_quota',
          422 when _errorCode(text) == 'file_error' => 'file_error',
          // The request's files exceed the gateway's byte budget.
          413 => 'file_error',
          _ => 'model_error',
        },
        'model gateway answered HTTP ${response.statusCode}: ${_short(text)}',
        status: response.statusCode,
        errorCode: _errorCodeLoose(text),
        retryAfter: response.headers['retry-after'],
      );
    }
    await for (final data in parseSse(response.stream)) {
      final Object? envelope;
      try {
        envelope = jsonDecode(data);
      } on FormatException {
        throw GatewayException('model_error', 'malformed gateway event');
      }
      if (envelope is! Map) {
        throw GatewayException('model_error', 'malformed gateway event');
      }
      final code = envelope['code'];
      if (code == 0) {
        final chunk = envelope['data'];
        if (chunk is Map) yield chunk.cast<String, Object?>();
        continue;
      }
      throw GatewayEnvelopeException(
        code == -429 ? 'model_quota' : 'model_error',
        _errorMessage(envelope['message']),
        code: code is int ? code : -500,
        difyErrorType: _difyErrorType(envelope['message']),
      );
    }
  }

  /// `POST /inner/agent/responses` (the `codex` style's native wire): the
  /// raw Responses request body, unchanged, goes to the provider through
  /// the Swift server, whose answer is the provider's event stream
  /// unchanged. The call is described by `X-Agent-Call-Index`,
  /// `X-Agent-Invocation-ID` (`<run_id>:<call_index>`) and `X-Agent-Attempt`
  /// (1, then one more per retry); the identity is the run token. Returns
  /// the response headers and the `data` of every event. A non-200 answer
  /// throws [GatewayHttpException]. An attempt is never sent twice.
  Future<({Map<String, String> headers, Stream<String> events})> openResponses(
    Map<String, Object?> body, {
    required int callIndex,
    required String invocationId,
    required int attempt,
  }) async {
    if (!_invocationIds.add('$invocationId#$attempt')) {
      throw StateError(
        'invocation_id $invocationId attempt $attempt was already sent',
      );
    }
    final request = http.Request('POST', _url('/inner/agent/responses'))
      ..headers.addAll(_headers)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['X-Agent-Call-Index'] = '$callIndex'
      ..headers['X-Agent-Invocation-ID'] = invocationId
      ..headers['X-Agent-Attempt'] = '$attempt'
      ..body = jsonEncode(body);
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final text = await response.stream.bytesToString();
      throw GatewayHttpException(
        switch (response.statusCode) {
          429 => 'model_quota',
          422 when _errorCodeLoose(text) == 'file_error' => 'file_error',
          413 => 'file_error',
          _ => 'model_error',
        },
        'responses gateway answered HTTP ${response.statusCode}: ${_short(text)}',
        status: response.statusCode,
        errorCode: _errorCodeLoose(text),
        retryAfter: response.headers['retry-after'],
      );
    }
    return (headers: response.headers, events: parseSse(response.stream));
  }

  /// `POST /inner/agent/files/download-request`.
  Future<Map<String, Object?>> downloadRequest(String fileId) =>
      _postJson('/inner/agent/files/download-request', {'file_id': fileId});

  /// `POST /inner/agent/files/upload-request`.
  Future<Map<String, Object?>> uploadRequest({
    required String filename,
    required String mimeType,
    required int size,
  }) => _postJson('/inner/agent/files/upload-request', {
    'filename': filename,
    'mime_type': mimeType,
    'size': size,
  });

  /// Resolves a URL from a file request against the inner base URL.
  Uri resolveFileUrl(String url) => baseUrl.resolve(url);

  /// GETs the bytes behind a signed download URL (at most [maxBytes]).
  Future<List<int>> downloadBytes(String url, int maxBytes) async {
    final http.StreamedResponse response;
    try {
      response = await _client.send(http.Request('GET', resolveFileUrl(url)));
    } on http.ClientException catch (e) {
      throw GatewayException('file_error', 'download failed: ${e.message}');
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw GatewayException(
        'file_error',
        'download answered HTTP ${response.statusCode}',
      );
    }
    final out = <int>[];
    await for (final chunk in response.stream) {
      out.addAll(chunk);
      if (out.length > maxBytes) {
        throw GatewayException('file_error', 'file exceeds $maxBytes bytes');
      }
    }
    return out;
  }

  /// PUTs [bytes] to the URL of an upload request.
  Future<void> uploadBytes(String url, List<int> bytes, String mimeType) async {
    final http.Response response;
    try {
      response = await _client.put(
        resolveFileUrl(url),
        headers: {'Content-Type': mimeType},
        body: bytes,
      );
    } on http.ClientException catch (e) {
      throw GatewayException('file_error', 'upload failed: ${e.message}');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayException(
        'file_error',
        'upload answered HTTP ${response.statusCode}: ${_short(response.body)}',
      );
    }
  }

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final http.Response response;
    try {
      response = await _client.post(
        _url(path),
        headers: _headers,
        body: jsonEncode(body),
      );
    } on http.ClientException catch (e) {
      throw GatewayException('file_error', '$path failed: ${e.message}');
    }
    if (response.statusCode != 200) {
      throw GatewayException(
        'file_error',
        '$path answered HTTP ${response.statusCode}: ${_short(response.body)}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw GatewayException('file_error', '$path answered a non-object');
    }
    return decoded.cast<String, Object?>();
  }

  static String _errorMessage(Object? message) {
    if (message is String) {
      try {
        final inner = jsonDecode(message);
        if (inner is Map) {
          final type = inner['error_type'];
          final text = inner['message'];
          return [?type, ?text].join(': ');
        }
      } on FormatException {
        // A plain message.
      }
      return message;
    }
    return 'model gateway error';
  }

  static String? _difyErrorType(Object? message) {
    if (message is! String) return null;
    try {
      final inner = jsonDecode(message);
      final t = inner is Map ? inner['error_type'] : null;
      return t is String ? t : null;
    } on FormatException {
      return null;
    }
  }

  static String _short(String text) =>
      text.length > 500 ? '${text.substring(0, 500)}…' : text;
}

/// The `data` payloads of a server-sent event stream (comments ignored).
Stream<String> parseSse(Stream<List<int>> bytes) async* {
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield data.join('\n');
        data.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    if (line.startsWith('data:')) {
      var v = line.substring(5);
      if (v.startsWith(' ')) v = v.substring(1);
      data.add(v);
    }
  }
  if (data.isNotEmpty) yield data.join('\n');
}

/// How reasoning reached the service for one model call; history sends it
/// back the same way.
enum ReasoningForm {
  /// `<think>…</think>` inside the content (Dify's plugin convention).
  thinkTag('think_tag'),

  /// `delta.message.reasoning_content`.
  reasoningContent('reasoning_content');

  const ReasoningForm(this.wire);
  final String wire;

  static ReasoningForm? parse(Object? v) =>
      values.where((f) => f.wire == v).firstOrNull;
}

/// One streamed piece of a model call.
sealed class LlmDelta {
  const LlmDelta(this.text);
  final String text;
}

class TextDelta extends LlmDelta {
  const TextDelta(super.text);
}

class ReasoningDelta extends LlmDelta {
  const ReasoningDelta(super.text, this.form);
  final ReasoningForm form;
}

/// A tool call merged from its deltas.
class MergedToolCall {
  MergedToolCall(this.index);

  final int? index;
  String? id;
  String type = 'function';
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
}

/// Splits `<think>…</think>` out of streamed content, across chunk
/// boundaries (a port of dify-agent's `_EmbeddedThinkingParser`).
class ThinkParser {
  static const _open = '<think>';
  static const _close = '</think>';

  String _pending = '';
  bool _inside = false;

  /// Returns (thinking, text) pieces in order.
  List<(bool, String)> parse(String content) {
    final out = <(bool, String)>[];
    var buffer = _pending + content;
    _pending = '';
    while (buffer.isNotEmpty) {
      if (_inside) {
        final end = buffer.indexOf(_close);
        if (end >= 0) {
          if (end > 0) out.add((true, buffer.substring(0, end)));
          buffer = buffer.substring(end + _close.length);
          _inside = false;
          continue;
        }
        final (safe, pending) = _splitSuffix(buffer, _close);
        _pending = pending;
        if (safe.isNotEmpty) out.add((true, safe));
        break;
      }
      final start = buffer.indexOf(_open);
      if (start >= 0) {
        if (start > 0) out.add((false, buffer.substring(0, start)));
        buffer = buffer.substring(start + _open.length);
        _inside = true;
        continue;
      }
      final (safe, pending) = _splitSuffix(buffer, _open);
      _pending = pending;
      if (safe.isNotEmpty) out.add((false, safe));
      break;
    }
    return out;
  }

  List<(bool, String)> flush() {
    if (_pending.isEmpty) return const [];
    final p = _pending;
    _pending = '';
    return [(_inside, p)];
  }

  static (String, String) _splitSuffix(String content, String tag) {
    for (var n = tag.length - 1; n > 0; n--) {
      if (content.endsWith(tag.substring(0, n))) {
        return (
          content.substring(0, content.length - n),
          content.substring(content.length - n),
        );
      }
    }
    return (content, '');
  }
}

/// Accumulates the chunks of one model call: answer text, reasoning (by
/// form), tool calls merged by `index` (or `id`), the last usage and the
/// first finish reason.
class LlmAccumulator {
  final ThinkParser _think = ThinkParser();
  final StringBuffer answer = StringBuffer();
  final StringBuffer thinkReasoning = StringBuffer();
  final StringBuffer fieldReasoning = StringBuffer();
  final List<MergedToolCall> toolCalls = [];
  final Map<int, MergedToolCall> _byIndex = {};
  Map<String, Object?>? usage;
  String? finishReason;
  static final Random _random = Random();

  List<LlmDelta> add(Map<String, Object?> chunk) {
    final out = <LlmDelta>[];
    final delta = chunk['delta'];
    if (delta is! Map) return out;
    final message = delta['message'];
    if (message is Map) {
      final reasoning = message['reasoning_content'];
      if (reasoning is String && reasoning.isNotEmpty) {
        fieldReasoning.write(reasoning);
        out.add(ReasoningDelta(reasoning, ReasoningForm.reasoningContent));
      }
      final content = message['content'];
      if (content is String && content.isNotEmpty) {
        out.addAll(_text(_think.parse(content)));
      } else if (content is List) {
        for (final part in content) {
          if (part is Map && part['type'] == 'text' && part['data'] is String) {
            out.addAll(_text(_think.parse(part['data'] as String)));
          }
        }
      }
      final calls = message['tool_calls'];
      if (calls is List) {
        for (final c in calls) {
          if (c is Map) _mergeToolCall(c.cast<String, Object?>());
        }
      }
    }
    final u = delta['usage'];
    if (u is Map) usage = u.cast<String, Object?>();
    final f = delta['finish_reason'];
    if (f is String && f.isNotEmpty) finishReason ??= f;
    return out;
  }

  List<LlmDelta> flush() => _text(_think.flush());

  List<LlmDelta> _text(List<(bool, String)> pieces) {
    final out = <LlmDelta>[];
    for (final (thinking, text) in pieces) {
      if (thinking) {
        thinkReasoning.write(text);
        out.add(ReasoningDelta(text, ReasoningForm.thinkTag));
      } else {
        answer.write(text);
        out.add(TextDelta(text));
      }
    }
    return out;
  }

  /// A delta with `index` belongs to that index's call; the first delta with
  /// an `id` sets the id; name and arguments concatenate in arrival order. A
  /// delta with an id but no index matches by id; one with neither continues
  /// the last call.
  void _mergeToolCall(Map<String, Object?> d) {
    final index = d['index'] is int ? d['index'] as int : null;
    final id = _normalizeId(d['id']);
    MergedToolCall? call;
    if (index != null) {
      call = _byIndex[index];
      if (call == null) {
        call = MergedToolCall(index);
        _byIndex[index] = call;
        toolCalls.add(call);
      }
    } else if (id != null) {
      call = toolCalls.where((c) => c.id == id).firstOrNull;
      if (call == null) {
        call = MergedToolCall(null);
        toolCalls.add(call);
      }
    } else {
      call = toolCalls.lastOrNull;
      if (call == null) {
        call = MergedToolCall(null);
        toolCalls.add(call);
      }
    }
    if (call.id == null && id != null) call.id = id;
    final type = d['type'];
    if (type is String && type.isNotEmpty) call.type = type;
    final function = d['function'];
    if (function is Map) {
      final name = function['name'];
      if (name is String) call.name.write(name);
      final args = function['arguments'];
      if (args is String) call.arguments.write(args);
    }
  }

  /// Gives every tool call without a provider ID a generated one.
  void assignMissingIds() {
    for (final c in toolCalls) {
      c.id ??=
          'call_${List.generate(12, (_) => _random.nextInt(16).toRadixString(16)).join()}';
    }
  }

  static String? _normalizeId(Object? raw) {
    if (raw == null) return null;
    final s = (raw is String ? raw : raw.toString()).trim();
    if (s.isEmpty || s.toLowerCase() == 'none' || s.toLowerCase() == 'null') {
      return null;
    }
    return s;
  }
}

String? _errorCode(String body) {
  try {
    final j = jsonDecode(body);
    return j is Map ? j['error'] as String? : null;
  } on FormatException {
    return null;
  }
}

/// The error code of a JSON error body: `{"error": "<code>"}` (the
/// gateway) or `{"error": {"code": "<code>"}}` (an OpenAI-style body).
String? _errorCodeLoose(String body) {
  try {
    final j = jsonDecode(body);
    final e = j is Map ? j['error'] : null;
    if (e is String) return e;
    if (e is Map && e['code'] is String) return e['code'] as String;
    // OpenAI-style bodies may carry the reason only in `error.type`
    // (e.g. `usage_limit_reached`), which Codex also reads.
    if (e is Map && e['type'] is String) return e['type'] as String;
    return null;
  } on FormatException {
    return null;
  }
}
