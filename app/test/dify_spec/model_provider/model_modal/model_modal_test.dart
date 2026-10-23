// dify-spec: web/app/components/header/account-setting/model-provider-page/model-modal/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json createProvider({String provider = 'openai', List<Json> schemas = const [], List<Json> modelSchemas = const []}) =>
    providerJson(
      provider: provider,
      providerSchemas: schemas,
      modelSchemas: modelSchemas,
      help: {'title': i18n('Help'), 'url': i18n('https://example.com')},
      customConfiguration: const {'status': 'active', 'available_credentials': <Object?>[]},
    );

const apiKeySchema = {
  'variable': 'api_key',
  'type': 'secret-input',
  'label': {'en_US': 'API Key'},
  'required': false,
};
const apiProtocolSchema = {
  'variable': 'api_protocol',
  'type': 'select',
  'label': {'en_US': 'API Protocol'},
  'options': [
    {
      'value': 'chat',
      'label': {'en_US': 'Chat'},
    },
  ],
};

late RecordingModelsApi api;
final cancels = <int>[];
final saves = <Map<String, Object?>>[];

Future<void> renderModal(
  WidgetTester t, {
  Json? provider,
  String configurateMethod = ConfigurationMethodEnum.predefinedModel,
  ModelModalModeEnum mode = ModelModalModeEnum.configProviderCredential,
  CustomModel? model,
  Credential? credential,
  CustomModelFixedFields? fixedFields,
  bool isModelCredential = false,
  RecordingModelsApi? withApi,
}) async {
  api = withApi ?? RecordingModelsApi();
  cancels.clear();
  saves.clear();
  await renderSettings(
    t,
    ModelModal(
      key: UniqueKey(),
      provider: provider ?? createProvider(),
      configurateMethod: configurateMethod,
      mode: mode,
      model: model,
      credential: credential,
      fixedFields: fixedFields,
      isModelCredential: isModelCredential,
      onCancel: () => cancels.add(1),
      onSave: saves.add,
    ),
    env: envOf(api),
  );
}

Finder field(String name) =>
    find.descendant(of: find.byKey(ValueKey('form-input-$name')), matching: find.byType(EditableText));

const tip = 'common.modelProvider.auth.openAIResponsesAPITip';

