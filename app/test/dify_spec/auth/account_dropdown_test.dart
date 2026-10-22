import 'package:flutter/gestures.dart';
// dify-spec: web/app/components/header/account-dropdown/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/auth/account_dropdown.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/material.dart';
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

    testWidgets('opens the main navigation account menu through the composed trigger', (t) async {
      final theme = AppTheme(DifyThemeMode.system, remember: false);
      addTearDown(theme.dispose);
      await renderAuth(
        t,
        await authOn(RecordingAuthApi()),
        _atBottom(const AccountSection(account: _profile)),
        theme: theme,
      );
      final trigger = _button(_accessibleName);
      expect(trigger, findsOne);
      await t.tap(find.byKey(const ValueKey('account-trigger')));
      await settleAuth(t, 3);
      expect(find.text('current@example.com'), findsOneWidget);
      // `data-popup-open`: the trigger shows its open state.
      expect(
        t
            .widget<Container>(
              find
                  .descendant(of: find.byKey(const ValueKey('account-trigger')), matching: find.byType(Container))
                  .first,
            )
            .decoration,
        isA<BoxDecoration>().having((d) => d.color, 'color', DifyColors.stateBaseHover),
      );
      expect(find.text('common.settings.preferences'), findsOneWidget);
      expect(find.text('common.account.appearanceLabel'), findsOneWidget);
    });

    testWidgets('pointer can enter the Appearance submenu and linger on every option', (t) async {
      final theme = AppTheme(DifyThemeMode.system, remember: false);
      addTearDown(theme.dispose);
      await renderAuth(
        t,
        await authOn(RecordingAuthApi()),
        _atBottom(const AccountSection(account: _profile)),
        theme: theme,
      );
      await t.tap(find.byKey(const ValueKey('account-trigger')));
      await settleAuth(t, 3);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.text('common.account.appearanceLabel')));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 1));
      for (final mode in ['light', 'dark', 'system']) {
        final option = find.byKey(ValueKey('appearance-$mode'));
        expect(option, findsOneWidget);
        await mouse.moveTo(t.getCenter(option));
        await t.pump(const Duration(milliseconds: 300));
        expect(option, findsOneWidget, reason: 'hovering a child must not close its parent submenu');
      }
      await mouse.removePointer();
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the Appearance submenu sets light, dark or system', (t) async {
      addTearDown(() => DifyColors.useDark(false));
      final theme = AppTheme(DifyThemeMode.system, remember: false);
      addTearDown(theme.dispose);
      await renderAuth(
        t,
        await authOn(RecordingAuthApi()),
        _atBottom(const AccountSection(account: _profile)),
        theme: theme,
      );
      for (final (label, mode, dark) in [
        ('common.account.appearanceDark', DifyThemeMode.dark, true),
        ('common.account.appearanceLight', DifyThemeMode.light, false),
        ('common.account.appearanceSystem', DifyThemeMode.system, false),
      ]) {
        await t.tap(find.byKey(const ValueKey('account-trigger')));
        await settleAuth(t, 3);
        await t.tap(find.text('common.account.appearanceLabel'));
        await settleAuth(t, 3);
        expect(find.text('common.account.appearanceSystem'), findsOneWidget);
        await t.tap(find.text(label));
        await settleAuth(t, 3);
        expect(theme.mode, mode);
        expect(DifyColors.isDark, dark);
        // closeOnClick: the whole menu closed.
        expect(find.text('current@example.com'), findsNothing);
      }
    });

    testWidgets('opens preferences from the account menu', (t) async {
      final opened = <String>[];
      await renderAuth(
        t,
        await authOn(RecordingAuthApi()),
        _atBottom(
          AccountDropdown(
            account: _profile,
            onOpenPreferences: () => opened.add('preferences'),
            trigger: (context, ariaLabel, open, toggle) => Semantics(
              button: true,
              label: ariaLabel,
              child: GestureDetector(
                key: const ValueKey('composed-trigger'),
                onTap: toggle,
                child: const Text('Current account'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('composed-trigger')));
      await settleAuth(t, 3);
      await t.tap(find.text('common.settings.preferences'));
      await settleAuth(t, 3);
      // `setSettingsDestination('preferences')`.
      expect(opened, ['preferences']);
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
