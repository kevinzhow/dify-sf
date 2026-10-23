// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/__tests__/credential-selector.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

const mockCredentials = [
  Credential(credentialId: 'cred-1', credentialName: 'Key 1'),
  Credential(credentialId: 'cred-2', credentialName: 'Key 2'),
];

Future<void> render(WidgetTester t, CredentialSelector selector) => renderSettings(
  t,
  Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: 400, child: selector),
  ),
  env: envOf(RecordingModelsApi()),
);

void main() {
  group('CredentialSelector', () {
    final selected = <SelectedCredential>[];
    setUp(selected.clear);

    testWidgets('should render selected credential name when selectedCredential is provided', (t) async {
      await render(
        t,
        CredentialSelector(
          selectedCredential: SelectedCredential(mockCredentials[0]),
          credentials: mockCredentials,
          onSelect: selected.add,
        ),
      );
      expect(find.text('Key 1'), findsOneWidget);
      // The status dot of the selected credential.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('credential-selector-trigger')),
          matching: find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == 8),
        ),
        findsOneWidget,
      );
    });

    testWidgets('should render placeholder when selectedCredential is missing', (t) async {
      await render(t, CredentialSelector(credentials: mockCredentials, onSelect: selected.add));
      expect(find.text('common.modelProvider.auth.selectModelCredential'), findsOneWidget);
    });

    testWidgets('should call onSelect when a credential item is clicked', (t) async {
      await render(t, CredentialSelector(credentials: mockCredentials, onSelect: selected.add));
      await t.tap(find.text('common.modelProvider.auth.selectModelCredential'));
      await settle(t);
      await t.tap(find.text('Key 2'));
      await settle(t);
      expect(selected.single.credential, mockCredentials[1]);
      expect(selected.single.addNewCredential, isFalse);
    });

    testWidgets('should call onSelect with add-new payload when add action is clicked', (t) async {
      await render(t, CredentialSelector(credentials: mockCredentials, onSelect: selected.add));
      await t.tap(find.text('common.modelProvider.auth.selectModelCredential'));
      await settle(t);
      await t.tap(find.text('common.modelProvider.auth.addNewModelCredential'));
      await settle(t);
      expect(selected.single.credential.credentialId, '__add_new_credential');
      expect(selected.single.addNewCredential, isTrue);
    });

    testWidgets('should not open options when disabled is true', (t) async {
      await render(t, CredentialSelector(disabled: true, credentials: mockCredentials, onSelect: selected.add));
      await t.tap(find.text('common.modelProvider.auth.selectModelCredential'));
      await settle(t);
      expect(find.text('Key 1'), findsNothing);
    });
  });
}
