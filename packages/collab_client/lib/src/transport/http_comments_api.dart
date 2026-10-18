import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../client/comments_api.dart';
import '../client/transport.dart';
import '../model/comments.dart';

/// [CommentsApi] against the real server (`/v1/docs/{doc}/comments`, docs/protocol.md section 2 "Comments").
class HttpCommentsApi implements CommentsApi {
  HttpCommentsApi({
    required Uri baseUrl,
    required this.docId,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _base = baseUrl,
       _client = client ?? http.Client();

  final Uri _base;
  final String docId;
  final http.Client _client;
  final Duration timeout;

  Uri _url(String suffix, [Map<String, String>? query]) => _base.replace(
    path:
        '${_base.path.endsWith('/') ? _base.path.substring(0, _base.path.length - 1) : _base.path}/v1/docs/$docId$suffix',
    queryParameters: query,
  );

  String _c(String id) => '/comments/${Uri.encodeComponent(id)}';

  @override
  Future<List<Comment>> list() async {
    final json = await _send('GET', '/comments', ok: 200) as Map<String, Object?>;
    final comments = json['comments'];
    if (comments is! List<Object?>) throw const TransportException('malformed comments list');
    return [for (final c in comments) Comment.fromJson(c)];
  }

  @override
  Future<Comment> get(String id) async => Comment.fromJson(await _send('GET', _c(id), ok: 200));

  @override
  Future<Comment> create({
    required String author,
    required double x,
    required double y,
    required String content,
    List<String> mentions = const [],
  }) async => Comment.fromJson(
    await _send(
      'POST',
      '/comments',
      ok: 201,
      body: {'client': author, 'position_x': x, 'position_y': y, 'content': content, 'mentioned_client_ids': mentions},
    ),
  );

  @override
  Future<Comment> update(
    String id, {
    required String author,
    String? content,
    double? x,
    double? y,
    List<String>? mentions,
  }) async => Comment.fromJson(
    await _send(
      'PUT',
      _c(id),
      ok: 200,
      body: {
        'client': author,
        'content': ?content,
        'position_x': ?x,
        'position_y': ?y,
        'mentioned_client_ids': ?mentions,
      },
    ),
  );

  @override
  Future<void> delete(String id, {required String author}) =>
      _send('DELETE', _c(id), ok: 204, query: {'client': author});

  @override
  Future<Comment> resolve(String id, {required String author}) async =>
      Comment.fromJson(await _send('POST', '${_c(id)}/resolve', ok: 200, body: {'client': author}));

  @override
  Future<CommentReply> reply(
    String id, {
    required String author,
    required String content,
    List<String> mentions = const [],
  }) async => CommentReply.fromJson(
    await _send(
      'POST',
      '${_c(id)}/replies',
      ok: 201,
      body: {'client': author, 'content': content, 'mentioned_client_ids': mentions},
    ),
  );

  @override
  Future<CommentReply> editReply(
    String id,
    String replyId, {
    required String author,
    required String content,
    List<String> mentions = const [],
  }) async => CommentReply.fromJson(
    await _send(
      'PUT',
      '${_c(id)}/replies/${Uri.encodeComponent(replyId)}',
      ok: 200,
      body: {'client': author, 'content': content, 'mentioned_client_ids': mentions},
    ),
  );

  @override
  Future<void> deleteReply(String id, String replyId, {required String author}) =>
      _send('DELETE', '${_c(id)}/replies/${Uri.encodeComponent(replyId)}', ok: 204, query: {'client': author});

  @override
  Future<Map<String, String>> clientNames() async {
    final json = await _send('GET', '/clients', ok: 200) as Map<String, Object?>;
    final clients = json['clients'];
    if (clients is! Map<String, Object?>) return const {};
    return {
      for (final e in clients.entries)
        if (e.value is String) e.key: e.value! as String,
    };
  }

  /// One request; the decoded JSON body (null for 204). Any other status, a timeout or a connect error throws a
  /// [TransportException] (with the server's error code, e.g. `not_author`).
  Future<Object?> _send(
    String method,
    String suffix, {
    required int ok,
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    final req = http.Request(method, _url(suffix, query));
    if (body != null) {
      req
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
    } on TimeoutException {
      throw TransportException('$method $suffix timed out', timeout: true);
    } on Object catch (e) {
      throw TransportException('$method $suffix failed: $e');
    }
    if (res.statusCode != ok) throw _error(res);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException catch (e) {
      throw TransportException('malformed answer to $method $suffix: ${e.message}');
    }
  }

  static TransportException _error(http.Response res) {
    try {
      final e = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>)['error']! as Map<String, Object?>;
      return TransportException('${e['message']}', statusCode: res.statusCode, code: e['code'] as String?);
    } on Object {
      return TransportException('HTTP ${res.statusCode}', statusCode: res.statusCode);
    }
  }

  void close() => _client.close();
}
