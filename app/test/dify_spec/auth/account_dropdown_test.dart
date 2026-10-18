// dify-spec: web/app/components/header/account-dropdown/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/auth/account_dropdown.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

const _profile = Account(
  id: 'current-user',
  name: 'Current User',
  email: 'current@example.com',
  avatarUrl: null,
  role: AccountRole.owner,
);
const _accessibleName = 'Current User common.account.account';

SemanticsFinder _button(String name) => find.semantics.byPredicate(
  (n) => n.getSemanticsData().flagsCollection.isButton && n.label == name,
  describeMatch: (_) => 'button "$name"',
);

/// The section at the bottom-left, where Dify's main navigation has it (the menu opens upwards).
Widget _atBottom(Widget w) => Align(
  alignment: Alignment.bottomLeft,
  child: Padding(padding: const EdgeInsets.all(12), child: w),
);

void main() {
  group('AccountDropdown', () {
    testWidgets('includes the visible account name in the main navigation trigger accessible name', (t) async {
      await renderAuth(t, await authOn(RecordingAuthApi()), _atBottom(const AccountSection(account: _profile)));
      expect(_button(_accessibleName), findsOne);
    });

    testWidgets('keeps the account identity in the compact trigger accessible name', (t) async {
      await renderAuth(
        t,
        await authOn(RecordingAuthApi()),
        _atBottom(const AccountSection(account: _profile, compact: true)),
      );
      expect(_button(_accessibleName), findsOne);
      expect(find.text('Current User'), findsNothing);
    });

    testWidgets('reads the signed-in account from the account profile query', (t) async {
      final auth = await signedInAuth(name: 'Current User', email: 'current@example.com');
      await renderAuth(t, auth, _atBottom(AccountSection(account: auth.account!)));
      expect(find.text('Current User'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('account-trigger')));
      await settleAuth(t, 3);
      expect(find.text('current@example.com'), findsOneWidget);
    });

    testWidgets('logs out and redirects to sign in', (t) async {
      final api = RecordingAuthApi();
      final auth = await signedInAuth(api: api, name: 'Current User', email: 'current@example.com');
      await renderAuth(t, auth, _atBottom(AccountSection(account: auth.account!)));
      await t.tap(find.byKey(const ValueKey('account-trigger')));
      await settleAuth(t, 3);
      await t.tap(find.text('common.userProfile.logout'));
      await settleAuth(t, 3);
      expect(api.callNames.where((n) => n == 'logout'), hasLength(1));
      expect(auth.signedIn, isFalse);
      expect(auth.route, isA<SignInRoute>());
    });
  });
}
