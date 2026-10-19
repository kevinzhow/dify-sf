// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/authorized/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

final mockProvider = <String, Object?>{
  'provider': 'openai',
  'allow_custom_token': true,
  'supported_model_types': ['llm'],
  'custom_configuration': {'status': 'active'},
};
const mockCredentials = [
  Credential(credentialId: 'cred-1', credentialName: 'API Key 1'),
  Credential(credentialId: 'cred-2', credentialName: 'API Key 2'),
];
const mockModel = (model: 'gpt-4', modelType: ModelTypeEnum.textGeneration);
const List<AuthorizedGroup> mockItems = [
  (title: null, model: mockModel, selectedCredential: null, credentials: mockCredentials),
];

Widget mockRenderTrigger(bool open, VoidCallback toggle) =>
    GestureDetector(onTap: toggle, child: Text('Trigger${open ? 'Open' : 'Closed'}'));

late RecordingModelsApi api;

Future<void> render(
  WidgetTester t,
  Authorized authorized, {
  List<String> permissionKeys = managerPermissionKeys,
}) async {
  api = RecordingModelsApi();
  await renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(padding: const EdgeInsets.all(400), child: authorized),
    ),
    env: envOf(api, permissionKeys: permissionKeys),
  );
}

Future<void> openPopup(WidgetTester t) async {
  await t.tap(find.textContaining('Trigger'));
  await settle(t);
}

Future<void> hoverItem(WidgetTester t) => hover(t, find.byKey(const ValueKey('credential-item-cred-1')));

Finder get addApiKey => find.text('common.modelProvider.auth.addApiKey');

