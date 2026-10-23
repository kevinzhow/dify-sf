// dify-spec: web/app/components/header/account-setting/model-provider-page/model-selector/__tests__/popup-item.spec.tsx
// dify-spec: web/app/components/header/account-setting/model-provider-page/model-selector/__tests__/popup-item.spec.tsx
// Integrates the real credential dropdown (the upstream PopupItem spec mocks DropdownContent).
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/model_fakes.dart';
import 'model_fixtures.dart';

final provider = <String, Object?>{
  'provider': 'openai',
  'label': {'en_US': 'OpenAI'},
  'allow_custom_token': true,
  'supported_model_types': ['llm'],
  'configurate_methods': ['predefined-model'],
  'provider_credential_schema': {'credential_form_schemas': <Object?>[]},
  'custom_configuration': {
    'status': 'active',
    'current_credential_id': 'c1',
    'current_credential_name': 'Primary key',
    'current_credential_usable': true,
    'available_credentials': [
      {'credential_id': 'c1', 'credential_name': 'Primary key'},
      {'credential_id': 'c2', 'credential_name': 'Backup key'},
    ],
  },
};

void main() {
  setUp(useDifyTestTranslator);
  late RecordingModelsApi api;
  late WorkspaceModels models;

  Future<void> render(
    WidgetTester t, {
    List<String> permissions = const ['credential.use', 'credential.create', 'credential.manage'],
    VoidCallback? onHide,
  }) async {
    api = RecordingModelsApi()
      ..summaryData = [provider]
      ..providersData = [provider];
    models = WorkspaceModels(api, fixedLanguage: 'en_US');
    addTearDown(models.dispose);
    await models.refreshSummary();
    final list = [makeModel()];
    await pumpHost(
      t,
      ModelSelector(value: null, models: list, onHide: onHide),
      services: LlmGroupServices(
        models: ModelCatalog(providers: models.providers),
        modelProviderEnv: ModelProviderEnv(models: models, permissionKeys: permissions),
      ),
    );
    await t.tap(named('plugin.detailPanel.configureModel'));
    await settle(t);
  }

  Future<void> open(WidgetTester t) async {
    await t.tap(named('Primary key'));
    await settle(t);
  }

  group('PopupItem', () {
    testWidgets('loads provider details on demand and opens the real dropdown only after they arrive', (t) async {
      await render(t);
      expect(api.callsOf('providers'), isEmpty);
      final gate = api.hold['providers'] = Completer<void>();
      await open(t);
      expect(find.byType(DropdownContent), findsNothing);
      expect(api.callsOf('providers'), hasLength(1));
      gate.complete();
      await settle(t);
      expect(find.byType(DropdownContent), findsOneWidget);
      expect(find.text('Backup key'), findsOneWidget);
      expect(find.byType(ModelSelectorPopup), findsOneWidget);
    });

    testWidgets('should keep the credential dropdown enabled for manage-only users', (t) async {
      await render(t, permissions: ['credential.manage']);
      expect(isDisabled(t, 'Primary key'), isFalse);
      await open(t);
      expect(find.byType(DropdownContent), findsOneWidget);
      expect(find.byKey(const ValueKey('api-key-section-add')), findsNothing);
      final item = t.widget<CredentialItem>(find.byKey(const ValueKey('c2')));
      expect(item.onItemClick, isNull);
      expect(item.disableEdit, isFalse);
      expect(item.disableDelete, isFalse);
    });

    testWidgets('members without credential permissions cannot open or fetch the dropdown', (t) async {
      await render(t, permissions: []);
      expect(find.byType(ModelSelectorPopup), findsOneWidget);
      expect(api.callsOf('providers'), isEmpty);
      // No dropdown button or chevron is rendered without any credential permission.
      expect(named('Primary key'), findsNothing);
      expect(find.text('Primary key'), findsOneWidget);
    });

    testWidgets('use-only members can switch but cannot add, edit or delete credentials', (t) async {
      await render(t, permissions: ['credential.use']);
      await open(t);
      final item = t.widget<CredentialItem>(find.byKey(const ValueKey('c2')));
      expect(item.onItemClick, isNotNull);
      expect(item.disableEdit, isTrue);
      expect(item.disableDelete, isTrue);
      expect(find.byKey(const ValueKey('api-key-section-add')), findsNothing);
      await t.tap(find.text('Backup key'));
      await settle(t);
      expect(api.callsOf('switchProviderCredential'), [
        {'provider': 'openai', 'credentialId': 'c2'},
      ]);
      expect(api.callsOf('summaries'), hasLength(2));
      expect(api.callsOf('modelsOfType'), [
        {'modelType': 'llm'},
      ]);
      expect(find.byType(DropdownContent), findsOneWidget);
      expect(t.widget<ApiKeySection>(find.byType(ApiKeySection)).selectedCredentialId, 'c2');
    });

    testWidgets('a rejected switch restores the selected credential and leaves both popovers open', (t) async {
      await render(t);
      await open(t);
      api.fail['switchProviderCredential'] = StateError('rejected');
      await t.tap(find.text('Backup key'));
      await settle(t);
      expect(t.widget<ApiKeySection>(find.byType(ApiKeySection)).selectedCredentialId, 'c1');
      expect(find.byType(ModelSelectorPopup), findsOneWidget);
      expect(find.byType(DropdownContent), findsOneWidget);
      expect(api.callsOf('summaries'), hasLength(1));
    });

    testWidgets('should close the dropdown through dropdown content callbacks', (t) async {
      var hidden = 0;
      await render(t, onHide: () => hidden++);
      await open(t);
      await t.tap(find.byKey(const ValueKey('api-key-section-add')));
      await settle(t);
      expect(find.byType(ModelModal), findsOneWidget);
      expect(find.byType(DropdownContent), findsNothing);
      expect(find.byType(ModelSelectorPopup), findsNothing);
      expect(hidden, 1);
    });

    testWidgets('failed detail loads can be retried without opening an empty popover', (t) async {
      await render(t);
      api.fail['providers'] = StateError('offline');
      await open(t);
      expect(find.byType(DropdownContent), findsNothing);
      api.fail.remove('providers');
      await open(t);
      expect(find.byType(DropdownContent), findsOneWidget);
      expect(api.callsOf('providers'), hasLength(2));
    });

    testWidgets('Escape closes the credential dropdown and keeps the model list reachable', (t) async {
      await render(t);
      await open(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(find.byType(DropdownContent), findsNothing);
      // Root may also close according to its Escape scope; it must remain operable afterwards.
      if (find.byType(ModelSelectorPopup).evaluate().isEmpty) {
        await t.tap(named('plugin.detailPanel.configureModel'));
        await settle(t);
      }
      expect(find.byType(ModelSelectorPopup), findsOneWidget);
    });
  });
}
