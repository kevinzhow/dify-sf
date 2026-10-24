import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth/auth_api.dart';
import 'auth/auth_session.dart';
import 'client/transport.dart';

typedef ToolJson = Map<String, Object?>;

/// Installed tools and scoped authorization. Secret values are write-only.
class ToolsApi {
  ToolsApi(this.baseUrl, {TokenProvider? auth, http.Client? client})
    : _client = auth == null ? (client ?? http.Client()) : AuthenticatedClient(client ?? http.Client(), auth);
  final Uri baseUrl;
  final http.Client _client;
  static const _root = '/v1/workspaces/current';
  String _provider(String id) => '$_root/tool-provider/builtin/${id.split('/').map(Uri.encodeComponent).join('/')}';
  Future<Object?> _send(String method, String path, [ToolJson? body]) async {
    final prefix = baseUrl.path.replaceFirst(RegExp(r'/$'), '');
    final request = http.Request(
      method,
      baseUrl.replace(
        path: '$prefix${Uri.parse(path).path}',
        query: Uri.parse(path).query.isEmpty ? null : Uri.parse(path).query,
        fragment: null,
      ),
    );
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 60)),
    );
    final Object? value = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = value is Map ? value['error'] : null;
      throw TransportException(
        error is Map ? '${error['message']}' : 'Tool request failed',
        statusCode: response.statusCode,
        code: error is Map ? error['code'] as String? : null,
      );
    }
    return value;
  }

  List<ToolJson> _list(Object? value) {
    if (value is! List) throw const TransportException('Invalid tool response');
    return value.map((e) => (e as Map).cast<String, Object?>()).toList();
  }

  Future<List<ToolJson>> providers() async => [
    for (final provider in _list(await _send('GET', '$_root/tool-providers')))
      {
        ...provider,
        for (final key in ['icon', 'icon_dark'])
          if (provider[key] is String && (provider[key] as String).startsWith('/'))
            key: baseUrl.resolve(provider[key] as String).toString(),
      },
  ];
  Future<List<ToolJson>> workflowProviders() async => _list(await _send('GET', '$_root/tools/workflow'));
  Future<ToolJson> workflowToolPreview(String appId) async => (await _send(
    'GET',
    '$_root/tool-provider/workflow/preview?${Uri(queryParameters: {'workflow_app_id': appId}).query}',
  ) as Map).cast<String, Object?>();
  Future<void> saveWorkflowTool(ToolJson value, {String? id}) async {
    await _send('POST', '$_root/tool-provider/workflow/${id == null ? 'create' : 'update'}', {
      ...value,
      'workflow_tool_id': ?id,
    });
  }

  Future<void> deleteWorkflowTool(String id) async {
    await _send('POST', '$_root/tool-provider/workflow/delete', {'workflow_tool_id': id});
  }

  Future<List<ToolJson>> credentials(String provider) async =>
      _list(await _send('GET', '${_provider(provider)}/credentials'));
  Future<void> saveCredential(
    String provider, {
    String? id,
    required String name,
    required ToolJson credentials,
    bool shared = false,
  }) async {
    await _send(
      'POST',
      '${_provider(provider)}/${id == null ? 'add' : 'update'}',
      {
        'credential_id': ?id,
        'name': name,
        'credentials': credentials,
        'is_team_authorization': shared,
      },
    );
  }

  Future<void> deleteCredential(String provider, String id) async {
    await _send('POST', '${_provider(provider)}/delete', {'credential_id': id});
  }

  Future<List<ToolJson>> runtimeParameters(String provider, String tool, {String? credentialId}) async => _list(
    await _send('POST', '${_provider(provider)}/tools/${Uri.encodeComponent(tool)}/parameters', {
      'credential_id': ?credentialId,
    }),
  );
  Future<List<ToolJson>> dynamicOptions(
    String provider,
    String tool,
    String parameter, {
    String? credentialId,
  }) async => _list(
    await _send('POST', '${_provider(provider)}/dynamic-options', {
      'tool': tool,
      'parameter': parameter,
      'credential_id': ?credentialId,
    }),
  );
  void close() => _client.close();
}