void main() {
  group('Authorized', () {
    testWidgets('should render trigger and open popup when trigger is clicked', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
      );
      expect(find.text('TriggerClosed'), findsOneWidget);
      await openPopup(t);
      expect(find.text('TriggerOpen'), findsOneWidget);
      expect(find.byType(AuthorizedItem), findsOneWidget);
      expect(addApiKey, findsOneWidget);
    });

    testWidgets('should call handleOpenModal when triggerOnlyOpenModal is true', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
          triggerOnlyOpenModal: true,
        ),
      );
      await openPopup(t);
      expect(find.byType(ModelModal), findsOneWidget);
    });

    testWidgets('should call onItemClick when credential is selected', (t) async {
      final clicks = <(Credential, Object?)>[];
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
          onItemClick: (c, m) => clicks.add((c, m)),
        ),
      );
      await openPopup(t);
      await t.tap(find.text('API Key 1'));
      await settle(t);
      expect(clicks, [(mockCredentials[0], mockModel)]);
    });

    testWidgets('should call handleActiveCredential when onItemClick is not provided', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
      );
      await openPopup(t);
      await t.tap(find.text('API Key 1'));
      await settle(t);
      expect(api.callsOf('switchModelCredential'), [
        {'provider': 'openai', 'model': 'gpt-4', 'modelType': 'llm', 'credentialId': 'cred-1'},
      ]);
    });

    testWidgets('should call handleOpenModal with fixed model fields when adding model credential', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.customizableModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
          isModelCredential: true,
          fixedFields: (modelName: 'gpt-4', modelType: ModelTypeEnum.textGeneration),
        ),
      );
      await openPopup(t);
      await t.tap(find.text('common.modelProvider.auth.addModelCredential'));
      await settle(t);
      final modal = t.widget<ModelModal>(find.byType(ModelModal));
      expect(modal.credential, isNull);
      expect(modal.model, (model: 'gpt-4', modelType: 'llm'));
    });

    testWidgets('should not render add action when hideAddAction is true', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
          hideAddAction: true,
        ),
      );
      await openPopup(t);
      expect(addApiKey, findsNothing);
    });

    testWidgets('should allow use-only users to switch credentials but not add, edit, or delete them', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
        permissionKeys: const ['credential.use'],
      );
      await openPopup(t);
      await hoverItem(t);
      expect(find.byKey(const ValueKey('credential-edit-cred-1')), findsNothing);
      expect(find.byKey(const ValueKey('credential-delete-cred-1')), findsNothing);
      expect(addApiKey, findsNothing);
      await t.tap(find.text('API Key 1'));
      await settle(t);
      expect(api.callsOf('switchModelCredential'), hasLength(1));
      expect(find.byType(ModelModal), findsNothing);
      expect(find.byKey(const ValueKey('alert-dialog')), findsNothing);
    });

    testWidgets(
      'should allow create-only users to add credentials but not switch, edit, or delete existing credentials',
      (t) async {
        await render(
          t,
          Authorized(
            provider: mockProvider,
            configurationMethod: ConfigurationMethodEnum.predefinedModel,
            items: mockItems,
            renderTrigger: mockRenderTrigger,
          ),
          permissionKeys: const ['credential.create'],
        );
        await openPopup(t);
        await hoverItem(t);
        expect(find.byKey(const ValueKey('credential-edit-cred-1')), findsNothing);
        expect(find.byKey(const ValueKey('credential-delete-cred-1')), findsNothing);
        await t.tap(find.text('API Key 1'), warnIfMissed: false);
        await settle(t);
        expect(api.callsOf('switchModelCredential'), isEmpty);
        await t.tap(addApiKey);
        await settle(t);
        final modal = t.widget<ModelModal>(find.byType(ModelModal));
        expect(modal.credential, isNull);
        expect(modal.model, isNull);
      },
    );

    testWidgets('should allow manage-only users to edit and delete credentials but not switch or add them', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
        permissionKeys: const ['credential.manage'],
      );
      await openPopup(t);
      expect(addApiKey, findsNothing);
      await t.tap(find.text('API Key 1'), warnIfMissed: false);
      await settle(t);
      expect(api.callsOf('switchModelCredential'), isEmpty);
      await hoverItem(t);
      await t.tap(find.byKey(const ValueKey('credential-edit-cred-1')));
      await settle(t);
      final modal = t.widget<ModelModal>(find.byType(ModelModal));
      expect(modal.credential, mockCredentials[0]);
      expect(modal.model, mockModel);
      await t.tap(find.byKey(const ValueKey('model-modal-cancel')));
      await settle(t);
      await openPopup(t);
      await hoverItem(t);
      await t.tap(find.byKey(const ValueKey('credential-delete-cred-1')));
      await settle(t);
      expect(find.byKey(const ValueKey('alert-dialog')), findsOneWidget);
    });

    testWidgets('should show confirm dialog and call confirm handler when delete is confirmed', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
      );
      await openPopup(t);
      await hoverItem(t);
      await t.tap(find.byKey(const ValueKey('credential-delete-cred-1')));
      await settle(t);
      expect(find.text('common.modelProvider.confirmDelete'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('alert-confirm')));
      await settle(t);
      expect(api.callsOf('deleteProviderCredential'), [
        {'provider': 'openai', 'credentialId': 'cred-1'},
      ]);
    });

    testWidgets('should close confirm dialog when deletion is cancelled', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
      );
      await openPopup(t);
      await hoverItem(t);
      await t.tap(find.byKey(const ValueKey('credential-delete-cred-1')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('alert-cancel')));
      await settle(t);
      expect(find.byKey(const ValueKey('alert-dialog')), findsNothing);
      expect(api.callsOf('deleteProviderCredential'), isEmpty);
    });

    testWidgets('should disable the confirm button while deletion is in progress', (t) async {
      await render(
        t,
        Authorized(
          provider: mockProvider,
          configurationMethod: ConfigurationMethodEnum.predefinedModel,
          items: mockItems,
          renderTrigger: mockRenderTrigger,
        ),
      );
      final gate = api.hold['deleteProviderCredential'] = Completer();
      await openPopup(t);
      await hoverItem(t);
      await t.tap(find.byKey(const ValueKey('credential-delete-cred-1')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('alert-confirm')));
      await t.pump();
      expect(isEnabled('common.operation.confirm'), isFalse);
      gate.complete();
      await settle(t);
    });
  });
}
