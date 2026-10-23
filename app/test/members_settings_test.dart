// The workspace settings in the whole app, on the in-memory accounts server: the workspace card at the top of the
// main navigation opens the Members tab; an owner invites (and gets the activation link), changes a role and removes
// a member; a normal member only reads; signing out closes the settings.
import 'package:collab_client/testing.dart' show FakeAccounts, FakeAuthApi;
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/members/harness.dart' show focusEmail, pasteText, settle;

Future<FakeAccounts> _signIn(WidgetTester t, String email) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DifyI18n.current = KeyEchoTranslator();
  final accounts = FakeAccounts()
    ..addMember(email: 'kim@example.com', name: 'Kim', role: AccountRole.owner)
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
  return accounts;
}

Future<void> _openMembers(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('workspace-card-trigger')));
  await settle(t, 3);
  await t.tap(find.byKey(const ValueKey('workspace-settings')));
  await settle(t);
}

void main() {
  testWidgets('an owner manages the members from the workspace card', (t) async {
    final accounts = await _signIn(t, 'kim@example.com');
    expect(find.text("Kim's Workspace"), findsOneWidget, reason: 'the workspace card');
    await _openMembers(t);
    expect(find.byKey(const ValueKey('account-setting-title')), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'the member count');

    // Invite: the result shows the activation link to pass on.
    await t.tap(find.byKey(const ValueKey('invite-button')));
    await settle(t);
    await focusEmail(t);
    await pasteText(t, 'new@example.com, bo@example.com');
    await t.tap(find.byKey(const ValueKey('role-selector-trigger')));
    await settle(t, 3);
    await t.tap(find.byKey(const ValueKey('role-option-normal')));
    await settle(t, 3);
    await t.tap(find.byKey(const ValueKey('send-invite')));
    await settle(t);
    expect(find.text('members.invitationSent'), findsOneWidget);
    expect(find.textContaining('/activate?email=new%40example.com&token='), findsOneWidget);
    expect(find.text('bo@example.com'), findsWidgets, reason: 'already in the team');
    await t.tap(find.byKey(const ValueKey('invited-ok')));
    await settle(t);
    expect(accounts.byEmail('new@example.com')!.status, 'pending');
    expect(find.text('4'), findsOneWidget);

    // Change Bo's role from the row's menu.
    final bo = accounts.byEmail('bo@example.com')!.id;
    await t.tap(find.byKey(ValueKey('member-actions-$bo')));
    await settle(t, 3);
    await t.tap(find.byKey(const ValueKey('member-edit-role')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('role-radio-admin')));
    await settle(t, 2);
    await t.tap(find.byKey(const ValueKey('assign-confirm')));
    await settle(t);
    expect(accounts.byEmail('bo@example.com')!.role, AccountRole.admin);
    expect(find.text('actionMsg.modifiedSuccessfully'), findsOneWidget);

    // Remove Nia, after confirming.
    final nia = accounts.byEmail('nia@example.com')!.id;
    await t.tap(find.byKey(ValueKey('member-actions-$nia')));
    await settle(t, 3);
    await t.tap(find.byKey(const ValueKey('member-remove')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('alert-confirm')));
    await settle(t);
    expect(accounts.byEmail('nia@example.com')!.role, isNull);
    expect(find.byKey(ValueKey('member-row-$nia')), findsNothing);

    // The toasts (over the close button, at the top right) close after 5 s; then close the settings.
    await t.pump(const Duration(seconds: 6));
    await t.tap(find.byKey(const ValueKey('account-setting-close')));
    await settle(t);
    expect(find.byKey(const ValueKey('account-setting-title')), findsNothing);
  });

  testWidgets('a normal member reads the members without any action', (t) async {
    final accounts = await _signIn(t, 'nia@example.com');
    await t.tap(find.byKey(const ValueKey('workspace-card-trigger')));
    await settle(t, 3);
    expect(find.byKey(const ValueKey('workspace-invite-members')), findsNothing);
    await t.tap(find.byKey(const ValueKey('workspace-settings')));
    await settle(t);
    expect(find.byKey(const ValueKey('invite-button')), findsNothing);
    expect(find.byKey(ValueKey('member-actions-${accounts.byEmail('bo@example.com')!.id}')), findsNothing);
    // The details open read-only.
    await t.tap(find.byKey(ValueKey('member-details-${accounts.byEmail('bo@example.com')!.id}')));
    await settle(t);
    expect(find.text('members.memberDetails.title'), findsOneWidget);
    expect(find.byKey(const ValueKey('details-edit-role')), findsNothing);
    expect(find.byKey(const ValueKey('details-save')), findsNothing);
  });

  testWidgets('signing out closes the settings', (t) async {
    await _signIn(t, 'kim@example.com');
    await _openMembers(t);
    expect(find.byKey(const ValueKey('account-setting-title')), findsOneWidget);
    final home = t.element(find.byType(HomePage));
    await AuthScope.read(home)!.signOut();
    await settle(t);
    expect(find.byKey(const ValueKey('account-setting-title')), findsNothing);
    expect(find.byKey(const ValueKey('signin-submit')), findsOneWidget);
  });
}
