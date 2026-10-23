// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/authorized/__tests__/credential-item.spec.tsx
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart' show DifyStatusDot, DifyStatusDotStatus;
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

const credential = Credential(credentialId: 'cred-1', credentialName: 'Test API Key');

Future<void> render(WidgetTester t, Widget item) async {
  await renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 360, child: item),
    ),
    env: envOf(RecordingModelsApi()),
  );
  await hover(t, find.byType(CredentialItem));
}

Finder get editButton => find.byKey(const ValueKey('credential-edit-cred-1'));
Finder get deleteButton => find.byKey(const ValueKey('credential-delete-cred-1'));
DifyStatusDotStatus dotStatus(WidgetTester t) => t.widget<DifyStatusDot>(find.byType(DifyStatusDot)).status;

void main() {
  group('CredentialItem', () {
    testWidgets('should render credential text and indicator', (t) async {
      await render(t, const CredentialItem(credential: credential));
      expect(find.text('Test API Key'), findsOneWidget);
      expect(find.byType(DifyStatusDot), findsOneWidget);
    });

    testWidgets('should render enterprise badge for enterprise credential', (t) async {
      await render(
        t,
        const CredentialItem(
          credential: Credential(credentialId: 'cred-1', credentialName: 'Test API Key', fromEnterprise: true),
        ),
      );
      expect(find.text('Enterprise'), findsOneWidget);
    });

    testWidgets('should call onItemClick when list item is clicked', (t) async {
      final clicks = <Credential>[];
      await render(t, CredentialItem(credential: credential, onItemClick: clicks.add));
      await t.tap(find.text('Test API Key'));
      expect(clicks, [credential]);
    });

    testWidgets('should not call onItemClick when credential is unavailable', (t) async {
      final clicks = <Credential>[];
      await render(
        t,
        CredentialItem(
          credential: const Credential(credentialId: 'cred-1', credentialName: 'Test API Key', notAllowedToUse: true),
          onItemClick: clicks.add,
        ),
      );
      await t.tap(find.text('Test API Key'));
      expect(clicks, isEmpty);
    });

    testWidgets('should render unavailable credential with error indicator and unavailable label', (t) async {
      await render(
        t,
        const CredentialItem(
          credential: Credential(credentialId: 'cred-1', credentialName: 'Test API Key', notAllowedToUse: true),
        ),
      );
      expect(dotStatus(t), DifyStatusDotStatus.error);
      expect(find.text('common.modelProvider.card.unavailable'), findsOneWidget);
    });

    testWidgets('should render available credential with success indicator', (t) async {
      await render(t, const CredentialItem(credential: credential));
      expect(dotStatus(t), DifyStatusDotStatus.success);
    });

    testWidgets('should call onEdit and onDelete from action buttons', (t) async {
      final edits = <Credential>[], deletes = <Credential>[];
      await render(t, CredentialItem(credential: credential, onEdit: edits.add, onDelete: deletes.add));
      await t.tap(editButton);
      await t.tap(deleteButton);
      expect(edits, [credential]);
      expect(deletes, [credential]);
    });

    testWidgets('should block delete action for the currently selected credential when delete is disabled', (t) async {
      final deletes = <Credential>[];
      await render(
        t,
        CredentialItem(
          credential: credential,
          onDelete: deletes.add,
          disableDeleteButShowAction: true,
          selectedCredentialId: 'cred-1',
          disableDeleteTip: 'Cannot remove selected',
        ),
      );
      await t.tap(deleteButton);
      expect(deletes, isEmpty);
    });

    testWidgets('should hide all action buttons when disableRename, disableEdit, and disableDelete are all true', (
      t,
    ) async {
      await render(
        t,
        CredentialItem(
          credential: credential,
          onEdit: (_) {},
          onDelete: (_) {},
          disableRename: true,
          disableEdit: true,
          disableDelete: true,
        ),
      );
      expect(editButton, findsNothing);
      expect(deleteButton, findsNothing);
    });

    testWidgets('should not call onItemClick when disabled=true and item is clicked', (t) async {
      final clicks = <Credential>[];
      await render(t, CredentialItem(credential: credential, disabled: true, onItemClick: clicks.add));
      await t.tap(find.text('Test API Key'));
      expect(clicks, isEmpty);
    });

    testWidgets('should not call onDelete when disabled=true and delete button is clicked', (t) async {
      final deletes = <Credential>[];
      await render(t, CredentialItem(credential: credential, disabled: true, onDelete: deletes.add));
      await t.tap(deleteButton);
      expect(deletes, isEmpty);
    });

    testWidgets('should render check icon area when showSelectedIcon=true and selectedCredentialId matches', (t) async {
      await render(
        t,
        const CredentialItem(credential: credential, showSelectedIcon: true, selectedCredentialId: 'cred-1'),
      );
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'check-line'), findsOneWidget);
    });

    testWidgets('should not render check icon when showSelectedIcon=true but selectedCredentialId does not match', (
      t,
    ) async {
      await render(
        t,
        const CredentialItem(credential: credential, showSelectedIcon: true, selectedCredentialId: 'other-cred'),
      );
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'check-line'), findsNothing);
    });
  });
}
