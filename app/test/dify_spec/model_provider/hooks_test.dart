// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/hooks.spec.ts
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

ModelItem _item(String model, String label, {String status = ModelStatusEnum.active}) =>
    ModelItem(model: model, label: {'en_US': label, 'zh_Hans': label}, status: status);

void main() {
  group('hooks', () {
    group('useLanguage', () {
      test('should replace hyphen with underscore in locale', () {
        expect(languageOfLocale('en-US'), 'en_US');
      });

      test('should return locale as is if no hyphen exists', () {
        expect(languageOfLocale('enUS'), 'enUS');
      });

      test('should handle Chinese locale', () {
        expect(languageOfLocale('zh-Hans'), 'zh_Hans');
      });

      test('should only replace the first hyphen when multiple exist', () {
        expect(languageOfLocale('en-GB-custom'), 'en_GB-custom');
      });
    });

    group('getCurrentProviderAndModel', () {
      List<ProviderWithModels> createModelList() => [
        ProviderWithModels(
          provider: 'openai',
          iconSmall: const {'en_US': 'icon', 'zh_Hans': 'icon'},
          label: const {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
          models: [_item('gpt-3.5-turbo', 'GPT-3.5'), _item('gpt-4', 'GPT-4')],
        ),
      ];

      test('should find current provider and model', () {
        final result = getCurrentProviderAndModel(createModelList(), (provider: 'openai', model: 'gpt-4'));

        expect(result.currentProvider?.provider, 'openai');
        expect(result.currentModel?.model, 'gpt-4');
      });

      test('should return undefined when provider not found', () {
        final result = getCurrentProviderAndModel(createModelList(), (provider: 'anthropic', model: 'claude-3'));

        expect(result.currentProvider, isNull);
        expect(result.currentModel, isNull);
      });

      test('should return undefined when model not found', () {
        final result = getCurrentProviderAndModel(createModelList(), (provider: 'openai', model: 'gpt-5'));

        expect(result.currentProvider?.provider, 'openai');
        expect(result.currentModel, isNull);
      });

      test('should handle undefined default model', () {
        final result = getCurrentProviderAndModel(createModelList(), null);

        expect(result.currentProvider, isNull);
        expect(result.currentModel, isNull);
      });

      test('should handle empty model list', () {
        final result = getCurrentProviderAndModel(const [], (provider: 'openai', model: 'gpt-4'));

        expect(result.currentProvider, isNull);
        expect(result.currentModel, isNull);
      });
    });

    group('useTextGenerationCurrentProviderAndModelAndModelList', () {
      List<ProviderWithModels> createModelList() => [
        ProviderWithModels(
          provider: 'openai',
          iconSmall: const {'en_US': 'icon', 'zh_Hans': 'icon'},
          label: const {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
          models: [_item('gpt-4', 'GPT-4')],
        ),
        ProviderWithModels(
          provider: 'anthropic',
          iconSmall: const {'en_US': 'icon', 'zh_Hans': 'icon'},
          label: const {'en_US': 'Anthropic', 'zh_Hans': 'Anthropic'},
          models: [_item('claude-3', 'Claude 3', status: 'no-configure')],
          status: 'no-configure',
        ),
      ];
      ModelCatalog catalog(List<ProviderWithModels> list) =>
          ModelCatalog(modelLists: {ModelTypeEnum.textGeneration: list});

      test('should return all text generation model lists', () {
        final modelList = createModelList();
        final result = catalog(modelList);

        expect(result.textGenerationModelList, modelList);
        expect(result.activeTextGenerationModelList, hasLength(1));
        expect(result.activeTextGenerationModelList[0].provider, 'openai');
      });

      test('should filter active models correctly', () {
        final result = catalog(createModelList());

        expect(result.activeTextGenerationModelList, hasLength(1));
        expect(result.activeTextGenerationModelList[0].status, ModelStatusEnum.active);
      });

      test('should find current provider and model', () {
        final result = getCurrentProviderAndModel(catalog(createModelList()).textGenerationModelList, (
          provider: 'openai',
          model: 'gpt-4',
        ));

        expect(result.currentProvider?.provider, 'openai');
        expect(result.currentModel?.model, 'gpt-4');
      });

      test('should handle empty model list', () {
        final result = catalog(const []);
        final current = getCurrentProviderAndModel(result.textGenerationModelList, null);

        expect(result.textGenerationModelList, isEmpty);
        expect(result.activeTextGenerationModelList, isEmpty);
        expect(current.currentProvider, isNull);
        expect(current.currentModel, isNull);
      });
    });
  });
}
