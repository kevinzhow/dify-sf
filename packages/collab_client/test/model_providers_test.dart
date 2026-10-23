import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/model_providers_scenario.dart';

TypeMatcher<TransportException> _code(String code) => isA<TransportException>().having((e) => e.code, 'code', code);

void main() {
  group('FakeModelProvidersApi', () {
    test('passes the shared scenario (the same one the real server passes in the conformance test)', () async {
      final owner = FakeModelProvidersApi();
      await modelProvidersScenario(
        owner,
        owner.asRole(AccountRole.normal),
        unique: 'u1',
        stubBase: 'http://stub.invalid',
        validates: true,
      );
    });

    test('a workspace without credentials', () async {
      final api = FakeModelProvidersApi();
      final summaries = await api.summaries();
      expect([for (final s in summaries) s['provider']], [openai, anthropic, 'langgenius/ollama/ollama', oaic]);
      expect(summaries.every((s) => s['is_configured'] == false), isTrue);
      expect(await api.modelsOfType('llm'), isEmpty);
      expect(await api.defaultModel('llm'), isNull);
      expect(await api.parameterRules(openai, 'gpt-4.1'), isEmpty);
      expect((await api.providerModels(openai)).every((m) => m['status'] == 'no-configure'), isTrue);
    });

    test('credentials: names, current, masks, hidden secrets, deleting', () async {
      final api = FakeModelProvidersApi();
      await api.createProviderCredential(openai, credentials: {'openai_api_key': 'sk-first-1234567890'});
      await api.createProviderCredential(openai, credentials: {'openai_api_key': 'sk-second-1234567890'});
      var config = (await api.providers()).first['custom_configuration']! as Map;
      final available = (config['available_credentials']! as List).cast<Map<String, Object?>>();
      expect([for (final c in available) c['credential_name']], ['API KEY 2', 'API KEY 1']);
      final first = available[1]['credential_id']! as String, second = available[0]['credential_id']! as String;
      expect(config['current_credential_id'], first);
      // Form defaults are filled in, secrets masked on read.
      final read = await api.providerCredentials(openai);
      expect(read['openai_api_key'], 'sk-fir************90');
      expect(read['api_protocol'], 'responses');
      // [__HIDDEN__] keeps the stored secret.
      await api.updateProviderCredential(
        openai,
        credentialId: first,
        credentials: {'openai_api_key': hiddenSecret, 'openai_organization': 'org-1'},
      );
      expect((await api.providerCredentials(openai))['openai_api_key'], 'sk-fir************90');
      expect((await api.providerCredentials(openai))['openai_organization'], 'org-1');
      expect((await api.modelsOfType('llm')).single['provider'], openai);
      // The default model is the first active one, and stays.
      final def = await api.defaultModel('llm');
      expect(def!['model'], 'gpt-4.1');
      await api.createProviderCredential(anthropic, credentials: {'anthropic_api_key': 'sk-ant-1'});
      expect((await api.defaultModel('llm'))!['model'], 'gpt-4.1');
      // Deleting the current credential leaves none current; the last one unconfigures.
      await api.deleteProviderCredential(openai, credentialId: first);
      config = (await api.providers()).first['custom_configuration']! as Map;
      expect(config['current_credential_id'], isNull);
      expect(config['status'], 'active');
      expect((await api.providerModels(openai)).every((m) => m['status'] == 'no-configure'), isTrue);
      await api.switchProviderCredential(openai, credentialId: second);
      await api.deleteProviderCredential(openai, credentialId: second);
      expect((await api.summaries()).first['is_configured'], isFalse);
      await expectLater(api.deleteProviderCredential(openai, credentialId: second), throwsA(_code('not_found')));
    });

    test('refusals: roles, a missing secrets key, the validator, form errors', () async {
      final api = FakeModelProvidersApi(secretsKeyMissing: true);
      await expectLater(
        api.createProviderCredential(openai, credentials: {'openai_api_key': 'k'}),
        throwsA(_code('secrets_key_missing')),
      );
      api.secretsKeyMissing = false;
      api.validator = (provider, c) => c['openai_api_key'] == 'right' ? null : 'nope';
      await expectLater(
        api.createProviderCredential(openai, credentials: {'openai_api_key': 'wrong'}),
        throwsA(_code('credential_validation_failed').having((e) => e.message, 'message', 'nope')),
      );
      await api.createProviderCredential(openai, credentials: {'openai_api_key': 'right'});
      expect((await api.validateProviderCredentials(openai, credentials: {'openai_api_key': 'wrong'})).error, 'nope');
      await expectLater(api.createProviderCredential(openai, credentials: {}), throwsA(_code('bad_request')));
      await expectLater(
        api.createProviderCredential(openai, credentials: {'openai_api_key': 'right'}, name: 'x' * 31),
        throwsA(_code('bad_request')),
      );
      final editor = api.asRole(AccountRole.editor);
      await expectLater(editor.disableModel(openai, model: 'gpt-4.1', modelType: 'llm'), throwsA(_code('forbidden')));
      await expectLater(editor.setDefaultModels(const []), throwsA(_code('forbidden')));
      expect(await editor.modelsOfType('llm'), isNotEmpty);
      expect(api.requests['createProviderCredential'], 5);
    });

    test('icons are served from memory', () async {
      final api = FakeModelProvidersApi();
      final s = (await api.summaries()).first;
      final url = (s['icon_small_dark']! as Map)['zh_Hans']! as String;
      expect((await api.icon(url))!.contentType, 'image/svg+xml');
      expect(api.iconUrl(url).toString(), 'http://fake.invalid$url');
      expect(await api.icon('/nowhere'), isNull);
    });
  });

  group('HttpModelProvidersApi', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) answer;
    late HttpModelProvidersApi api;
    setUp(() {
      sent = [];
      answer = (_) => http.Response('{"result":"success"}', 200, headers: {'content-type': 'application/json'});
      api = HttpModelProvidersApi(
        Uri.parse('http://h:1/base/'),
        client: MockClient((req) async {
          sent.add(req);
          return answer(req);
        }),
      );
    });

    test('paths, methods and bodies are Dify\'s', () async {
      answer = (r) => http.Response(jsonEncode({'data': []}), 200);
      await api.summaries();
      await api.providers(modelType: 'llm');
      await api.modelsOfType('text-embedding');
      await api.parameterRules(openai, 'gpt-4o');
      await api.providerModels(oaic);
      expect(
        [for (final r in sent) '${r.method} ${r.url}'],
        [
          'GET http://h:1/base/v1/workspace/model-providers/summary',
          'GET http://h:1/base/v1/workspace/model-providers?model_type=llm',
          'GET http://h:1/base/v1/workspace/models/model-types/text-embedding',
          'GET http://h:1/base/v1/workspace/model-providers/langgenius/openai/openai/models/parameter-rules?model=gpt-4o',
          'GET http://h:1/base/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models',
        ],
      );
      sent.clear();
      answer = (r) => http.Response(
        r.method == 'DELETE' ? '' : '{"result":"success"}',
        r.method == 'DELETE' ? 204 : (r.method == 'POST' && r.url.path.endsWith('/credentials') ? 201 : 200),
      );
      await api.createProviderCredential(openai, credentials: {'openai_api_key': 'k'}, name: 'Main');
      await api.updateProviderCredential(openai, credentialId: 'c1', credentials: {'openai_api_key': hiddenSecret});
      await api.deleteProviderCredential(openai, credentialId: 'c1');
      await api.switchProviderCredential(openai, credentialId: 'c2');
      await api.disableModel(openai, model: 'gpt-4o', modelType: 'llm');
      await api.setDefaultModels([const DefaultModelSetting(modelType: 'llm', provider: openai, model: 'gpt-4o')]);
      await api.deleteModelCredential(oaic, model: 'm', modelType: 'llm', credentialId: 'c3');
      await api.addCustomModel(oaic, model: 'm', modelType: 'llm', credentialId: 'c4');
      await api.removeCustomModel(oaic, model: 'm', modelType: 'llm');
      expect(
        [for (final r in sent) '${r.method} ${r.url.path} ${r.body}'],
        [
          'POST /base/v1/workspace/model-providers/langgenius/openai/openai/credentials {"credentials":{"openai_api_key":"k"},"name":"Main"}',
          'PUT /base/v1/workspace/model-providers/langgenius/openai/openai/credentials {"credential_id":"c1","credentials":{"openai_api_key":"[__HIDDEN__]"}}',
          'DELETE /base/v1/workspace/model-providers/langgenius/openai/openai/credentials {"credential_id":"c1"}',
          'POST /base/v1/workspace/model-providers/langgenius/openai/openai/credentials/switch {"credential_id":"c2"}',
          'PATCH /base/v1/workspace/model-providers/langgenius/openai/openai/models/disable {"model":"gpt-4o","model_type":"llm"}',
          'POST /base/v1/workspace/default-model {"model_settings":[{"model_type":"llm","provider":"langgenius/openai/openai","model":"gpt-4o"}]}',
          'DELETE /base/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models/credentials {"model":"m","model_type":"llm","credential_id":"c3"}',
          'POST /base/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models {"model":"m","model_type":"llm","config_from":"custom-model","credential_id":"c4"}',
          'DELETE /base/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models {"model":"m","model_type":"llm"}',
        ],
      );
    });

    test('answers are unwrapped; validation results and errors are typed', () async {
      answer = (_) => http.Response(jsonEncode({'data': null}), 200);
      expect(await api.defaultModel('llm'), isNull);
      expect(sent.last.url.query, 'model_type=llm');
      answer = (_) => http.Response(
        jsonEncode({
          'data': {'model': 'gpt-4o', 'model_type': 'llm', 'provider': {}},
        }),
        200,
      );
      expect((await api.defaultModel('llm'))!['model'], 'gpt-4o');
      answer = (_) => http.Response(
        jsonEncode({
          'credentials': {'openai_api_key': 'sk-abc************yz'},
        }),
        200,
      );
      expect(await api.providerCredentials(openai, credentialId: 'c 1'), {'openai_api_key': 'sk-abc************yz'});
      expect(sent.last.url.queryParameters, {'credential_id': 'c 1'});
      answer = (_) => http.Response(jsonEncode({'result': 'error', 'error': 'Incorrect API key'}), 200);
      final v = await api.validateProviderCredentials(openai, credentials: {});
      expect(v.ok, isFalse);
      expect(v.error, 'Incorrect API key');
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'secrets_key_missing', 'message': 'no key'},
        }),
        503,
      );
      await expectLater(api.createProviderCredential(openai, credentials: {}), throwsA(_code('secrets_key_missing')));
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'credential_validation_failed', 'message': 'Incorrect API key (HTTP 401)'},
        }),
        400,
      );
      await expectLater(
        api.createModelCredential(oaic, model: 'm', modelType: 'llm', credentials: {}),
        throwsA(_code('credential_validation_failed').having((e) => e.statusCode, 'status', 400)),
      );
    });

    test('icons: relative URLs resolve against the server; bytes and type come back', () async {
      expect(
        api.iconUrl('/v1/workspace/model-providers/langgenius/openai/openai/icon_small/en_US').toString(),
        'http://h:1/base/v1/workspace/model-providers/langgenius/openai/openai/icon_small/en_US',
      );
      expect(api.iconUrl('https://cdn.example.com/x.svg').toString(), 'https://cdn.example.com/x.svg');
      answer = (_) => http.Response('<svg/>', 200, headers: {'content-type': 'image/svg+xml'});
      final icon = await api.icon('/v1/workspace/model-providers/langgenius/openai/openai/icon_small/en_US');
      expect(icon!.isSvg, isTrue);
      expect(utf8.decode(icon.bytes), '<svg/>');
      answer = (_) => http.Response('{"error":{"code":"not_found","message":"x"}}', 404);
      expect(
        await api.icon('/v1/workspace/model-providers/langgenius/anthropic/anthropic/icon_small_dark/en_US'),
        isNull,
      );
    });
  });
}