void main() {
  group('ModelModal', () {
    testWidgets('should show title, description, and loading state for predefined models', (t) async {
      final slow = RecordingModelsApi();
      slow.hold['providerCredentials'] = Completer();
      await renderModal(
        t,
        credential: const Credential(credentialId: 'c1'),
        withApi: slow,
      );
      expect(find.text('common.modelProvider.auth.apiKeyModal.title'), findsOneWidget);
      expect(find.text('common.modelProvider.auth.apiKeyModal.desc'), findsOneWidget);
      expect(find.bySemanticsLabel('common.loading'), findsOneWidget);
      expect(isEnabled('common.operation.save'), isFalse);
      slow.hold['providerCredentials']!.complete();
      await settle(t);

      await renderModal(t, configurateMethod: ConfigurationMethodEnum.customizableModel);
      expect(find.text('common.modelProvider.auth.apiKeyModal.desc'), findsNothing);

      await renderModal(
        t,
        mode: ModelModalModeEnum.configModelCredential,
        model: (model: 'gpt-4', modelType: ModelTypeEnum.textGeneration),
      );
      expect(find.text('common.modelProvider.auth.addModelCredential'), findsOneWidget);
    });

    testWidgets('should reveal the credential label when adding a new credential', (t) async {
      await renderModal(t, mode: ModelModalModeEnum.addCustomModelToModelList);
      expect(find.text('COMMON.MODELPROVIDER.AUTH.MODELCREDENTIAL'), findsNothing);
      await t.tap(find.byKey(const ValueKey('credential-selector-trigger')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('credential-selector-add-new')));
      await settle(t);
      expect(find.text('COMMON.MODELPROVIDER.AUTH.MODELCREDENTIAL'), findsOneWidget);
    });

    testWidgets('should show the Responses API tip only for official OpenAI credential forms', (t) async {
      await renderModal(
        t,
        provider: createProvider(provider: 'langgenius/openai/openai', schemas: const [apiProtocolSchema]),
      );
      expect(find.text(tip), findsOneWidget);

      await renderModal(t, provider: createProvider(schemas: const [apiProtocolSchema]));
      expect(find.text(tip), findsOneWidget);

      await renderModal(t);
      expect(find.text(tip), findsNothing);

      await renderModal(
        t,
        provider: createProvider(provider: 'langgenius/azure_openai/azure_openai', schemas: const [apiProtocolSchema]),
      );
      expect(find.text(tip), findsNothing);
    });

    testWidgets('should show the Responses API tip when adding a new custom model credential', (t) async {
      final provider = createProvider(modelSchemas: const [apiProtocolSchema]);
      await renderModal(
        t,
        provider: provider,
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configCustomModel,
      );
      expect(find.text(tip), findsOneWidget);

      await renderModal(
        t,
        provider: provider,
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configModelCredential,
        model: (model: 'gpt-5.6', modelType: ModelTypeEnum.textGeneration),
      );
      expect(find.text(tip), findsOneWidget);

      await renderModal(
        t,
        provider: provider,
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.addCustomModelToModelList,
      );
      expect(find.text(tip), findsNothing);
      await t.tap(find.byKey(const ValueKey('credential-selector-trigger')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('credential-selector-add-new')));
      await settle(t);
      expect(find.text(tip), findsOneWidget);
    });

    testWidgets('should call onCancel when the cancel button is clicked', (t) async {
      await renderModal(t);
      await t.tap(find.byKey(const ValueKey('model-modal-cancel')));
      expect(cancels, hasLength(1));
    });

    testWidgets('should call onCancel when the escape key is pressed', (t) async {
      // The modal is shown by showModelModal (Dify's modal context): Escape closes the dialog route.
      api = RecordingModelsApi();
      late BuildContext context;
      await renderSettings(
        t,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
        env: envOf(api),
      );
      unawaited(
        showModelModal(
          context,
          env: envOf(api),
          provider: createProvider(),
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
        ),
      );
      await settle(t);
      expect(find.byType(ModelModal), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(find.byType(ModelModal), findsNothing);
    });

    testWidgets('should confirm deletion when a delete dialog is shown', (t) async {
      final withCredential = RecordingModelsApi()..providerCredentialData = {'api_key': 'secret'};
      await renderModal(
        t,
        provider: createProvider(schemas: const [apiKeySchema]),
        credential: const Credential(credentialId: 'cred-1'),
        withApi: withCredential,
      );
      await t.tap(find.byKey(const ValueKey('model-modal-remove')));
      await settle(t);
      expect(find.text('common.modelProvider.confirmDelete'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('alert-confirm')));
      await settle(t);
      expect(api.callsOf('deleteProviderCredential'), [
        {'provider': 'openai', 'credentialId': 'cred-1'},
      ]);
      expect(cancels, hasLength(1));
    });

    testWidgets('should handle save flows for different modal modes', (t) async {
      // Adding a custom model: the model name and type, then its credential.
      await renderModal(
        t,
        provider: createProvider(modelSchemas: const [apiKeySchema]),
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configCustomModel,
        isModelCredential: true,
      );
      await t.enterText(field('__model_name'), 'custom-model');
      // Dify's model type select starts empty (the form's default values are `{}`).
      await t.tap(find.byKey(const ValueKey('form-select-__model_type')));
      await settle(t);
      await t.tap(find.text('LLM').last);
      await settle(t);
      await t.enterText(field('__authorization_name__'), 'Auth Name');
      await t.enterText(field('api_key'), 'secret');
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('createModelCredential'), [
        {
          'provider': 'openai',
          'model': 'custom-model',
          'modelType': 'llm',
          'credentials': {'api_key': 'secret', '__model_name': 'custom-model', '__model_type': 'llm'},
          'name': 'Auth Name',
        },
      ]);
      expect(saves.single, {
        'api_key': 'secret',
        '__model_name': 'custom-model',
        '__model_type': 'llm',
        '__authorization_name__': 'Auth Name',
      });

      // A custom model's credential.
      const model = (model: 'gpt-4', modelType: ModelTypeEnum.textGeneration);
      final stored = RecordingModelsApi()
        ..modelCredentialData = {
          'credentials': {'api_key': 'abc'},
        };
      await renderModal(
        t,
        provider: createProvider(modelSchemas: const [apiKeySchema]),
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configModelCredential,
        isModelCredential: true,
        model: model,
        credential: const Credential(credentialId: 'cred-123', credentialName: 'Model Auth'),
        withApi: stored,
      );
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('updateModelCredential'), [
        {
          'provider': 'openai',
          'model': 'gpt-4',
          'modelType': 'llm',
          'credentialId': 'cred-123',
          // The untouched secret stays the stored one.
          'credentials': {'api_key': '[__HIDDEN__]', '__model_name': 'gpt-4', '__model_type': 'llm'},
          'name': 'Model Auth',
        },
      ]);

      // A provider credential.
      await renderModal(t, provider: createProvider(schemas: const [apiKeySchema]));
      await t.enterText(field('__authorization_name__'), 'Provider Auth');
      await t.enterText(field('api_key'), 'provider-key');
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('createProviderCredential'), [
        {
          'provider': 'openai',
          'credentials': {'api_key': 'provider-key'},
          'name': 'Provider Auth',
        },
      ]);

      // Adding a model back with an existing credential.
      final existing = RecordingModelsApi()
        ..modelCredentialData = {
          'available_credentials': [
            {'credential_id': 'existing', 'credential_name': 'Existing'},
          ],
        };
      await renderModal(
        t,
        provider: createProvider(modelSchemas: const [apiKeySchema]),
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.addCustomModelToModelList,
        isModelCredential: true,
        model: model,
        withApi: existing,
      );
      await t.tap(find.byKey(const ValueKey('credential-selector-trigger')));
      await settle(t);
      await t.tap(find.text('Existing'));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('switchModelCredential'), [
        {'provider': 'openai', 'model': 'gpt-4', 'modelType': 'llm', 'credentialId': 'existing'},
      ]);
      expect(cancels, hasLength(1));

      // Adding a model back with a new credential.
      await renderModal(
        t,
        provider: createProvider(modelSchemas: const [apiKeySchema]),
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.addCustomModelToModelList,
        isModelCredential: true,
        model: model,
      );
      await t.tap(find.byKey(const ValueKey('credential-selector-trigger')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('credential-selector-add-new')));
      await settle(t);
      await t.enterText(field('__authorization_name__'), 'New Auth');
      await t.enterText(field('api_key'), 'new-key');
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('createModelCredential'), [
        {
          'provider': 'openai',
          'model': 'gpt-4',
          'modelType': 'llm',
          'credentials': {'api_key': 'new-key', '__model_name': 'gpt-4', '__model_type': 'llm'},
          'name': 'New Auth',
        },
      ]);

      // An invalid form saves nothing.
      await renderModal(
        t,
        provider: createProvider(
          schemas: const [
            {
              'variable': 'api_key',
              'type': 'secret-input',
              'label': {'en_US': 'API Key'},
              'required': true,
            },
          ],
        ),
      );
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('createProviderCredential'), isEmpty);

      // Remove: an existing credential with values.
      final removable = RecordingModelsApi()..providerCredentialData = {'api_key': 'value'};
      await renderModal(
        t,
        provider: createProvider(schemas: const [apiKeySchema]),
        credential: const Credential(credentialId: 'remove-1'),
        withApi: removable,
      );
      await t.tap(find.byKey(const ValueKey('model-modal-remove')));
      await settle(t);
      expect(find.text('common.modelProvider.confirmDelete'), findsOneWidget);
    });

    testWidgets('should use fixed model context when saving a model credential without model prop', (t) async {
      await renderModal(
        t,
        provider: createProvider(modelSchemas: const [apiKeySchema]),
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configModelCredential,
        isModelCredential: true,
        fixedFields: (modelName: 'bge-m3', modelType: ModelTypeEnum.textEmbedding),
      );
      await t.enterText(field('__authorization_name__'), 'Xinference Auth');
      await t.enterText(field('api_key'), 'secret');
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('createModelCredential'), [
        {
          'provider': 'openai',
          'model': 'bge-m3',
          'modelType': 'text-embedding',
          'credentials': {'api_key': 'secret'},
          'name': 'Xinference Auth',
        },
      ]);
    });

    testWidgets('should not submit model credential payload when model context is missing', (t) async {
      await renderModal(
        t,
        provider: createProvider(modelSchemas: const [apiKeySchema]),
        configurateMethod: ConfigurationMethodEnum.customizableModel,
        mode: ModelModalModeEnum.configModelCredential,
        isModelCredential: true,
      );
      await t.enterText(field('api_key'), 'secret');
      await t.tap(find.byKey(const ValueKey('model-modal-save')));
      await settle(t);
      expect(api.callsOf('createModelCredential'), isEmpty);
    });
  });
}
