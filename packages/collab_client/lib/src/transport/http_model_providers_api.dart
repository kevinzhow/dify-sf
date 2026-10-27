import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_api.dart';
import '../auth/auth_session.dart';
import '../client/transport.dart';
import '../providers/model_providers_api.dart';

/// [ModelProvidersApi] against a real server at [baseUrl] (protocol 1.9). Pass the signed-in user's [auth]: every
/// request carries its bearer token (refreshed once on a `401`).
class HttpModelProvidersApi implements ModelProvidersApi, ModelProviderPluginsApi, ModelDiscoveryApi {
  HttpModelProvidersApi(
    this.baseUrl, {
    http.Client? client,
    TokenProvider? auth,
    this.timeout = const Duration(seconds: 20),
  }) : _client = auth == null ? (client ?? http.Client()) : AuthenticatedClient(client ?? http.Client(), auth);

  final Uri baseUrl;

  /// Per request. Saving a credential waits for the server's validation request to the provider (up to 10 s).
  final Duration timeout;
  final http.Client _client;

  String get _basePath =>
      baseUrl.path.endsWith('/') ? baseUrl.path.substring(0, baseUrl.path.length - 1) : baseUrl.path;

  Uri _url(String path, [Map<String, String>? query]) => baseUrl.replace(
    path: '$_basePath$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  static const _ws = '/v1/workspace';

  /// `.../model-providers/{org}/{plugin}/{name}`: the provider id's segments, each encoded.
  String _p(String provider) => '$_ws/model-providers/${provider.split('/').map(Uri.encodeComponent).join('/')}';

  List<Map<String, Object?>> _data(Object? json) {
    final data = json is Map<String, Object?> ? json['data'] : null;
    if (data is! List<Object?>) {
      throw const TransportException('malformed answer: no data list');
    }
    return [
      for (final e in data)
        if (e is Map<String, Object?>) e,
    ];
  }

  @override
  Future<List<Map<String, Object?>>> summaries() async => _data(
    await _send('GET', '$_ws/model-providers/summary', ok: const [200]),
  );

  @override
  Future<List<Map<String, Object?>>> providers({String? modelType}) async => _data(
    await _send(
      'GET',
      '$_ws/model-providers',
      ok: const [200],
      query: {'model_type': ?modelType},
    ),
  );

  @override
  Future<List<Map<String, Object?>>> modelsOfType(String modelType) async => _data(
    await _send(
      'GET',
      '$_ws/models/model-types/${Uri.encodeComponent(modelType)}',
      ok: const [200],
    ),
  );

  @override
  Future<Map<String, Object?>?> defaultModel(String modelType) async {
    final json = await _send(
      'GET',
      '$_ws/default-model',
      ok: const [200],
      query: {'model_type': modelType},
    );
    final data = json is Map<String, Object?> ? json['data'] : null;
    return data is Map<String, Object?> ? data : null;
  }

  @override
  Future<List<Map<String, Object?>>> parameterRules(
    String provider,
    String model,
  ) async => _data(
    await _send(
      'GET',
      '${_p(provider)}/models/parameter-rules',
      ok: const [200],
      query: {'model': model},
    ),
  );

  @override
  Future<List<Map<String, Object?>>> providerModels(String provider) async =>
      _data(await _send('GET', '${_p(provider)}/models', ok: const [200]));

  @override
  Future<void> setDefaultModels(List<DefaultModelSetting> settings) => _send(
    'POST',
    '$_ws/default-model',
    ok: const [200],
    body: {
      'model_settings': [for (final s in settings) s.toJson()],
    },
  );

  @override
  Future<void> enableModel(
    String provider, {
    required String model,
    required String modelType,
  }) => _send(
    'PATCH',
    '${_p(provider)}/models/enable',
    ok: const [200],
    body: {'model': model, 'model_type': modelType},
  );

  @override
  Future<void> disableModel(
    String provider, {
    required String model,
    required String modelType,
  }) => _send(
    'PATCH',
    '${_p(provider)}/models/disable',
    ok: const [200],
    body: {'model': model, 'model_type': modelType},
  );

  @override
  Future<Map<String, Object?>> providerCredentials(
    String provider, {
    String? credentialId,
  }) async {
    final json = await _send(
      'GET',
      '${_p(provider)}/credentials',
      ok: const [200],
      query: {'credential_id': ?credentialId},
    );
    final c = json is Map<String, Object?> ? json['credentials'] : null;
    return c is Map<String, Object?> ? c : <String, Object?>{};
  }

  @override
  Future<void> createProviderCredential(
    String provider, {
    required Map<String, Object?> credentials,
    String? name,
  }) => _send(
    'POST',
    '${_p(provider)}/credentials',
    ok: const [201, 200],
    body: {'credentials': credentials, 'name': ?name},
  );

  @override
  Future<void> updateProviderCredential(
    String provider, {
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  }) => _send(
    'PUT',
    '${_p(provider)}/credentials',
    ok: const [200],
    body: {
      'credential_id': credentialId,
      'credentials': credentials,
      'name': ?name,
    },
  );

  @override
  Future<void> deleteProviderCredential(
    String provider, {
    required String credentialId,
  }) => _send(
    'DELETE',
    '${_p(provider)}/credentials',
    ok: const [204, 200],
    body: {'credential_id': credentialId},
  );

  @override
  Future<void> switchProviderCredential(
    String provider, {
    required String credentialId,
  }) => _send(
    'POST',
    '${_p(provider)}/credentials/switch',
    ok: const [200],
    body: {'credential_id': credentialId},
  );

  @override
  Future<CredentialValidation> validateProviderCredentials(
    String provider, {
    required Map<String, Object?> credentials,
  }) async => CredentialValidation.fromJson(
    await _send(
      'POST',
      '${_p(provider)}/credentials/validate',
      ok: const [200],
      body: {'credentials': credentials},
    ),
  );

  @override
  Future<Map<String, Object?>> modelCredentials(
    String provider, {
    required String model,
    required String modelType,
    String? configFrom,
    String? credentialId,
  }) async {
    final json = await _send(
      'GET',
      '${_p(provider)}/models/credentials',
      ok: const [200],
      query: {
        'model': model,
        'model_type': modelType,
        'config_from': ?configFrom,
        'credential_id': ?credentialId,
      },
    );
    return json is Map<String, Object?> ? json : <String, Object?>{};
  }

  @override
  Future<void> createModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
    String? name,
  }) => _send(
    'POST',
    '${_p(provider)}/models/credentials',
    ok: const [201, 200],
    body: {
      'model': model,
      'model_type': modelType,
      'credentials': credentials,
      'name': ?name,
    },
  );

  @override
  Future<void> updateModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  }) => _send(
    'PUT',
    '${_p(provider)}/models/credentials',
    ok: const [200],
    body: {
      'model': model,
      'model_type': modelType,
      'credential_id': credentialId,
      'credentials': credentials,
      'name': ?name,
    },
  );

  @override
  Future<void> deleteModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) => _send(
    'DELETE',
    '${_p(provider)}/models/credentials',
    ok: const [204, 200],
    body: {
      'model': model,
      'model_type': modelType,
      'credential_id': credentialId,
    },
  );

  @override
  Future<void> switchModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) => _send(
    'POST',
    '${_p(provider)}/models/credentials/switch',
    ok: const [200],
    body: {
      'model': model,
      'model_type': modelType,
      'credential_id': credentialId,
    },
  );

  @override
  Future<CredentialValidation> validateModelCredentials(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
  }) async => CredentialValidation.fromJson(
    await _send(
      'POST',
      '${_p(provider)}/models/credentials/validate',
      ok: const [200],
      body: {
        'model': model,
        'model_type': modelType,
        'credentials': credentials,
      },
    ),
  );

  @override
  Future<void> addCustomModel(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) => _send(
    'POST',
    '${_p(provider)}/models',
    ok: const [200, 201],
    body: {
      'model': model,
      'model_type': modelType,
      'config_from': ModelConfigFrom.customModel,
      'credential_id': credentialId,
    },
  );

  @override
  Future<void> removeCustomModel(
    String provider, {
    required String model,
    required String modelType,
  }) => _send(
    'DELETE',
    '${_p(provider)}/models',
    ok: const [204, 200],
    body: {'model': model, 'model_type': modelType},
  );

  @override
  Uri iconUrl(String url) {
    final parsed = Uri.parse(url);
    if (parsed.hasScheme) return parsed;
    return baseUrl.replace(
      path: '$_basePath${parsed.path}',
      query: parsed.hasQuery ? parsed.query : null,
    );
  }

  @override
  Future<ModelProviderIcon?> icon(String url) async {
    final http.Response res;
    try {
      res = await _client.get(iconUrl(url)).timeout(timeout);
    } on TimeoutException {
      throw TransportException('GET $url timed out', timeout: true);
    } on Object catch (e) {
      throw TransportException('GET $url failed: $e');
    }
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw transportErrorOf(
        res.statusCode,
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );
    }
    return ModelProviderIcon(
      bytes: res.bodyBytes,
      contentType: res.headers['content-type'] ?? 'application/octet-stream',
    );
  }

  Future<Object?> _send(
    String method,
    String path, {
    required List<int> ok,
    Map<String, Object?>? body,
    Map<String, String>? query,
    Duration? requestTimeout,
  }) async {
    final effectiveTimeout = requestTimeout ?? timeout;
    final req = http.Request(method, _url(path, query));
    if (body != null) {
      req
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _client.send(req).timeout(effectiveTimeout),
      ).timeout(effectiveTimeout);
    } on TimeoutException {
      throw TransportException('$method $path timed out', timeout: true);
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    if (!ok.contains(res.statusCode)) {
      throw transportErrorOf(
        res.statusCode,
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );
    }
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException catch (e) {
      throw TransportException(
        'malformed answer to $method $path: ${e.message}',
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> providerPlugins() async =>
      _data(await _send('GET', '$_ws/model-provider-plugins', ok: const [200]));

  String _pluginPath(String pluginId) =>
      '$_ws/model-provider-plugins/${pluginId.split('/').map(Uri.encodeComponent).join('/')}';

  @override
  Future<Map<String, Object?>> installProviderPlugin(String pluginId) async => (await _send(
    'POST',
    '${_pluginPath(pluginId)}/install',
    ok: const [200],
    requestTimeout: const Duration(seconds: 120),
  )) as Map<String, Object?>;

  @override
  Future<Map<String, Object?>> providerPluginTask(String taskId) async => (await _send(
    'GET',
    '$_ws/model-provider-plugins/tasks/${Uri.encodeComponent(taskId)}',
    ok: const [200],
  )) as Map<String, Object?>;

  @override
  Future<void> uninstallProviderPlugin(
    String pluginId, {
    required String installationId,
  }) => _send(
    'POST',
    '${_pluginPath(pluginId)}/uninstall',
    ok: const [200],
    body: {'installation_id': installationId},
  );

  void close() => _client.close();

  @override
  Future<Map<String, Object?>> discoverModels(String provider, {required Map<String, Object?> credentials}) async =>
      (await _send(
        'POST',
        '${_p(provider)}/models/discover',
        ok: const [200],
        body: {'credentials': credentials},
        requestTimeout: const Duration(seconds: 30),
      )) as Map<String, Object?>;

  @override
  Future<Map<String, Object?>> probeModel(
    String provider, {
    required Map<String, Object?> credentials,
    required String model,
    required String apiType,
    required bool consent,
  }) async => (await _send(
    'POST',
    '${_p(provider)}/models/probe',
    ok: const [200],
    body: {
      'credentials': credentials,
      'model': model,
      'api_type': apiType,
      'consent': consent,
    },
    requestTimeout: const Duration(seconds: 160),
  )) as Map<String, Object?>;

  @override
  Future<void> createAutofilledModel(
    String provider, {
    required String model,
    required Map<String, Object?> credentials,
    String? discoveryId,
    String? probeId,
  }) => _send(
    'POST',
    '${_p(provider)}/models/autofill',
    ok: const [201],
    body: {
      'model': model,
      'credentials': credentials,
      'discovery_id': ?discoveryId,
      'probe_id': ?probeId,
    },
  );
}
