// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/hooks/__tests__/use-auth.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

void main() {
  group('useAuth', () {
    final provider = <String, Object?>{
      'provider': 'openai',
      'allow_custom_token': true,
      'supported_model_types': ['llm'],
      'custom_configuration': {'status': 'active'},
    };
    const credential = Credential(credentialId: 'cred-1', credentialName: 'Primary key');
    const model = (model: 'gpt-4', modelType: ModelTypeEnum.textGeneration);

    late RecordingModelsApi api;
    late BuildContext context;

    Future<ModelAuth> render(
      WidgetTester t, {
      String method = ConfigurationMethodEnum.predefinedModel,
      CustomModelFixedFields? fixedFields,
      bool isModelCredential = false,
      void Function(Map<String, Object?>?)? onUpdate,
      void Function(String)? onRemove,
      ModelModalModeEnum? mode,
    }) async {
      api = RecordingModelsApi();
      final env = envOf(api);
      await renderSettings(
        t,
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
        env: env,
      );
      return ModelAuth(
        env: env,
        provider: provider,
        configurationMethod: method,
        fixedFields: fixedFields,
        isModelCredential: isModelCredential,
        onUpdate: onUpdate,
        onRemove: onRemove,
        mode: mode,
      );
    }

    testWidgets('should open and close delete confirmation state', (t) async {
      final auth = await render(t);
      auth.openConfirmDelete(credential: credential, model: model);
      expect(auth.deleteCredentialId, 'cred-1');
      expect(auth.deleteModel, model);
      auth.closeConfirmDelete();
      expect(auth.deleteCredentialId, isNull);
      expect(auth.deleteModel, isNull);
    });

    testWidgets('should activate credential, notify success, and refresh models', (t) async {
      final auth = await render(t, method: ConfigurationMethodEnum.customizableModel);
      await auth.handleActiveCredential(credential, model);
      await settle(t);
      expect(api.callsOf('switchModelCredential'), [
        {'provider': 'openai', 'model': 'gpt-4', 'modelType': 'llm', 'credentialId': 'cred-1'},
      ]);
      expect(find.text('common.api.actionSuccess'), findsOneWidget);
      // handleRefreshModel(provider, undefined, true): the providers, the lists and the provider's model list.
      expect(api.callsOf('summaries'), isNotEmpty);
      expect(api.callsOf('providerModels'), [
        {'provider': 'openai'},
      ]);
      expect(auth.doingAction, isFalse);
    });

    testWidgets('should close delete dialog without calling services when nothing is pending', (t) async {
      final auth = await render(t);
      await auth.handleConfirmDelete();
      expect(api.callsOf('deleteProviderCredential'), isEmpty);
      expect(api.callsOf('removeCustomModel'), isEmpty);
      expect(auth.deleteCredentialId, isNull);
      expect(auth.deleteModel, isNull);
    });

    testWidgets('should delete credential and call onRemove callback', (t) async {
      final removed = <String>[];
      final auth = await render(t, onRemove: removed.add);
      auth.openConfirmDelete(credential: credential, model: model);
      await auth.handleConfirmDelete();
      expect(api.callsOf('deleteProviderCredential'), [
        {'provider': 'openai', 'credentialId': 'cred-1'},
      ]);
      expect(api.callsOf('removeCustomModel'), isEmpty);
      expect(removed, ['cred-1']);
      expect(auth.deleteCredentialId, isNull);
    });

    testWidgets('should delete model when pending operation has no credential id', (t) async {
      final removed = <String>[];
      final auth = await render(t, method: ConfigurationMethodEnum.customizableModel, onRemove: removed.add);
      auth.openConfirmDelete(model: model);
      await auth.handleConfirmDelete();
      expect(api.callsOf('removeCustomModel'), [
        {'provider': 'openai', 'model': 'gpt-4', 'modelType': 'llm'},
      ]);
      expect(removed, ['']);
    });

    testWidgets('should add or edit credentials and refresh on successful save', (t) async {
      final auth = await render(t);
      await auth.handleSaveCredential(credentials: const {'api_key': 'new-key'});
      await settle(t);
      expect(api.callsOf('createProviderCredential'), [
        {
          'provider': 'openai',
          'credentials': {'api_key': 'new-key'},
          'name': null,
        },
      ]);
      // A new credential refreshes the provider's model list too (refreshModelList).
      expect(api.callsOf('providerModels'), hasLength(1));

      await auth.handleSaveCredential(credentialId: 'cred-1', credentials: const {'api_key': 'updated-key'});
      await settle(t);
      expect(api.callsOf('updateProviderCredential'), [
        {
          'provider': 'openai',
          'credentialId': 'cred-1',
          'credentials': {'api_key': 'updated-key'},
          'name': null,
        },
      ]);
      expect(api.callsOf('providerModels'), hasLength(1));
    });

    testWidgets('should ignore duplicate save requests while an action is in progress', (t) async {
      final auth = await render(t);
      final gate = api.hold['createProviderCredential'] = Completer();
      final first = auth.handleSaveCredential(credentials: const {'api_key': 'first'});
      final second = auth.handleSaveCredential(credentials: const {'api_key': 'second'});
      gate.complete();
      await Future.wait([first, second]);
      expect(api.callsOf('createProviderCredential'), [
        {
          'provider': 'openai',
          'credentials': {'api_key': 'first'},
          'name': null,
        },
      ]);
    });

    testWidgets('should forward modal open arguments', (t) async {
      final updates = <Map<String, Object?>?>[];
      const fixedFields = (modelName: 'gpt-4', modelType: ModelTypeEnum.textGeneration);
      final auth = await render(
        t,
        method: ConfigurationMethodEnum.customizableModel,
        fixedFields: fixedFields,
        isModelCredential: true,
        onUpdate: updates.add,
        mode: ModelModalModeEnum.configModelCredential,
      );
      auth.handleOpenModal(context, credential: credential, model: model);
      await settle(t);
      final modal = t.widget<ModelModal>(find.byType(ModelModal));
      expect(modal.provider, provider);
      expect(modal.configurateMethod, ConfigurationMethodEnum.customizableModel);
      expect(modal.fixedFields, fixedFields);
      expect(modal.isModelCredential, isTrue);
      expect(modal.credential, credential);
      expect(modal.model, model);
      expect(modal.mode, ModelModalModeEnum.configModelCredential);
    });

    testWidgets('should not notify or refresh when handleSaveCredential returns non-success result', (t) async {
      final auth = await render(t);
      // dify-sf's server refuses with an error (Dify's `{result: "error"}`): the server's message is toasted instead.
      api.fail['createProviderCredential'] = Exception('refused');
      await auth.handleSaveCredential(credentials: const {'api_key': 'some-key'});
      await settle(t);
      expect(api.callsOf('createProviderCredential'), hasLength(1));
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsNothing);
      expect(api.callsOf('summaries'), isEmpty);
    });

    testWidgets(
      'should pass undefined model and model_type when handleActiveCredential is called without a model parameter',
      (t) async {
        final auth = await render(t);
        await auth.handleActiveCredential(credential);
        expect(api.callsOf('switchProviderCredential'), [
          {'provider': 'openai', 'credentialId': 'cred-1'},
        ]);
        expect(api.callsOf('switchModelCredential'), isEmpty);
      },
    );

    testWidgets('should only set deleteCredentialId when openConfirmDelete is called without a model', (t) async {
      final auth = await render(t);
      auth.openConfirmDelete(credential: credential);
      expect(auth.deleteCredentialId, 'cred-1');
      expect(auth.deleteModel, isNull);
    });

    testWidgets('should ignore a second handleConfirmDelete call while the first is still in progress', (t) async {
      final auth = await render(t);
      auth.openConfirmDelete(credential: credential, model: model);
      final gate = api.hold['deleteProviderCredential'] = Completer();
      final first = auth.handleConfirmDelete();
      final second = auth.handleConfirmDelete();
      gate.complete();
      await Future.wait([first, second]);
      expect(api.callsOf('deleteProviderCredential'), hasLength(1));
    });

    testWidgets('should ignore a second handleActiveCredential call while the first is still in progress', (t) async {
      final auth = await render(t);
      final gate = api.hold['switchProviderCredential'] = Completer();
      final first = auth.handleActiveCredential(credential);
      final second = auth.handleActiveCredential(credential);
      gate.complete();
      await Future.wait([first, second]);
      expect(api.callsOf('switchProviderCredential'), hasLength(1));
    });
  });
}
