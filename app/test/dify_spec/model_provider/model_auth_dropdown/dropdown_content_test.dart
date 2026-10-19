// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/model-auth-dropdown/__tests__/dropdown-content.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_modal.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json createProvider({Json? customConfiguration}) => {
  'provider': 'test',
  'custom_configuration':
      customConfiguration ??
      {
        'status': 'active',
        'current_credential_id': 'cred-1',
        'current_credential_name': 'My Key',
        'available_credentials': [
          {'credential_id': 'cred-1', 'credential_name': 'My Key'},
          {'credential_id': 'cred-2', 'credential_name': 'Other Key'},
        ],
      },
  'system_configuration': {'enabled': true, 'current_quota_type': 'trial', 'quota_configurations': <Object?>[]},
  'preferred_provider_type': 'system',
  'configurate_methods': ['predefined-model'],
  'supported_model_types': ['llm'],
};

const noCredentials = {'status': 'no-configure', 'available_credentials': <Object?>[]};

CredentialPanelState createState({bool hasCredentials = true}) => CredentialPanelState(
  variant: CardVariant.apiActive,
  priority: UsagePriority.apiKey,
  supportsCredits: true,
  showPrioritySwitcher: true,
  hasCredentials: hasCredentials,
  isCreditsExhausted: false,
  credentialName: 'My Key',
  credits: 100,
);

late RecordingModelsApi api;
var closes = 0;

Future<void> render(
  WidgetTester t,
  Json provider, {
  CredentialPanelState? state,
  List<String> permissionKeys = const ['credential.use', 'credential.create', 'credential.manage'],
}) {
  api = RecordingModelsApi();
  closes = 0;
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: DropdownContent(provider: provider, state: state ?? createState(), onClose: () => closes++),
    ),
    env: envOf(api, permissionKeys: permissionKeys),
  );
}

Future<void> hoverCred2(WidgetTester t) => hover(t, find.byKey(const ValueKey('credential-item-cred-2')));
Finder get edit2 => find.byKey(const ValueKey('credential-edit-cred-2'));
Finder get delete2 => find.byKey(const ValueKey('credential-delete-cred-2'));
Finder get addApiKey => find.textContaining('addApiKey');

void main() {
  group('DropdownContent', () {
    group('API key section', () {
      testWidgets('should render all credential items', (t) async {
        await render(t, createProvider());
        expect(find.text('My Key'), findsOneWidget);
        expect(find.text('Other Key'), findsOneWidget);
      });

      testWidgets('should show empty state when no credentials', (t) async {
        await render(t, createProvider(customConfiguration: noCredentials), state: createState(hasCredentials: false));
        expect(find.textContaining('noApiKeysTitle'), findsOneWidget);
        expect(find.textContaining('noApiKeysDescription'), findsOneWidget);
      });

      testWidgets('should call activate without closing on credential item click', (t) async {
        await render(t, createProvider());
        await t.tap(find.text('Other Key'));
        await settle(t);
        expect(api.callsOf('switchProviderCredential'), [
          {'provider': 'test', 'credentialId': 'cred-2'},
        ]);
        expect(closes, 0);
      });

      testWidgets('should call handleOpenModal and close on edit credential', (t) async {
        await render(t, createProvider());
        await hoverCred2(t);
        await t.tap(edit2);
        await settle(t);
        expect(t.widget<ModelModal>(find.byType(ModelModal)).credential?.credentialId, 'cred-2');
        expect(closes, 1);
      });

      testWidgets('should call openConfirmDelete on delete credential', (t) async {
        await render(t, createProvider());
        await hoverCred2(t);
        await t.tap(delete2);
        await settle(t);
        expect(find.text('common.modelProvider.confirmDelete'), findsOneWidget);
      });

      testWidgets('should allow use-only users to switch credentials but not edit or delete them', (t) async {
        await render(t, createProvider(), permissionKeys: const ['credential.use']);
        await t.tap(find.text('Other Key'));
        await settle(t);
        await hoverCred2(t);
        expect(edit2, findsNothing);
        expect(delete2, findsNothing);
        expect(api.callsOf('switchProviderCredential'), hasLength(1));
        expect(find.byType(ModelModal), findsNothing);
      });

      testWidgets(
        'should allow create-only users to add credentials but not switch, edit, or delete existing credentials',
        (t) async {
          await render(t, createProvider(), permissionKeys: const ['credential.create']);
          await t.tap(find.text('Other Key'), warnIfMissed: false);
          await settle(t);
          await hoverCred2(t);
          expect(edit2, findsNothing);
          expect(delete2, findsNothing);
          await t.tap(addApiKey);
          await settle(t);
          expect(api.callsOf('switchProviderCredential'), isEmpty);
          final modal = t.widget<ModelModal>(find.byType(ModelModal));
          expect(modal.credential, isNull);
          expect(closes, 1);
        },
      );

      testWidgets('should allow manage-only users to edit and delete credentials but not switch or add them', (
        t,
      ) async {
        await render(t, createProvider(), permissionKeys: const ['credential.manage']);
        await t.tap(find.text('Other Key'), warnIfMissed: false);
        await settle(t);
        expect(api.callsOf('switchProviderCredential'), isEmpty);
        expect(addApiKey, findsNothing);
        await hoverCred2(t);
        await t.tap(delete2);
        await settle(t);
        expect(find.text('common.modelProvider.confirmDelete'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('alert-cancel')));
        await settle(t);
        await hoverCred2(t);
        await t.tap(edit2);
        await settle(t);
        expect(t.widget<ModelModal>(find.byType(ModelModal)).credential?.credentialId, 'cred-2');
      });
    });

    group('Add API Key', () {
      testWidgets('should call handleOpenModal with no args and close on add', (t) async {
        await render(t, createProvider(customConfiguration: noCredentials), state: createState(hasCredentials: false));
        await t.tap(addApiKey);
        await settle(t);
        final modal = t.widget<ModelModal>(find.byType(ModelModal));
        expect(modal.credential, isNull);
        expect(modal.model, isNull);
        expect(closes, 1);
      });

      testWidgets('should hide add action for use-only users', (t) async {
        await render(
          t,
          createProvider(customConfiguration: noCredentials),
          state: createState(hasCredentials: false),
          permissionKeys: const ['credential.use'],
        );
        expect(addApiKey, findsNothing);
      });
    });

    group('AlertDialog for delete confirmation', () {
      testWidgets('should show confirm dialog when deleteCredentialId is set', (t) async {
        await render(t, createProvider());
        await hoverCred2(t);
        await t.tap(delete2);
        await settle(t);
        expect(find.textContaining('confirmDelete'), findsOneWidget);
        // Dify's DropdownContent confirms with "Delete".
        expect(find.text('common.operation.delete'), findsWidgets);
      });

      testWidgets('should not show confirm dialog when deleteCredentialId is null', (t) async {
        await render(t, createProvider());
        expect(find.textContaining('confirmDelete'), findsNothing);
      });
    });

    group('Layout', () {
      testWidgets('should have 320px width container', (t) async {
        await render(t, createProvider());
        expect(t.getSize(find.byType(DropdownContent)).width, 320);
      });
    });
  });
}
