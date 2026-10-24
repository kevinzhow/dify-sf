import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth/auth_session.dart';
import 'client/transport.dart';

typedef HelperJson = Map<String, Object?>;
typedef HelperAudio = ({Uint8List bytes, String mimeType});

class HelperCancellation {
  final _done = Completer<void>();
  Future<void> get signal => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Model-backed proposals and audio. Generation never writes collaborative document state.
class HelpersApi {
  HelpersApi(this.baseUrl, {TokenProvider? auth, http.Client? client})
    : _client = auth == null ? (client ?? http.Client()) : AuthenticatedClient(client ?? http.Client(), auth);
  final Uri baseUrl;
  final http.Client _client;

  Future<({Uint8List bytes, String type})> _send(
    String method,
    String path,
    HelperJson? body,
    HelperCancellation? cancellation,
  ) async {
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(cancellation?.signal.then((_) => cancel()));
    final deadline = Timer(const Duration(minutes: 3), cancel);
    try {
      final location = Uri.parse(path);
      final request = http.AbortableRequest(
        method,
        baseUrl.replace(
          path: '${baseUrl.path.replaceFirst(RegExp(r'/$'), '')}${location.path}',
          query: location.query.isEmpty ? null : location.query,
          fragment: null,
        ),
        abortTrigger: abort.future,
      );
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }

      // A timeout is bounded on both send and body reads; closing an owning page closes this API too.
      final response = await _client.send(request).timeout(const Duration(minutes: 3));
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        bytes.add(chunk);
        if (bytes.length > 16 << 20) {
          cancel();
          throw const TransportException('Helper response exceeds 16MB');
        }
      }
      final data = bytes.takeBytes();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(data));
        } on Object {
          /* Keep an HTTP error if the peer returned HTML. */
        }
        final error = decoded is Map ? decoded['error'] : null;
        throw TransportException(
          error is Map ? '${error['message']}' : 'Helper request failed (${response.statusCode})',
          statusCode: response.statusCode,
          code: error is Map ? error['code'] as String? : null,
        );
      }
      return (bytes: data, type: response.headers['content-type']?.split(';').first ?? 'application/octet-stream');
    } finally {
      deadline.cancel();
    }
  }

  Future<HelperJson> generate(String kind, HelperJson body, {HelperCancellation? cancellation}) async {
    if (!const [
      'rule-generate',
      'rule-code-generate',
      'rule-structured-output-generate',
      'instruction-generate',
      'workflow-generate',
    ].contains(kind)) {
      throw ArgumentError.value(kind, 'kind');
    }
    final response = await _send('POST', '/v1/$kind', body, cancellation);
    final decoded = jsonDecode(utf8.decode(response.bytes));
    if (decoded is! Map<String, Object?>) throw const TransportException('Invalid generation response');
    if (decoded['error'] case final String error when error.isNotEmpty) throw TransportException(error);
    return decoded;
  }

  String _audio(String app) => '/v1/apps/${Uri.encodeComponent(app)}/text-to-audio';
  Future<List<({String value, String name})>> voices(
    String app,
    String language, {
    HelperCancellation? cancellation,
  }) async {
    final response = await _send(
      'GET',
      '${_audio(app)}/voices?${Uri(queryParameters: {'language': language}).query}',
      null,
      cancellation,
    );
    final decoded = jsonDecode(utf8.decode(response.bytes));
    final values = decoded is List ? decoded : (decoded is Map ? decoded['voices'] : null);
    if (values is! List) throw const TransportException('Invalid voice list');
    return [
      for (final voice in values)
        if (voice is Map && voice['value'] is String && voice['name'] is String)
          (value: voice['value'] as String, name: voice['name'] as String),
    ];
  }

  Future<HelperAudio> audio(
    String app, {
    required String text,
    String? voice,
    String? messageId,
    HelperCancellation? cancellation,
  }) async {
    final response = await _send('POST', _audio(app), {
      'text': text,
      'voice': ?voice,
      'message_id': ?messageId,
    }, cancellation);
    if (!response.type.startsWith('audio/') || response.bytes.isEmpty) {
      throw const TransportException('The model returned no playable audio');
    }
    return (bytes: response.bytes, mimeType: response.type);
  }

  void close() => _client.close();
}
