// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/hooks/__tests__/use-auth-service.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';

void main() {
  group('useAuthService hooks', () {
    test('useGetCredential selects correct source and params', () async {
      final api = RecordingModelsApi()..providerCredentialData = {'data': 'test'};
      final env = envOf(api);
      final provider = providerJson(provider: 'openai');

      // Provider case.
      await loadCredentialData(
        env,
        provider,
        providerFormSchemaPredefined: true,
        credential: const Credential(credentialId: 'cred-123'),
      );
      expect(api.callsOf('providerCredentials'), [
        {'provider': 'openai', 'credentialId': 'cred-123'},
      ]);

      // Model case.
      await loadCredentialData(
        env,
        provider,
        providerFormSchemaPredefined: false,
        isModelCredential: true,
        credential: const Credential(credentialId: 'cred-123'),
        model: (model: 'gpt-4', modelType: ModelTypeEnum.textGeneration),
      );
      expect(api.callsOf('modelCredentials'), [
        {
          'provider': 'openai',
          'model': 'gpt-4',
          'modelType': 'llm',
          'configFrom': 'custom-model',
          'credentialId': 'cred-123',
        },
      ]);

      // Nothing to load: no credential (provider), neither credential nor model (model).
      expect(loadCredentialData(env, provider, providerFormSchemaPredefined: true), isNull);
      expect(loadCredentialData(env, provider, providerFormSchemaPredefined: true, isModelCredential: true), isNull);
    });

    test('useAuthService provides correct services for provider and model', () async {
      final api = RecordingModelsApi();
      final env = envOf(api);
      final provider = providerJson(provider: 'openai');
      const credential = Credential(credentialId: 'c1');
      const model = (model: 'gpt-4', modelType: 'llm');
      final forProvider = ModelAuth(
        env: env,
        provider: provider,
        configurationMethod: ConfigurationMethodEnum.predefinedModel,
      );
      final forModel = ModelAuth(
        env: env,
        provider: provider,
        configurationMethod: ConfigurationMethodEnum.customizableModel,
        isModelCredential: true,
      );

      await forProvider.handleSaveCredential(credentials: const {'k': 'v'});
      await forProvider.handleSaveCredential(credentialId: 'c1', credentials: const {'k': 'v'});
      forProvider.openConfirmDelete(credential: credential);
      await forProvider.handleConfirmDelete();
      await forProvider.handleActiveCredential(credential);

      await forModel.handleSaveCredential(credentials: const {'k': 'v'}, model: 'gpt-4', modelType: 'llm');
      await forModel.handleSaveCredential(
        credentialId: 'c1',
        credentials: const {'k': 'v'},
        model: 'gpt-4',
        modelType: 'llm',
      );
      forModel.openConfirmDelete(credential: credential, model: model);
      await forModel.handleConfirmDelete();
      await forModel.handleActiveCredential(credential, model);

      final writes = [
        for (final (name, _) in api.calls)
          if (!const {'summaries', 'providers', 'modelsOfType', 'providerModels'}.contains(name)) name,
      ];
      expect(writes, [
        'createProviderCredential',
        'updateProviderCredential',
        'deleteProviderCredential',
        'switchProviderCredential',
        'createModelCredential',
        'updateModelCredential',
        'deleteModelCredential',
        'switchModelCredential',
      ]);
    });
  });
}
