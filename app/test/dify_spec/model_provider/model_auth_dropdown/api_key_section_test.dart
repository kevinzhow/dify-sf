// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/model-auth-dropdown/__tests__/api-key-section.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json createProvider({bool allowCustomToken = true}) => {
  'provider': 'test-provider',
  'allow_custom_token': allowCustomToken,
  'custom_configuration': {'status': 'active', 'available_credentials': <Object?>[]},
  'system_configuration': {'enabled': true, 'current_quota_type': 'trial', 'quota_configurations': <Object?>[]},
  'preferred_provider_type': 'system',
};

var adds = 0;

Future<void> render(WidgetTester t, Json provider, List<Credential> credentials, {String? selected}) {
  adds = 0;
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 320,
        child: ApiKeySection(
          provider: provider,
          credentials: credentials,
          selectedCredentialId: selected,
          onItemClick: (_) {},
          onEdit: (_) {},
          onDelete: (_) {},
          onAdd: () => adds++,
        ),
      ),
    ),
    env: envOf(
      RecordingModelsApi(),
      permissionKeys: const ['credential.use', 'credential.create', 'credential.manage'],
    ),
  );
}

Finder get addApiKey => find.textContaining('addApiKey');

void main() {
  group('ApiKeySection', () {
    group('Empty state (no credentials)', () {
      testWidgets('should show empty state message', (t) async {
        await render(t, createProvider(), const []);
        expect(find.textContaining('noApiKeysTitle'), findsOneWidget);
        expect(find.textContaining('noApiKeysDescription'), findsOneWidget);
      });

      testWidgets('should show Add API Key button', (t) async {
        await render(t, createProvider(), const []);
        expect(addApiKey, findsOneWidget);
      });

      testWidgets('should call onAdd when Add API Key is clicked', (t) async {
        await render(t, createProvider(), const []);
        await t.tap(addApiKey);
        expect(adds, 1);
      });

      testWidgets('should hide Add API Key button when allow_custom_token is false', (t) async {
        await render(t, createProvider(allowCustomToken: false), const []);
        expect(addApiKey, findsNothing);
      });
    });

    group('With credentials', () {
      const credentials = [
        Credential(credentialId: 'cred-1', credentialName: 'Key Alpha'),
        Credential(credentialId: 'cred-2', credentialName: 'Key Beta'),
      ];

      testWidgets('should render credential list with header', (t) async {
        await render(t, createProvider(), credentials, selected: 'cred-1');
        expect(find.textContaining(RegExp('apiKeys', caseSensitive: false)), findsOneWidget);
        expect(find.text('Key Alpha'), findsOneWidget);
        expect(find.text('Key Beta'), findsOneWidget);
      });

      testWidgets('should show Add API Key button in footer', (t) async {
        await render(t, createProvider(), credentials, selected: 'cred-1');
        expect(addApiKey, findsOneWidget);
      });

      testWidgets('should hide Add API Key when allow_custom_token is false', (t) async {
        await render(t, createProvider(allowCustomToken: false), credentials, selected: 'cred-1');
        expect(addApiKey, findsNothing);
      });
    });
  });
}
