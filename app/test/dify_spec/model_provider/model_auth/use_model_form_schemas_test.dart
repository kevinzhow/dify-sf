// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/hooks/__tests__/use-model-form-schemas.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('useModelFormSchemas', () {
    final provider = <String, Object?>{
      'provider': 'openai',
      'provider_credential_schema': {
        'credential_form_schemas': [
          {'type': 'text-input', 'variable': 'api_key', 'label': 'API Key', 'required': true},
        ],
      },
      'model_credential_schema': {
        'credential_form_schemas': [
          {'type': 'text-input', 'variable': 'model_key', 'label': 'Model Key', 'required': true},
        ],
      },
      'supported_model_types': ['text-generation'],
    };

    test('selects correct form schemas based on providerFormSchemaPredefined', () {
      expect(
        modelFormSchemas(provider, providerFormSchemaPredefined: true).formSchemas.any((s) => s.name == 'api_key'),
        isTrue,
      );
      expect(
        modelFormSchemas(provider, providerFormSchemaPredefined: false).formSchemas.any((s) => s.name == 'model_key'),
        isTrue,
      );
      // Only __authorization_name__.
      expect(modelFormSchemas(const {}, providerFormSchemaPredefined: true).formSchemas, hasLength(1));
    });

    test('computes form values correctly for credentials and models', () {
      const credential = Credential(credentialId: '', credentialName: 'Test');
      final r = modelFormSchemas(
        provider,
        providerFormSchemaPredefined: true,
        credentials: const {'api_key': 'val'},
        credential: credential,
        model: (model: 'gpt-4', modelType: 'text-generation'),
      );
      expect(r.formValues['api_key'], 'val');
      expect(r.formValues['__authorization_name__'], 'Test');
      expect(r.formValues['__model_name'], 'gpt-4');
      final noCredentials = modelFormSchemas(provider, providerFormSchemaPredefined: true, credential: credential);
      expect(noCredentials.formValues['__authorization_name__'], 'Test');
    });

    test('handles model name and type schemas for custom models', () {
      expect(modelFormSchemas(provider, providerFormSchemaPredefined: true).modelNameAndTypeFormSchemas, isEmpty);
      final custom = modelFormSchemas(provider, providerFormSchemaPredefined: false);
      expect(custom.modelNameAndTypeFormSchemas, hasLength(2));
      expect(custom.modelNameAndTypeFormSchemas[0].name, '__model_name');
      final withValue = modelFormSchemas(
        provider,
        providerFormSchemaPredefined: false,
        model: (model: 'custom', modelType: 'text'),
      );
      expect(withValue.modelNameAndTypeFormValues['__model_name'], 'custom');
    });
  });
}
