// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/__tests__/manage-custom-model-credentials.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json provider(List<Json> customModels) => {
  'provider': 'openai',
  'custom_configuration': {'status': 'active', 'custom_models': customModels},
};

Future<void> render(WidgetTester t, Widget child) => renderSettings(
  t,
  Align(
    alignment: Alignment.topLeft,
    child: Padding(padding: const EdgeInsets.only(left: 500, top: 20), child: child),
  ),
  env: envOf(RecordingModelsApi()),
);

Authorized authorized(WidgetTester t) => t.widget<Authorized>(find.byType(Authorized));

void main() {
  group('ManageCustomModelCredentials', () {
    testWidgets('should return null when no custom models exist', (t) async {
      await render(t, ManageCustomModelCredentials(provider: provider(const [])));
      expect(find.byType(Authorized), findsNothing);
      expect(find.byType(ManageCredentialsButton), findsNothing);
    });

    testWidgets('should render authorized component when custom models exist', (t) async {
      await render(
        t,
        ManageCustomModelCredentials(
          provider: provider(const [
            {
              'model': 'gpt-4',
              'available_model_credentials': [
                {'credential_id': 'c1', 'credential_name': 'Key 1'},
              ],
              'current_credential_id': 'c1',
              'current_credential_name': 'Key 1',
            },
            {'model': 'gpt-3.5'},
          ]),
        ),
      );
      expect(find.byType(Authorized), findsOneWidget);
      expect(find.text('common.modelProvider.auth.manageCredentials'), findsOneWidget);
      expect(authorized(t).items, hasLength(2));
      expect(authorized(t).popupTitle, 'common.modelProvider.auth.customModelCredentials');
    });

    testWidgets('should render trigger in both open and closed states', (t) async {
      await render(
        t,
        ManageCustomModelCredentials(
          provider: provider(const [
            {
              'model': 'gpt-4',
              'available_model_credentials': [
                {'credential_id': 'c1', 'credential_name': 'Key 1'},
              ],
              'current_credential_id': 'c1',
              'current_credential_name': 'Key 1',
            },
          ]),
        ),
      );
      expect(find.byType(ManageCredentialsButton), findsOneWidget);
      expect(t.widget<ManageCredentialsButton>(find.byType(ManageCredentialsButton)).open, isFalse);
      await t.tap(find.text('common.modelProvider.auth.manageCredentials'));
      await settle(t);
      expect(t.widget<ManageCredentialsButton>(find.byType(ManageCredentialsButton)).open, isTrue);
    });

    testWidgets('should forward controlled open state', (t) async {
      final changes = <bool>[];
      await render(
        t,
        ManageCustomModelCredentials(
          provider: provider(const [
            {'model': 'gpt-4'},
          ]),
          isOpen: true,
          onOpenChange: changes.add,
        ),
      );
      expect(authorized(t).isOpen, isTrue);
      authorized(t).onOpenChange!(false);
      expect(changes, [false]);
    });

    testWidgets('should pass undefined selectedCredential when model has no current_credential_id', (t) async {
      await render(
        t,
        ManageCustomModelCredentials(
          provider: provider(const [
            {
              'model': 'gpt-3.5',
              'available_model_credentials': [
                {'credential_id': 'c1', 'credential_name': 'Key 1'},
              ],
              'current_credential_id': '',
              'current_credential_name': '',
            },
          ]),
        ),
      );
      expect(authorized(t).items.single.selectedCredential, isNull);
    });
  });
}
