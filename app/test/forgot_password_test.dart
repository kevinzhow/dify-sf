// Forgot password in the whole app, on the in-memory accounts server: with mail the sign-in page's "Forgot your
// password?" leads through the email, the code from the mail and the new password back to the sign-in page, which takes
// the new password; without mail the link does nothing; an admin's reset link opens the new password page directly.
import 'package:collab_client/testing.dart' show FakeAccounts, FakeAuthApi;
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/members/harness.dart' show settle;

Future<void> _open(WidgetTester t, FakeAccounts accounts, {LaunchOptions? launch}) async {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DifyI18n.current = KeyEchoTranslator();
  await t.pumpWidget(
    buildApp(
      AppSettings(serverUrl: 'http://fake', journaled: true, lastDoc: ''),
      authApiFor: (_) => FakeAuthApi(accounts),
      tokenStore: MemoryTokenStore(),
      launch: launch,
    ),
  );
  await settle(t, 5);
}

Future<void> _type(WidgetTester t, String key, String text) async {
  await t.enterText(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)), text);
  await t.pump();
}

void main() {
  testWidgets('with mail: email, code, new password, then sign in with it', (t) async {
    final accounts = FakeAccounts(emailSetup: true)..addMember(email: 'kim@example.com', name: 'Kim');
    final elsewhere = accounts.signIn('kim@example.com');
    await _open(t, accounts);
    await t.tap(find.byKey(const ValueKey('signin-forget')));
    await settle(t);
    expect(find.text('resetPassword'), findsOneWidget);

    await _type(t, 'reset-email', 'Kim@Example.com');
    await t.tap(find.byKey(const ValueKey('reset-send')));
    await settle(t);
    expect(accounts.sentMails.single.to, 'kim@example.com');
    expect(find.text('checkCode.checkYourEmail'), findsOneWidget);
    expect(find.textContaining('Kim@Example.com', findRichText: true), findsOneWidget);
    expect(find.textContaining('59s', findRichText: true), findsOneWidget, reason: 'the resend countdown');

    // A wrong code is refused with the server's message; the right one goes on.
    await _type(t, 'reset-code', '000000' == accounts.sentMails.single.code ? '111111' : '000000');
    await t.tap(find.byKey(const ValueKey('reset-verify')));
    await settle(t);
    expect(find.text('checkCode.checkYourEmail'), findsOneWidget);
    expect(find.text('Email code is invalid or expired.'), findsOneWidget, reason: "the server's message");
    await _type(t, 'reset-code', accounts.sentMails.single.code!);
    await t.tap(find.byKey(const ValueKey('reset-verify')));
    await settle(t);
    expect(find.text('changePassword'), findsOneWidget);

    await _type(t, 'reset-new-password', 'brand-new-1');
    await _type(t, 'reset-confirm-password', 'brand-new-1');
    await t.tap(find.byKey(const ValueKey('reset-set-password')));
    await settle(t);
    expect(find.text('passwordChangedTip'), findsOneWidget);
    expect(accounts.byEmail('kim@example.com')!.password, 'brand-new-1');
    // The account's other sessions ended.
    expect(() => accounts.account(elsewhere.tokens.accessToken), throwsA(anything));

    await t.tap(find.byKey(const ValueKey('reset-sign-in-now')));
    await settle(t);
    await t.enterText(find.byType(EditableText).at(0), 'kim@example.com');
    await t.enterText(find.byType(EditableText).at(1), 'brand-new-1');
    await t.tap(find.byKey(const ValueKey('signin-submit')));
    await settle(t);
    expect(find.byKey(const Key('doc-field')), findsOneWidget, reason: 'the home page');
  });

  testWidgets('the resend countdown ends in Resend, which mails a new code', (t) async {
    final accounts = FakeAccounts(emailSetup: true, resetSendInterval: Duration.zero)
      ..addMember(email: 'kim@example.com', name: 'Kim');
    await _open(t, accounts);
    await t.tap(find.byKey(const ValueKey('signin-forget')));
    await settle(t);
    await _type(t, 'reset-email', 'kim@example.com');
    await t.tap(find.byKey(const ValueKey('reset-send')));
    await settle(t);
    expect(find.byKey(const ValueKey('reset-resend')), findsNothing);
    await t.pump(const Duration(seconds: 60));
    await t.tap(find.byKey(const ValueKey('reset-resend')));
    await settle(t);
    expect(accounts.sentMails, hasLength(2));
    // The latest code counts.
    await _type(t, 'reset-code', accounts.sentMails.last.code!);
    await t.tap(find.byKey(const ValueKey('reset-verify')));
    await settle(t);
    expect(find.text('changePassword'), findsOneWidget);
  });

  testWidgets('without mail the link is disabled', (t) async {
    final accounts = FakeAccounts()..addMember(email: 'kim@example.com', name: 'Kim');
    await _open(t, accounts);
    await t.tap(find.byKey(const ValueKey('signin-forget')));
    await settle(t);
    expect(find.byKey(const ValueKey('signin-submit')), findsOneWidget);
    expect(find.text('resetPassword'), findsNothing);
  });

  testWidgets("an admin's reset link opens the new password page, also without mail", (t) async {
    final accounts = FakeAccounts()
      ..addMember(email: 'kim@example.com', name: 'Kim')
      ..addMember(email: 'bo@example.com', name: 'Bo');
    final owner = accounts.signIn('kim@example.com').tokens.accessToken;
    final url = accounts.resetPasswordLink(owner, accounts.byEmail('bo@example.com')!.id)['url']! as String;
    await _open(
      t,
      accounts,
      launch: LaunchOptions.fromQuery(Uri.parse(url).queryParameters, path: Uri.parse(url).path),
    );
    expect(find.text('changePassword'), findsOneWidget);
    await _type(t, 'reset-new-password', 'bo-new-pass-1');
    await _type(t, 'reset-confirm-password', 'bo-new-pass-1');
    await t.tap(find.byKey(const ValueKey('reset-set-password')));
    await settle(t);
    expect(find.text('passwordChangedTip'), findsOneWidget);
    expect(accounts.byEmail('bo@example.com')!.password, 'bo-new-pass-1');
    // The link works once.
    expect(
      () => accounts.resetPassword(
        token: Uri.parse(url).queryParameters['token'],
        newPassword: 'x-1234567',
        passwordConfirm: 'x-1234567',
      ),
      throwsA(anything),
    );
  });

  test('reset links on the command line and in the web URL', () {
    expect(LaunchOptions.parse(['--reset-link', 'http://x/reset-password/set-password?token=abc']).resetToken, 'abc');
    expect(LaunchOptions.fromQuery({'token': 'abc'}, path: '/reset-password/set-password').resetToken, 'abc');
    expect(LaunchOptions.fromQuery({'token': 'abc'}, path: '/activate').resetToken, isNull);
  });
}
