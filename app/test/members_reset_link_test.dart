// dify-sf's password reset links on the Members page, on the in-memory accounts server: an owner or admin gets a
// one-time link for another member from the row's menu and copies it; the owner's row and one's own have no menu;
// normal members see no actions.
import 'package:collab_client/testing.dart' show FakeAccounts, FakeAuthApi;
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/settings/members/reset_link_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/members/harness.dart' show settle;

Future<FakeAccounts> _members(WidgetTester t, String email) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DifyI18n.current = KeyEchoTranslator();
  final accounts = FakeAccounts()
    ..addMember(email: 'kim@example.com', name: 'Kim', role: AccountRole.owner)
    ..addMember(email: 'ada@example.com', name: 'Ada', role: AccountRole.admin)
    ..addMember(email: 'bo@example.com', name: 'Bo', role: AccountRole.editor)
    ..addMember(email: 'nia@example.com', name: 'Nia', role: AccountRole.normal);
  await t.pumpWidget(
    buildApp(
      AppSettings(serverUrl: 'http://fake', journaled: true, lastDoc: ''),
      authApiFor: (_) => FakeAuthApi(accounts),
      tokenStore: MemoryTokenStore(),
    ),
  );
  await settle(t, 5);
  await t.enterText(find.byType(EditableText).at(0), email);
  await t.enterText(find.byType(EditableText).at(1), 'password-1');
  await t.tap(find.byKey(const ValueKey('signin-submit')));
  await settle(t);
  await t.tap(find.byKey(const ValueKey('workspace-card-trigger')));
  await settle(t, 3);
  await t.tap(find.byKey(const ValueKey('workspace-settings')));
  await settle(t);
  return accounts;
}

void main() {
  testWidgets("an admin gets a member's reset link and the member sets a new password with it", (t) async {
    final accounts = await _members(t, 'ada@example.com');
    final bo = accounts.byEmail('bo@example.com')!;
    final boSession = accounts.signIn('bo@example.com').tokens.accessToken;
    await t.tap(find.byKey(ValueKey('member-actions-${bo.id}')));
    await settle(t, 3);
    await t.tap(find.byKey(const ValueKey('member-reset-password-link')));
    await settle(t);
    expect(find.text(ResetLinkModal.title), findsWidgets);
    expect(find.textContaining('Send this link to Bo (bo@example.com)'), findsOneWidget);
    expect(find.textContaining('expires in 24 hours'), findsOneWidget);
    final url = t.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey('reset-link')), matching: find.textContaining('/reset-password/')),
    );
    expect(url.data, startsWith('/reset-password/set-password?email=bo%40example.com&token='));
    await t.tap(find.byKey(const ValueKey('reset-link-ok')));
    await settle(t);
    expect(find.text(ResetLinkModal.title), findsNothing);

    final token = Uri.parse(url.data!).queryParameters['token'];
    accounts.resetPassword(token: token, newPassword: 'bo-new-pass-1', passwordConfirm: 'bo-new-pass-1');
    expect(bo.password, 'bo-new-pass-1');
    expect(() => accounts.account(boSession), throwsA(anything), reason: "Bo's sessions ended");
  });

  testWidgets("no link for the owner's row, one's own row, or a normal member", (t) async {
    final accounts = await _members(t, 'ada@example.com');
    expect(find.byKey(ValueKey('member-actions-${accounts.owner!.id}')), findsNothing);
    expect(find.byKey(ValueKey('member-actions-${accounts.byEmail('ada@example.com')!.id}')), findsNothing);
  });

  testWidgets('a refused request toasts the server message', (t) async {
    final accounts = await _members(t, 'kim@example.com');
    final nia = accounts.byEmail('nia@example.com')!;
    await t.tap(find.byKey(ValueKey('member-actions-${nia.id}')));
    await settle(t, 3);
    accounts.byId[nia.id]!.role = null; // removed meanwhile
    await t.tap(find.byKey(const ValueKey('member-reset-password-link')));
    await settle(t);
    expect(find.text('unknown member'), findsOneWidget);
    expect(find.text(ResetLinkModal.title), findsNothing);
  });

  test('the validity in words', () {
    final now = DateTime.utc(2026, 1, 1);
    expect(
      ResetLinkModal.validity(PasswordResetLink(url: '/x', expiresAt: now.add(const Duration(hours: 24))), now),
      '24 hours',
    );
    expect(
      ResetLinkModal.validity(PasswordResetLink(url: '/x', expiresAt: now.add(const Duration(minutes: 50))), now),
      'one hour',
    );
    expect(ResetLinkModal.validity(const PasswordResetLink(url: '/x'), now), 'a limited time');
  });
}
