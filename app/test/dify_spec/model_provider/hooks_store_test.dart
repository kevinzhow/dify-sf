// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/hooks.spec.ts
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/settings/model_provider/system_model_selector.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/model_fakes.dart';
import '_settings_harness.dart';

/// The hooks over the console's queries are WorkspaceModels' (a query read is its getter, an invalidation a refetch
/// recorded by the fake API); the modal handler is showModelModal.
void main() {
  late RecordingModelsApi api;
  late WorkspaceModels store;
  setUp(() {
    api = RecordingModelsApi();
    store = WorkspaceModels(api, fixedLanguage: 'en_US');
  });
  tearDown(() => store.dispose());

  group('hooks', () {
    group('useSystemDefaultModelAndModelList', () {
      List<ProviderWithModels> createMockModelList() => [
        ProviderWithModels.fromJson(providerWithModels('openai', ['gpt-3.5-turbo', 'gpt-4'])),
      ];
      Json createMockDefaultModel([String model = 'gpt-3.5-turbo']) => defaultModelJson('openai', model);

      test('should return default model state when model exists', () {
        final state = SystemDefaultModelState();
        expect(state.selected(systemDefaultModelOf(createMockDefaultModel(), createMockModelList())), (
          provider: 'openai',
          model: 'gpt-3.5-turbo',
        ));
      });

      test('should return undefined when default model is undefined', () {
        expect(SystemDefaultModelState().selected(systemDefaultModelOf(null, createMockModelList())), isNull);
      });

      test('should return undefined when provider not found in model list', () {
        expect(systemDefaultModelOf(defaultModelJson('anthropic', 'claude-3'), createMockModelList()), isNull);
      });

      test('should return undefined when model not found in provider', () {
        expect(systemDefaultModelOf(createMockDefaultModel('gpt-5'), createMockModelList()), isNull);
      });

      test('should update default model state', () {
        final state = SystemDefaultModelState();
        final current = systemDefaultModelOf(createMockDefaultModel(), createMockModelList());
        state.change(current, (provider: 'openai', model: 'gpt-4'));
        expect(state.selected(current), (provider: 'openai', model: 'gpt-4'));
      });

      test('should update state when defaultModel prop changes', () {
        final state = SystemDefaultModelState();
        final list = createMockModelList();
        expect(state.selected(systemDefaultModelOf(createMockDefaultModel(), list)), (
          provider: 'openai',
          model: 'gpt-3.5-turbo',
        ));
        expect(state.selected(systemDefaultModelOf(createMockDefaultModel('gpt-4'), list)), (
          provider: 'openai',
          model: 'gpt-4',
        ));
      });

      test('should handle empty model list', () {
        expect(SystemDefaultModelState().selected(systemDefaultModelOf(createMockDefaultModel(), const [])), isNull);
      });
    });

    group('useDefaultModel', () {
      final mockDefaultModel = defaultModelJson('openai', 'gpt-4');

      test('should fetch default model successfully', () async {
        api.defaults['llm'] = mockDefaultModel;
        await store.invalidateDefaultModel(ModelTypeEnum.textGeneration);
        expect(store.defaultModel(ModelTypeEnum.textGeneration), mockDefaultModel);
        expect(store.isDefaultModelLoading(ModelTypeEnum.textGeneration), isFalse);
        expect(api.callsOf('defaultModel'), [
          {'modelType': 'llm'},
        ]);
      });

      test('should return undefined when data is not available', () async {
        await store.invalidateDefaultModel(ModelTypeEnum.textGeneration);
        expect(store.defaultModel(ModelTypeEnum.textGeneration), isNull);
      });

      test('should keep the query disabled when requested', () {
        // A disabled query is never fetched (the page skips it without plugin preferences): not loading.
        expect(store.isDefaultModelLoading(ModelTypeEnum.textEmbedding), isFalse);
        expect(api.callsOf('defaultModel'), isEmpty);
      });

      test('should handle loading state', () async {
        final gate = api.hold['defaultModel'] = Completer();
        final f = store.invalidateDefaultModel(ModelTypeEnum.textGeneration);
        expect(store.isDefaultModelLoading(ModelTypeEnum.textGeneration), isTrue);
        gate.complete();
        await f;
        expect(store.isDefaultModelLoading(ModelTypeEnum.textGeneration), isFalse);
      });

      test('should call mutate to refetch data', () async {
        api.defaults['llm'] = mockDefaultModel;
        await store.invalidateDefaultModel(ModelTypeEnum.textGeneration);
        await store.invalidateDefaultModel(ModelTypeEnum.textGeneration);
        expect(api.callsOf('defaultModel'), hasLength(2));
      });
    });

    group('useModelListAndDefaultModel', () {
      test('should return both model list and default model', () async {
        api.modelsByType['llm'] = [
          {'provider': 'openai', 'models': <Object?>[]},
        ];
        api.defaults['llm'] = {
          'model': 'gpt-4',
          'provider': {'provider': 'openai'},
        };
        await Future.wait([store.updateModelList('llm'), store.invalidateDefaultModel('llm')]);
        expect(store.modelListJson('llm'), api.modelsByType['llm']);
        expect(store.defaultModel('llm'), api.defaults['llm']);
      });

      test('should handle undefined values', () async {
        await Future.wait([store.updateModelList('llm'), store.invalidateDefaultModel('llm')]);
        expect(store.modelList('llm'), isEmpty);
        expect(store.defaultModel('llm'), isNull);
      });
    });

    group('useModelListAndDefaultModelAndCurrentProviderAndModel', () {
      test('should return complete data structure', () async {
        api.modelsByType['llm'] = [
          providerWithModels('openai', ['gpt-4']),
        ];
        api.defaults['llm'] = defaultModelJson('openai', 'gpt-4');
        await Future.wait([store.updateModelList('llm'), store.invalidateDefaultModel('llm')]);
        final d = store.defaultModel('llm')!;
        final current = getCurrentProviderAndModel(store.modelList('llm'), (
          provider: (d['provider']! as Map)['provider'] as String,
          model: d['model']! as String,
        ));
        expect(store.modelListJson('llm'), api.modelsByType['llm']);
        expect(d, api.defaults['llm']);
        expect(current.currentProvider?.provider, 'openai');
        expect(current.currentModel?.model, 'gpt-4');
      });

      test('should handle missing default model', () async {
        api.modelsByType['llm'] = [
          {'provider': 'openai', 'models': <Object?>[], 'status': 'active'},
        ];
        await Future.wait([store.updateModelList('llm'), store.invalidateDefaultModel('llm')]);
        final current = getCurrentProviderAndModel(store.modelList('llm'), (provider: '', model: ''));
        expect(current.currentProvider, isNull);
        expect(current.currentModel, isNull);
      });
    });

    group('useUpdateModelList', () {
      test('should invalidate model list queries', () async {
        await store.updateModelList(ModelTypeEnum.textGeneration);
        expect(api.callsOf('modelsOfType'), [
          {'modelType': 'llm'},
        ]);
      });

      test('should handle multiple model types', () async {
        await Future.wait([
          store.updateModelList(ModelTypeEnum.textGeneration),
          store.updateModelList(ModelTypeEnum.textEmbedding),
          store.updateModelList(ModelTypeEnum.rerank),
        ]);
        expect(api.callsOf('modelsOfType'), hasLength(3));
      });
    });

    group('useInvalidateDefaultModel', () {
      test('should invalidate default model queries', () async {
        await store.invalidateDefaultModel(ModelTypeEnum.textGeneration);
        expect(api.callsOf('defaultModel'), [
          {'modelType': 'llm'},
        ]);
      });

      test('should handle multiple model types', () async {
        await Future.wait([
          store.invalidateDefaultModel(ModelTypeEnum.textGeneration),
          store.invalidateDefaultModel(ModelTypeEnum.textEmbedding),
          store.invalidateDefaultModel(ModelTypeEnum.rerank),
        ]);
        expect(api.callsOf('defaultModel'), hasLength(3));
      });
    });

    group('useUpdateModelProviders', () {
      test('should invalidate model providers queries', () async {
        await store.loadProviderDetails();
        api.calls.clear();
        await store.updateModelProviders();
        expect(api.callsOf('summaries'), hasLength(1));
        expect(api.callsOf('providers'), hasLength(1));
      });

      test('should be callable multiple times', () async {
        await store.loadProviderDetails();
        api.calls.clear();
        await store.updateModelProviders();
        await store.updateModelProviders();
        await store.updateModelProviders();
        expect(api.calls, hasLength(6));
      });
    });

    group('useRefreshModel', () {
      Json createMockProvider({String status = 'active', List<String> types = const ['llm', 'text-embedding']}) =>
          providerJson(
            provider: 'openai',
            supportedModelTypes: types,
            customConfiguration: {'status': status},
          );

      test('should refresh providers and model lists', () async {
        await store.loadProviderDetails();
        api.calls.clear();
        await store.refreshModel(createMockProvider());
        expect(api.callsOf('summaries'), hasLength(1));
        expect(api.callsOf('providers'), hasLength(1));
        expect(api.callsOf('modelsOfType'), [
          {'modelType': 'llm'},
          {'modelType': 'text-embedding'},
        ]);
        // The provider's own model list is only marked stale.
        expect(api.callsOf('providerModels'), isEmpty);
      });

      test('should expand target provider list when refreshModelList is true and custom config is active', () async {
        await store.refreshModel(createMockProvider(), modelType: 'llm', refreshModelList: true);
        expect(store.isExpanded('openai'), isTrue);
        expect(api.callsOf('providerModels'), [
          {'provider': 'openai'},
        ]);
        expect(api.callsOf('modelsOfType').where((c) => c['modelType'] == 'llm'), isNotEmpty);
      });

      test('should not expand provider list when custom config is not active', () async {
        await store.refreshModel(createMockProvider(status: 'no-configure'), refreshModelList: true);
        expect(store.isExpanded('openai'), isFalse);
        expect(api.callsOf('providerModels'), isEmpty);
      });

      test('adding the first model uses refreshed configuration rather than the stale unconfigured form', () async {
        api.summaryData = [createMockProvider()];
        api.providerModelsData['openai'] = [modelJson('new-model', fetchFrom: 'customizable-model')];
        await store.refreshModel(createMockProvider(status: 'no-configure'), refreshModelList: true);
        expect(store.isExpanded('openai'), isTrue);
        expect(store.providerModels('openai')?.single.model, 'new-model');
      });

      test('removing the last model clears the visible list even after the provider becomes unconfigured', () async {
        api.providerModelsData['openai'] = [modelJson('old-model', fetchFrom: 'customizable-model')];
        await store.fetchProviderModels('openai');
        api.summaryData = [createMockProvider(status: 'no-configure')];
        api.providerModelsData['openai'] = [];
        await store.refreshModel(createMockProvider(), refreshModelList: true);
        expect(store.providerModels('openai'), isEmpty);
      });

      test('should refetch active model provider list when custom refresh callback is absent', () async {
        await store.refreshModel(createMockProvider(), refreshModelList: true);
        expect(api.callsOf('providerModels'), [
          {'provider': 'openai'},
        ]);
      });

      test('should invalidate all supported model types when __model_type is undefined', () async {
        await store.refreshModel(createMockProvider(), refreshModelList: true);
        expect(api.callsOf('modelsOfType').map((c) => c['modelType']).toSet(), {'llm', 'text-embedding'});
      });

      test('should handle provider with single model type', () async {
        await store.loadProviderDetails();
        api.calls.clear();
        await store.refreshModel(createMockProvider(types: const ['llm']));
        expect(api.callsOf('summaries'), hasLength(1));
        expect(api.callsOf('providers'), hasLength(1));
        expect(api.callsOf('modelsOfType'), [
          {'modelType': 'llm'},
        ]);
      });
    });

    group('useModelModalHandler', () {
      final provider = providerJson(
        provider: 'openai',
        providerSchemas: const [
          {
            'variable': 'api_key',
            'type': 'secret-input',
            'label': {'en_US': 'API Key'},
            'required': false,
          },
        ],
      );

      Future<BuildContext> open(WidgetTester t) async {
        late BuildContext ctx;
        await renderSettings(
          t,
          Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
          env: envOf(api, models: store),
        );
        return ctx;
      }

      testWidgets('should open model modal with basic configuration', (t) async {
        final context = await open(t);
        unawaited(
          showModelModal(
            context,
            env: envOf(api, models: store),
            provider: provider,
            configurationMethod: ConfigurationMethodEnum.predefinedModel,
          ),
        );
        await settle(t);
        final modal = t.widget<ModelModal>(find.byType(ModelModal));
        expect(modal.provider, provider);
        expect(modal.configurateMethod, ConfigurationMethodEnum.predefinedModel);
        expect(modal.fixedFields, isNull);
        expect(modal.isModelCredential, isFalse);
        expect(modal.credential, isNull);
        expect(modal.model, isNull);
        expect(modal.mode, ModelModalModeEnum.configProviderCredential);
      });

      testWidgets('should open model modal with custom configuration', (t) async {
        final context = await open(t);
        const fixed = (modelName: 'gpt-4', modelType: 'llm');
        unawaited(
          showModelModal(
            context,
            env: envOf(api, models: store),
            provider: provider,
            configurationMethod: ConfigurationMethodEnum.customizableModel,
            fixedFields: fixed,
          ),
        );
        await settle(t);
        final modal = t.widget<ModelModal>(find.byType(ModelModal));
        expect(modal.configurateMethod, ConfigurationMethodEnum.customizableModel);
        expect(modal.fixedFields, fixed);
      });

      testWidgets('should open model modal with extra options', (t) async {
        final context = await open(t);
        const credential = Credential(credentialId: 'cred-1');
        const model = (model: 'gpt-4', modelType: 'llm');
        unawaited(
          showModelModal(
            context,
            env: envOf(api, models: store),
            provider: provider,
            configurationMethod: ConfigurationMethodEnum.predefinedModel,
            isModelCredential: true,
            credential: credential,
            model: model,
            mode: ModelModalModeEnum.configProviderCredential,
            onSave: (_) {},
          ),
        );
        await settle(t);
        final modal = t.widget<ModelModal>(find.byType(ModelModal));
        expect(modal.isModelCredential, isTrue);
        expect(modal.credential, credential);
        expect(modal.model, model);
        expect(modal.mode, ModelModalModeEnum.configProviderCredential);
      });

      testWidgets('should call onUpdate callback when modal is saved', (t) async {
        final context = await open(t);
        final updates = <Map<String, Object?>?>[];
        unawaited(
          showModelModal(
            context,
            env: envOf(api, models: store),
            provider: provider,
            configurationMethod: ConfigurationMethodEnum.predefinedModel,
            onSave: updates.add,
          ),
        );
        await settle(t);
        await t.enterText(
          find.descendant(of: find.byKey(const ValueKey('form-input-api_key')), matching: find.byType(EditableText)),
          'sk-new',
        );
        await t.tap(find.byKey(const ValueKey('model-modal-save')));
        await settle(t);
        expect(updates.single, {'api_key': 'sk-new'});
        expect(find.byType(ModelModal), findsNothing);
      });

      testWidgets('should handle modal without onUpdate callback', (t) async {
        final context = await open(t);
        unawaited(
          showModelModal(
            context,
            env: envOf(api, models: store),
            provider: provider,
            configurationMethod: ConfigurationMethodEnum.predefinedModel,
          ),
        );
        await settle(t);
        await t.tap(find.byKey(const ValueKey('model-modal-save')));
        await settle(t);
        expect(t.takeException(), isNull);
        expect(find.byType(ModelModal), findsNothing);
      });
    });
  });
}
