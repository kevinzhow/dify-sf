import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../apps_api.dart';
import '../auth/auth_api.dart';
import '../auth/auth_session.dart';
import '../client/transport.dart';

/// [AppsApi] against a real server at [baseUrl] (protocol 1.10). Pass the signed-in user's [auth]: every request
/// carries its bearer token (refreshed once on a `401`).
class HttpAppsApi implements AppsApi {
  HttpAppsApi(
    this.baseUrl, {
    http.Client? client,
    TokenProvider? auth,
    this.timeout = const Duration(seconds: 20),
  }) : _client = auth == null ? (client ?? http.Client()) : AuthenticatedClient(client ?? http.Client(), auth);

  final Uri baseUrl;

  /// Per request.
  final Duration timeout;
  final http.Client _client;

  String get _basePath =>
      baseUrl.path.endsWith('/') ? baseUrl.path.substring(0, baseUrl.path.length - 1) : baseUrl.path;

  Uri _url(String path, [Map<String, List<String>>? query]) =>
      baseUrl.replace(path: '$_basePath$path', queryParameters: query == null || query.isEmpty ? null : query);

  static String _app(String id) => '/v1/apps/${Uri.encodeComponent(id)}';

  static Map<String, Object?> _map(Object? json) =>
      json is Map<String, Object?> ? json : throw const TransportException('malformed answer: not an object');

  @override
  Future<AppPage> list([AppListQuery query = const AppListQuery()]) async =>
      AppPage.fromJson(_map((await _send('GET', '/v1/apps', ok: const [200], query: query.toQuery())).json));

  @override
  Future<AppPage> starred([AppListQuery query = const AppListQuery(limit: 100)]) async =>
      AppPage.fromJson(_map((await _send('GET', '/v1/apps/starred', ok: const [200], query: query.toQuery())).json));

  @override
  Future<AppInfo> get(String id) async => AppInfo.fromJson(_map((await _send('GET', _app(id), ok: const [200])).json));

  @override
  Future<void> star(String id) => _send('POST', '${_app(id)}/star', ok: const [200]);

  @override
  Future<void> unstar(String id) => _send('DELETE', '${_app(id)}/star', ok: const [200, 204]);

  @override
  Future<AppInfo> create({
    required String name,
    required String mode,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) async => AppInfo.fromJson(
    _map(
      (await _send(
        'POST',
        '/v1/apps',
        ok: const [201, 200],
        body: {
          'name': name,
          'mode': mode,
          'description': ?description,
          'icon_type': ?iconType,
          'icon': ?icon,
          'icon_background': ?iconBackground,
        },
      )).json,
    ),
  );

  @override
  Future<AppImport> importDsl(
    String yamlContent, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => _import('/v1/apps/imports', {
    'mode': 'yaml-content',
    'yaml_content': yamlContent,
    'name': ?name,
    'description': ?description,
    'icon_type': ?iconType,
    'icon': ?icon,
    'icon_background': ?iconBackground,
  });

  @override
  Future<AppImport> confirmImport(String importId) =>
      _import('/v1/apps/imports/${Uri.encodeComponent(importId)}/confirm', null);

  /// Dify answers an import with an `Import` object also when it failed (`400`) or waits for confirmation (`202`).
  Future<AppImport> _import(String path, Map<String, Object?>? body) async {
    final res = await _send('POST', path, ok: const [200, 202, 400], body: body);
    final json = res.json;
    if (json is Map<String, Object?> && json['status'] is String) return AppImport.fromJson(json);
    throw transportErrorOf(res.status, res.text);
  }

  @override
  Future<AppInfo> update(
    String id, {
    required String name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
    bool? useIconAsAnswerIcon,
    int? maxActiveRequests,
  }) async => AppInfo.fromJson(
    _map(
      (await _send(
        'PUT',
        _app(id),
        ok: const [200],
        body: {
          'name': name,
          'description': ?description,
          'icon_type': ?iconType,
          'icon': ?icon,
          'icon_background': ?iconBackground,
          'use_icon_as_answer_icon': ?useIconAsAnswerIcon,
          'max_active_requests': ?maxActiveRequests,
        },
      )).json,
    ),
  );

  @override
  Future<AppInfo> copy(
    String id, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) async => AppInfo.fromJson(
    _map(
      (await _send(
        'POST',
        '${_app(id)}/copy',
        ok: const [201, 200],
        body: {
          'name': ?name,
          'description': ?description,
          'icon_type': ?iconType,
          'icon': ?icon,
          'icon_background': ?iconBackground,
        },
      )).json,
    ),
  );

  @override
  Future<void> delete(String id) => _send('DELETE', _app(id), ok: const [204, 200]);

  @override
  Future<String> exportDsl(String id, {bool includeSecret = false}) async {
    final json = _map(
      (await _send(
        'GET',
        '${_app(id)}/export',
        ok: const [200],
        query: {
          'include_secret': ['$includeSecret'],
        },
      )).json,
    );
    final data = json['data'];
    if (data is! String) throw const TransportException('malformed answer: no data');
    return data;
  }

  Future<({int status, String text, Object? json})> _send(
    String method,
    String path, {
    required List<int> ok,
    Map<String, Object?>? body,
    Map<String, List<String>>? query,
  }) async {
    final req = http.Request(method, _url(path, query));
    if (body != null) {
      req
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
    } on TimeoutException {
      throw TransportException('$method $path timed out', timeout: true);
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (!ok.contains(res.statusCode)) throw transportErrorOf(res.statusCode, text);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return (status: res.statusCode, text: text, json: null);
    try {
      return (status: res.statusCode, text: text, json: jsonDecode(text));
    } on FormatException catch (e) {
      if (res.statusCode >= 400) throw transportErrorOf(res.statusCode, text);
      throw TransportException('malformed answer to $method $path: ${e.message}');
    }
  }

  void close() => _client.close();
}
