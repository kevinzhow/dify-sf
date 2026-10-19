// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_list.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

final mockProvider = <String, Object?>{
  'provider': 'langgenius/openai/openai',
  'configurate_methods': ['predefined-model'],
  'system_configuration': {'enabled': true},
  'supported_model_types': ['llm'],
  'custom_configuration': {'status': 'active'},
};

late RecordingModelsApi api;
late WorkspaceModels models;

Future<void> render(
  WidgetTester t,
  Json provider, {
  bool notConfigured = false,
  List<String> permissionKeys = managerPermissionKeys,
  bool rbacEnabled = false,
}) async {
  api = RecordingModelsApi()..providerModelsData['langgenius/openai/openai'] = [modelJson('gpt-4')];
  models = WorkspaceModels(api, fixedLanguage: 'en_US');
  await renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 1400,
        child: ProviderAddedCard(provider: provider, notConfigured: notConfigured),
      ),
    ),
    env: envOf(api, permissionKeys: permissionKeys, rbacEnabled: rbacEnabled, models: models),
  );
}

Finder get showModels => find.byKey(const ValueKey('provider-show-models'));

void main() {
  group('ProviderAddedCard', () {
    testWidgets('should render provider added card component', (t) async {
      await render(t, mockProvider);
      expect(find.byKey(const ValueKey('provider-added-card')), findsOneWidget);
      expect(find.byType(ProviderIcon), findsOneWidget);
      expect(find.byType(CredentialPanel), findsOneWidget);
    });

    testWidgets('should hide credential controls from legacy use-only members', (t) async {
      await render(t, mockProvider, permissionKeys: const ['credential.use']);
      expect(find.byType(CredentialPanel), findsNothing);
      expect(showModels, findsNothing);
      models.setExpanded('langgenius/openai/openai', true);
      await settle(t);
      expect(api.callsOf('providerModels'), isEmpty);
    });

    testWidgets('should use credential permissions when RBAC is enabled', (t) async {
      await render(t, mockProvider, permissionKeys: const ['credential.use'], rbacEnabled: true);
      expect(find.byType(CredentialPanel), findsOneWidget);
    });

    testWidgets('should open, refresh and collapse model list', (t) async {
      await render(t, mockProvider);
      await t.tap(showModels);
      await settle(t);
      expect(api.callsOf('providerModels'), [
        {'provider': 'langgenius/openai/openai'},
      ]);
      expect(find.byType(ModelList), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('model-list-collapse')));
      await settle(t);
      expect(find.byType(ModelList), findsNothing);

      await t.tap(showModels);
      await settle(t);
      expect(find.byType(ModelList), findsOneWidget);
      // Re-opening fetches again (a stale query refetches when it mounts).
      expect(api.callsOf('providerModels'), hasLength(2));

      t.widget<ModelList>(find.byType(ModelList)).onChange!('langgenius/openai/openai');
      await settle(t);
      expect(api.callsOf('providerModels'), hasLength(3));
    });

    testWidgets('should handle concurrent getModelList calls (loading state coverage)', (t) async {
      await render(t, mockProvider);
      final gate = api.hold['providerModels'] = Completer();
      await t.tap(showModels);
      await t.pump();
      expect(api.callsOf('providerModels'), hasLength(1));
      await t.tap(showModels);
      await t.pump();
      expect(api.callsOf('providerModels'), hasLength(1));
      gate.complete();
      await settle(t);
      expect(find.byType(ModelList), findsOneWidget);
    });

    testWidgets('should only react to external expansion for the matching provider', (t) async {
      await render(t, mockProvider);
      models.setExpanded('langgenius/anthropic/anthropic', true);
      await settle(t);
      expect(api.callsOf('providerModels'), isEmpty);
      models.setExpanded('langgenius/openai/openai', true);
      await settle(t);
      expect(api.callsOf('providerModels'), [
        {'provider': 'langgenius/openai/openai'},
      ]);
    });

    testWidgets('should render configure tip when provider is not in quota list and not configured', (t) async {
      await render(t, {...mockProvider, 'provider': 'custom/provider'}, notConfigured: true);
      expect(find.text('common.modelProvider.configureTip'), findsOneWidget);
    });

    testWidgets('should render custom model actions when user can configure models', (t) async {
      final custom = <String, Object?>{
        ...mockProvider,
        'configurate_methods': ['customizable-model'],
        'custom_configuration': {'has_custom_models': true},
      };
      await render(t, custom);
      expect(find.text('common.modelProvider.auth.manageCredentials'), findsOneWidget);
      expect(find.text('common.modelProvider.addModel'), findsOneWidget);

      await render(t, custom, permissionKeys: const ['credential.use', 'credential.create', 'credential.manage']);
      expect(find.text('common.modelProvider.auth.manageCredentials'), findsNothing);
      expect(find.text('common.modelProvider.addModel'), findsNothing);
    });

    testWidgets('should render custom model actions when user can configure models without credential permissions', (
      t,
    ) async {
      await render(
        t,
        {
          ...mockProvider,
          'configurate_methods': ['customizable-model'],
          'custom_configuration': {'has_custom_models': false},
        },
        permissionKeys: const ['plugin.model_config'],
      );
      expect(find.text('common.modelProvider.auth.manageCredentials'), findsNothing);
      expect(find.text('common.modelProvider.addModel'), findsOneWidget);
    });
  });
}
