import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/account.dart';
import '../auth/auth_session.dart';
import '../client/comments_api.dart';
import '../client/transport.dart';
import '../model/document.dart';
import 'http_comments_api.dart';

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

/// A document's Dify app metadata (`GET /v1/docs/{id}/meta`): what an imported Dify workflow file says about the app.
/// Documents that were not imported have the defaults (a workflow, no variables). Since protocol 1.7 the variables and
/// features are those of the document at head (they live in the document: [AppRegisters]); a live editor reads them
/// from its document instead.
final class DocMeta {
  const DocMeta({
    this.appMode = 'workflow',
    this.appName = '',
    this.environmentVariables = const [],
    this.conversationVariables = const [],
    this.raw = const {},
  });

  factory DocMeta.fromJson(Map<String, Object?> json) {
    final app = json['app'];
    List<Map<String, Object?>> vars(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e is Map<String, Object?>) e,
    ];
    return DocMeta(
      appMode: app is Map<String, Object?> && app['mode'] is String ? app['mode']! as String : 'workflow',
      appName: app is Map<String, Object?> && app['name'] is String ? app['name']! as String : '',
      environmentVariables: vars(json['environment_variables']),
      conversationVariables: vars(json['conversation_variables']),
      raw: json,
    );
  }

  /// Dify's `app.mode`: `workflow`, `advanced-chat` (a chatflow), ...
  final String appMode;
  final String appName;

  /// Dify's `workflow.environment_variables`, as Dify JSON (secret values are masked by the server, 1.7).
  final List<Map<String, Object?>> environmentVariables;

  /// Dify's `workflow.conversation_variables`, as Dify JSON.
  final List<Map<String, Object?>> conversationVariables;

  /// The whole response (`app`, `features`, `dependencies`, ...).
  final Map<String, Object?> raw;

  bool get isChatflow => appMode == 'advanced-chat';
}

/// The document-level endpoints (everything except ops and events). Protocol 1.8: pass the signed-in user's [auth] and
/// every request carries its bearer token (refreshed once on a `401`); without it no token is sent.
class DocsApi {
  DocsApi(this.baseUrl, {http.Client? client, this.auth, this.timeout = const Duration(seconds: 10)})
    : _client = auth == null ? (client ?? http.Client()) : AuthenticatedClient(client ?? http.Client(), auth);

  final Uri baseUrl;
  final Duration timeout;
  final http.Client _client;

  /// The signed-in user (protocol 1.8); null = no token.
  final TokenProvider? auth;

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

  /// `POST /v1/docs/{id}/clients` (protocol 1.1): a fresh unique client id for one client instance. Since protocol 1.8
  /// it belongs to the signed-in account (ops under it from another account are refused); [name] is ignored by 1.8
  /// servers (names are the accounts' names).
  Future<String> issueClientId(String id, {String? name}) async {
    final req = http.Request('POST', _url('/v1/docs/$id/clients'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'name': ?name});
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 201 && res.statusCode != 200) throw _error(res);
    return (jsonDecode(res.body) as Map<String, Object?>)['client']! as String;
  }

  /// `PUT /v1/docs/{id}/clients/{client}`: since protocol 1.8 it binds a self-chosen [client] id to the signed-in
  /// account (`403` if it belongs to another one); [name] is ignored. (1.3: it named the id.)
  Future<void> setClientName(String id, String client, String name) async {
    final req = http.Request('PUT', _url('/v1/docs/$id/clients/${Uri.encodeComponent(client)}'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'name': name});
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 200) throw _error(res);
  }

  /// `GET /v1/docs/{id}/clients` (protocol 1.8): client id -> the account it belongs to (id, name, avatar). Several ids
  /// of one account (tabs, devices) are one user.
  Future<Map<String, ClientIdentity>> clientDirectory(String id) async {
    final res = await _guard(() => _client.get(_url('/v1/docs/$id/clients')).timeout(timeout));
    if (res.statusCode != 200) throw _error(res);
    return parseClientDirectory(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// Client id -> account name, from [clientDirectory] (protocol 1.3's name directory, now with account names).
  Future<Map<String, String>> clientNames(String id) async =>
      (await clientDirectory(id)).map((client, who) => MapEntry(client, who.name));

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

  /// `GET /v1/docs/{id}/export`: the current state as a Dify workflow file (YAML). Secret environment variables are
  /// exported with `""` unless [includeSecret] (Dify's option of the same name, protocol 1.7).
  Future<String> exportDifyDsl(String id, {bool includeSecret = false}) async {
    final url = _url('/v1/docs/$id/export');
    final res = await _guard(
      () =>
          _client.get(includeSecret ? url.replace(queryParameters: {'include_secret': 'true'}) : url).timeout(timeout),
    );
    if (res.statusCode != 200) throw _error(res);
    return utf8.decode(res.bodyBytes);
  }

  /// `GET /v1/docs/{id}/export?format=json`: the same as parsed JSON.
  Future<Map<String, Object?>> exportDifyDslJson(String id, {bool includeSecret = false}) async {
    final query = {'format': 'json', if (includeSecret) 'include_secret': 'true'};
    final res = await _guard(
      () => _client.get(_url('/v1/docs/$id/export').replace(queryParameters: query)).timeout(timeout),
    );
    if (res.statusCode != 200) throw _error(res);
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>;
  }

  /// `POST /v1/docs/{id}/secrets` (protocol 1.7): stores the plaintext of a secret environment variable server-side.
  /// Returns its reference and Dify's mask; write the variable with ordinary item ops on `$app` with `value` = [masked]
  /// and `secret_ref` = [ref]. The plaintext never enters ops, the log or snapshots.
  Future<({String ref, String masked})> storeSecret(String id, String value) async {
    final req = http.Request('POST', _url('/v1/docs/$id/secrets'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'value': value});
    final res = await _guard(() async => http.Response.fromStream(await _client.send(req).timeout(timeout)));
    if (res.statusCode != 201 && res.statusCode != 200) throw _error(res);
    final json = jsonDecode(res.body) as Map<String, Object?>;
    return (ref: json['ref']! as String, masked: json['masked']! as String);
  }

  /// `GET /v1/docs/{id}/meta`: the Dify app metadata (mode, name, variables, features).
  Future<DocMeta> meta(String id) async {
    final res = await _guard(() => _client.get(_url('/v1/docs/$id/meta')).timeout(timeout));
    if (res.statusCode != 200) throw _error(res);
    return DocMeta.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>);
  }

  /// The canvas comments of document [id] (`/v1/docs/{id}/comments`), over this API's HTTP client (and its token).
  CommentsApi comments(String id) => HttpCommentsApi(baseUrl: baseUrl, docId: id, client: _client, timeout: timeout);

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

/// The `clients` map of `GET /v1/docs/{doc}/clients`: protocol 1.8's `{"<client id>": {"account","name","avatar_url"?}}`.
/// Entries of the 1.3 shape (`"<client id>": "<name>"`) become identities whose account is the client id.
Map<String, ClientIdentity> parseClientDirectory(Object? json) {
  final clients = json is Map<String, Object?> ? json['clients'] : null;
  if (clients is! Map<String, Object?>) return const {};
  return {
    for (final e in clients.entries)
      if (e.value is Map<String, Object?>)
        e.key: ClientIdentity.fromJson(e.value)
      else if (e.value is String)
        e.key: ClientIdentity(account: e.key, name: e.value! as String),
  };
}
