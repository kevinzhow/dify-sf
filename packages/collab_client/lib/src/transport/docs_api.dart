import 'dart:convert';

import 'package:http/http.dart' as http;

import '../client/transport.dart';
import '../model/document.dart';

/// Result of creating or looking up a document.
final class DocInfo {
  const DocInfo({required this.id, required this.head, this.created = false});

  factory DocInfo.fromJson(Object? json) {
    final m = json! as Map<String, Object?>;
    return DocInfo(id: m['id']! as String, head: m['head']! as int, created: m['created'] as bool? ?? false);
  }

  final String id;
  final int head;
  final bool created;
}

/// The document-level endpoints (everything except ops and events).
class DocsApi {
  DocsApi(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 10)})
    : _client = client ?? http.Client();

  final Uri baseUrl;
  final Duration timeout;
  final http.Client _client;

  Uri _url(String path) {
    final base = baseUrl.path.endsWith('/') ? baseUrl.path.substring(0, baseUrl.path.length - 1) : baseUrl.path;
    return baseUrl.replace(path: '$base$path');
  }

  /// `GET /healthz`.
  Future<bool> healthy() async {
    try {
      final res = await _client.get(_url('/healthz')).timeout(timeout);
      return res.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// `POST /v1/docs`: a new document with a server-generated id.
  Future<DocInfo> create({String? template}) => _send('POST', '/v1/docs', template);

  /// `PUT /v1/docs/{id}`: create if absent (idempotent).
  Future<DocInfo> ensure(String id, {String? template}) => _send('PUT', '/v1/docs/$id', template);

  /// `GET /v1/docs/{id}`; null if unknown.
  Future<DocInfo?> info(String id) async {
    final res = await _guard(() => _client.get(_url('/v1/docs/$id')).timeout(timeout));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw _error(res);
    return DocInfo.fromJson(jsonDecode(res.body));
  }

  /// `POST /v1/docs/{id}/clients` (protocol 1.1): a fresh unique client id for one client instance, optionally
  /// with a display name (protocol 1.3).
  Future<String> issueClientId(String id, {String? name}) async {
    final req = http.Request('POST', _url('/v1/docs/$id/clients'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'name': ?name});
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 201 && res.statusCode != 200) throw _error(res);
    return (jsonDecode(res.body) as Map<String, Object?>)['client']! as String;
  }

  /// `PUT /v1/docs/{id}/clients/{client}` (protocol 1.3): names or renames a client id.
  Future<void> setClientName(String id, String client, String name) async {
    final req = http.Request('PUT', _url('/v1/docs/$id/clients/${Uri.encodeComponent(client)}'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'name': name});
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 200) throw _error(res);
  }

  /// `GET /v1/docs/{id}/clients` (protocol 1.3): display names of the clients that registered one.
  Future<Map<String, String>> clientNames(String id) async {
    final res = await _guard(() => _client.get(_url('/v1/docs/$id/clients')).timeout(timeout));
    if (res.statusCode != 200) throw _error(res);
    final clients = (jsonDecode(res.body) as Map<String, Object?>)['clients'];
    if (clients is! Map<String, Object?>) return const {};
    return {
      for (final e in clients.entries)
        if (e.value is String) e.key: e.value! as String,
    };
  }

  /// `POST /v1/docs/import` (server-generated id) or `PUT /v1/docs/{id}/import`: a document from a Dify workflow
  /// file (YAML). An existing document is left alone (`created: false`), so a retried import is harmless.
  Future<DocInfo> importDifyDsl(String yaml, {String? id}) async {
    final req = http.Request(id == null ? 'POST' : 'PUT', _url(id == null ? '/v1/docs/import' : '/v1/docs/$id/import'))
      ..headers['Content-Type'] = 'application/x-yaml; charset=utf-8'
      ..body = yaml;
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 200 && res.statusCode != 201) throw _error(res);
    final json = jsonDecode(res.body) as Map<String, Object?>;
    return DocInfo(id: json['id']! as String, head: json['head']! as int, created: json['created'] as bool? ?? false);
  }

  /// `GET /v1/docs/{id}/export`: the current state as a Dify workflow file (YAML).
  Future<String> exportDifyDsl(String id) async {
    final res = await _guard(() => _client.get(_url('/v1/docs/$id/export')).timeout(timeout));
    if (res.statusCode != 200) throw _error(res);
    return utf8.decode(res.bodyBytes);
  }

  /// `GET /v1/docs/{id}/export?format=json`: the same as parsed JSON.
  Future<Map<String, Object?>> exportDifyDslJson(String id) async {
    final res = await _guard(
      () => _client.get(_url('/v1/docs/$id/export').replace(queryParameters: {'format': 'json'})).timeout(timeout),
    );
    if (res.statusCode != 200) throw _error(res);
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>;
  }

  /// `GET /v1/docs/{id}/snapshot`: the full document at the current head.
  Future<({int seq, Document doc})> snapshot(String id) async {
    final res = await _guard(() => _client.get(_url('/v1/docs/$id/snapshot')).timeout(timeout));
    if (res.statusCode != 200) throw _error(res);
    final json = jsonDecode(res.body) as Map<String, Object?>;
    return (seq: json['seq']! as int, doc: Document.fromJson(json['doc']));
  }

  Future<DocInfo> _send(String method, String path, String? template) async {
    final req = http.Request(method, _url(path))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'template': ?template});
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 200 && res.statusCode != 201) throw _error(res);
    final json = jsonDecode(res.body) as Map<String, Object?>;
    return DocInfo(
      id: json['id']! as String,
      head: json['head']! as int,
      created: json['created'] as bool? ?? res.statusCode == 201,
    );
  }

  Future<http.Response> _guard(Future<http.Response> Function() f) async {
    try {
      return await f();
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('request failed: $e');
    }
  }

  TransportException _error(http.Response res) {
    try {
      final e = (jsonDecode(res.body) as Map<String, Object?>)['error']! as Map<String, Object?>;
      return TransportException('${e['message']}', statusCode: res.statusCode, code: e['code'] as String?);
    } on Object {
      return TransportException('HTTP ${res.statusCode}', statusCode: res.statusCode);
    }
  }

  void close() => _client.close();
}
