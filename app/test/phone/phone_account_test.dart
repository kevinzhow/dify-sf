/// The phone home's Account tab: the account header, the workspace switcher, the settings sections as pushed
/// full-screen pages (no two-pane settings modal on a phone), switching the server and logging out (asked first).
library;

import 'package:dify_sf_app/src/account/account_page.dart';
import 'package:dify_sf_app/src/account/account_tab.dart';
import 'package:dify_sf_app/src/auth/signin_page.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings/account_setting.dart';
import 'package:dify_sf_app/src/settings/members/members_page.dart';
import 'package:dify_sf_app/src/settings/preference_page.dart';
import 'package:dify_sf_app/src/shell/phone_home_shell.dart';
import 'package:dify_sf_app/src/shell/phone_page.dart';
import 'package:dify_sf_app/src/settings/members/member_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Finder _nav(String label) =>
    find.descendant(of: find.byKey(const ValueKey('phone-home-navigation')), matching: find.text(label));

Future<void> _openAccount(WidgetTester t) async {
  await t.tap(_nav('Account'));
  await settle(t);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in phoneWindows) {
    testWidgets('${w.name}: the header, the workspace and the settings rows fit', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      final ws = await workspace();
      await pumpApp(t, ws);
      await _openAccount(t);
      expect(t.takeException(), isNull);
      final profile = find.byKey(const ValueKey('account-tab-profile'));
      expect(find.descendant(of: profile, matching: find.text('Owner User')), findsOneWidget);
      expect(find.descendant(of: profile, matching: find.text('owner@example.com')), findsOneWidget);
      for (final key in [
        'account-tab-workspace',
        'account-tab-members',
        'account-tab-my-account',
        'account-tab-preferences',
        'account-tab-logout',
      ]) {
        await t.scrollUntilVisible(find.byKey(ValueKey(key)), 100, scrollable: find.byType(Scrollable).last);
        expect(t.getSize(find.byKey(ValueKey(key))).height, greaterThanOrEqualTo(DifyListRow.minHeight), reason: key);
      }
      await unmount(t);
    });
  }

  testWidgets('settings open as pushed pages with a back button; system back returns to the tab', (t) async {
    phoneWindow(t, size: const Size(360, 780));
    final ws = await workspace();
    await pumpApp(t, ws);
    await _openAccount(t);

    Future<void> open(String key, Type page) async {
      await t.tap(find.byKey(ValueKey(key)));
      await settle(t);
      expect(find.byType(PhonePage), findsOneWidget, reason: key);
      expect(find.byType(page), findsOneWidget, reason: key);
      expect(find.byType(AccountSetting), findsNothing, reason: 'no two-pane settings modal on a phone');
      expect(t.takeException(), isNull, reason: key);
    }

    await open('account-tab-members', MembersPage);
    // The members are rows on a phone (subpages PR): no table to scroll sideways.
    expect(find.byKey(const ValueKey('members-table-scroll')), findsNothing);
    expect(find.byType(MemberRow), findsWidgets);
    await t.tap(find.byType(DifyAppBarBackButton));
    await settle(t);
    expect(find.byType(PhonePage), findsNothing);

    await open('account-tab-preferences', PreferencePage);
    expect(await systemBack(t), isTrue);
    expect(find.byType(PhonePage), findsNothing);

    await open('account-tab-my-account', AccountPageBody);
    expect(await systemBack(t), isTrue);
    expect(find.byType(PhonePage), findsNothing);
    expect(t.widget<PhoneHomeShell>(find.byType(PhoneHomeShell)).tab, HomeTab.account);
    await unmount(t);
  });

  testWidgets('the workspace switcher is an action sheet with the workspace and its settings', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    await pumpApp(t, ws);
    await _openAccount(t);
    await t.tap(find.byKey(const ValueKey('account-tab-workspace')));
    await settle(t);
    expect(find.text('Switch workspace'), findsWidgets);
    await t.tap(find.text('Workspace settings'));
    await settle(t);
    expect(find.byType(MembersPage), findsOneWidget);
    await unmount(t);
  });

  testWidgets('log out asks first; confirming shows the sign-in page', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    await pumpApp(t, ws);
    await _openAccount(t);
    await t.scrollUntilVisible(
      find.byKey(const ValueKey('account-tab-logout')),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await t.tap(find.byKey(const ValueKey('account-tab-logout')));
    await settle(t);
    expect(find.text('Log out of this account?'), findsOneWidget);
    // Back dismisses the question: still signed in.
    expect(await systemBack(t), isTrue);
    expect(find.text('Log out of this account?'), findsNothing);
    expect(ws.auth.account, isNotNull);

    await t.tap(find.byKey(const ValueKey('account-tab-logout')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('account-tab-logout-confirm')));
    await settle(t, 2000);
    expect(ws.auth.account, isNull);
    expect(find.byType(SignInPage), findsOneWidget);
    expect(find.byType(PhoneHomeShell), findsNothing);
    await unmount(t);
  });

  testWidgets('the account setting opened elsewhere on a phone is a pushed page, not the two-pane modal', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    await pumpApp(t, ws);
    await _openAccount(t);
    final members = t.widget<AccountTab>(find.byType(AccountTab)).members;
    final shown = showAccountSetting(
      t.element(find.byType(AccountTab)),
      members: members,
      tab: AccountSettingTab.preferences,
    );
    await settle(t);
    expect(find.byType(AccountSetting), findsNothing);
    expect(find.byType(PreferencePage), findsOneWidget);
    expect(find.byType(PhonePage), findsOneWidget);
    expect(await systemBack(t), isTrue);
    await shown;
    expect(find.byType(PhonePage), findsNothing);
    await unmount(t);
  });
}
