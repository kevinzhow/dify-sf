// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/hooks/__tests__/use-custom-models.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('useCustomModels and useCanAddedModels', () {
    test('extracts custom models from provider correctly', () {
      final provider = <String, Object?>{
        'custom_configuration': {
          'custom_models': [
            {'model': 'gpt-4', 'model_type': 'text-generation'},
            {'model': 'gpt-3.5', 'model_type': 'text-generation'},
          ],
        },
      };
      expect(provider.customModels, hasLength(2));
      expect(provider.customModels[0].model, 'gpt-4');
      expect(<String, Object?>{'custom_configuration': <String, Object?>{}}.customModels, isEmpty);
    });

    test('extracts can_added_models from provider correctly', () {
      final provider = <String, Object?>{
        'custom_configuration': {
          'can_added_models': [
            {'model': 'gpt-4-turbo', 'model_type': 'text-generation'},
          ],
        },
      };
      expect(provider.canAddedModels, hasLength(1));
      expect(provider.canAddedModels[0].model, 'gpt-4-turbo');
      expect(<String, Object?>{'custom_configuration': <String, Object?>{}}.canAddedModels, isEmpty);
    });
  });
}
