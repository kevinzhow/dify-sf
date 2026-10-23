// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/hooks/__tests__/use-credential-data.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';

void main() {
  group('useCredentialData', () {
    test('determines correct config source and parameters', () async {
      final api = RecordingModelsApi();
      final env = envOf(api);
      final provider = providerJson(provider: 'openai');
      const model = (model: 'gpt-4', modelType: 'llm');
      await loadCredentialData(
        env,
        provider,
        providerFormSchemaPredefined: true,
        isModelCredential: true,
        model: model,
      );
      await loadCredentialData(
        env,
        provider,
        providerFormSchemaPredefined: false,
        isModelCredential: true,
        model: model,
      );
      expect([for (final c in api.callsOf('modelCredentials')) c['configFrom']], ['predefined-model', 'custom-model']);
    });

    test('returns appropriate loading and data states', () async {
      final api = RecordingModelsApi()..providerCredentialData = {'api_key': 'test'};
      final gate = api.hold['providerCredentials'] = Completer();
      var done = false;
      final f =
          loadCredentialData(
            envOf(api),
            providerJson(provider: 'openai'),
            providerFormSchemaPredefined: true,
            credential: const Credential(credentialId: 'c1'),
          )!.then((d) {
            done = true;
            return d;
          });
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      gate.complete();
      expect(await f, {
        'credentials': {'api_key': 'test'},
      });
    });

    test('passes credential and model identifier correctly', () async {
      final api = RecordingModelsApi();
      await loadCredentialData(
        envOf(api),
        providerJson(provider: 'openai'),
        providerFormSchemaPredefined: true,
        isModelCredential: true,
        credential: const Credential(credentialId: 'cred-123'),
        model: (model: 'gpt-4', modelType: ''),
      );
      expect(api.callsOf('modelCredentials'), [
        {
          'provider': 'openai',
          'model': 'gpt-4',
          'modelType': '',
          'configFrom': 'predefined-model',
          'credentialId': 'cred-123',
        },
      ]);
    });
  });
}
