// The Account page (Dify 1.17.1's /account) and the account's time zone accessor, against the in-memory accounts
// server (protocol 1.8 / 1.12): rename, password, the change of email with codes by mail, the account's apps, the header,
// the main navigation's Account entry, and AccountTime (Dify's useTimestamp).
import 'package:collab_client/testing.dart' show FakeAccounts, FakeAppsApi, FakeAuthApi, FakeMail;
import 'package:dify_sf_app/src/account/account_page.dart';
import 'package:dify_sf_app/src/auth/account_dropdown.dart';
import 'package:dify_sf_app/src/auth/account_time.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/dify_test_i18n.dart';
import 'dify_spec/members/harness.dart' show button, settle, tapButton;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

class _Fixture {
  _Fixture(this.accounts, this.auth);
  final FakeAccounts accounts;
  final AuthController auth;
}

Future<_Fixture> _signedIn({bool mail = false}) async {
  final accounts = FakeAccounts(emailSetup: mail, changeEmailSendInterval: Duration.zero)
    ..addMember(email: 'owner@example.com', name: 'Owner User', password: 'owner-pass-1')
    ..addMember(email: 'taken@example.com', name: 'Taken');
  final auth = AuthController.on(server: 'http://test', api: FakeAuthApi(accounts), store: MemoryTokenStore());
  await auth.start();
  await auth.signIn(email: 'owner@example.com', password: 'owner-pass-1');
  return _Fixture(accounts, auth);
}

/// [child] under a navigator with the session above it (as buildApp's relay puts it), the toast host and Dify's test
/// translator.
Future<void> _pump(WidgetTester t, AuthController auth, Widget child) async {
  useDifyTestTranslator();
  t.view.physicalSize = const Size(1440, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: child,
      builder: (context, c) => AuthScope(
        controller: auth,
        child: AppLocaleScope(
          locale: AppLocale('en-US', loader: (_) async {}),
          child: Stack(
            fit: StackFit.expand,
            children: [
              c!,
              const DifyToastHost(timeout: Duration.zero),
            ],
          ),
        ),
      ),
    ),
  );
  await settle(t);
}

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> _type(WidgetTester t, Key key, String text) async {
  await t.enterText(_input(key), text);
  await t.pump();
}

Finder _labelled(String label) => find
    .descendant(
      of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == label),
      matching: find.byType(EditableText),
    )
    .first;

void main() {
  group('Account page', () {
    testWidgets('shows the profile, name, email, password and the account\'s apps', (t) async {
      final f = await _signedIn();
      final apps = FakeAppsApi();
      await apps.create(name: 'Support bot', mode: 'advanced-chat');
      await apps.create(name: 'Summariser', mode: 'workflow');
      await _pump(t, f.auth, AccountPage(apps: apps));
      expect(find.text('common.account.myAccount'), findsOneWidget);
      // The card, the name field and the header's account.
      expect(find.text('Owner User'), findsNWidgets(2));
      expect(find.text('owner@example.com'), findsNWidgets(2));
      expect(button('common.operation.edit'), findsOneWidget);
      // Without mail the email cannot change (dify-sf's `enable_change_email`).
      expect(button('common.operation.change'), findsNothing);
      expect(button('common.account.resetPassword'), findsOneWidget);
      // Dify Cloud's delete is not offered.
      expect(find.text('common.account.delete'), findsNothing);
      final show = 'common.account.showAppLength:{"length":2}';
      expect(find.text('Support bot'), findsNothing);
      await tapButton(t, show);
      expect(find.text('Support bot'), findsOneWidget);
      expect(find.text('Summariser'), findsOneWidget);
    });

    testWidgets('Edit Name renames the account; the server\'s refusal stays in the dialog', (t) async {
      final f = await _signedIn();
      await _pump(t, f.auth, const AccountPage());
      await tapButton(t, 'common.operation.edit');
      expect(find.text('common.account.editName'), findsOneWidget);
      await _type(t, const ValueKey('edit-name-input'), 'Ol');
      await tapButton(t, 'common.operation.save');
      expect(find.text('name must be 3-30 characters'), findsOneWidget);
      expect(find.text('common.account.editName'), findsOneWidget);
      await _type(t, const ValueKey('edit-name-input'), '');
      expect(button('common.operation.save'), findsOneWidget);
      await _type(t, const ValueKey('edit-name-input'), 'Olivia Owner');
      await tapButton(t, 'common.operation.save');
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
      expect(find.text('common.account.editName'), findsNothing);
      expect(f.accounts.byEmail('owner@example.com')!.name, 'Olivia Owner');
      expect(f.auth.account!.name, 'Olivia Owner');
      expect(find.text('Olivia Owner'), findsNWidgets(2));
    });

    testWidgets('Reset password checks Dify\'s rules, then changes the password', (t) async {
      final f = await _signedIn();
      await _pump(t, f.auth, const AccountPage());
      Future<void> open() => tapButton(t, 'common.account.resetPassword');
      await open();
      await tapButton(t, 'common.operation.reset');
      expect(find.text('login.error.passwordEmpty'), findsOneWidget);
      await t.enterText(_labelled('common.account.newPassword'), 'short');
      await tapButton(t, 'common.operation.reset');
      expect(find.text('login.error.passwordInvalid'), findsOneWidget);
      await t.enterText(_labelled('common.account.newPassword'), 'owner-new-1');
      await t.enterText(_labelled('common.account.confirmPassword'), 'owner-new-2');
      await tapButton(t, 'common.operation.reset');
      expect(find.text('common.account.notEqual'), findsOneWidget);
      // A wrong current password: the server's message, and the dialog closes (as Dify's).
      await t.enterText(_labelled('common.account.currentPassword'), 'wrong-pass-1');
      await t.enterText(_labelled('common.account.confirmPassword'), 'owner-new-1');
      await tapButton(t, 'common.operation.reset');
      expect(find.text('the current password is incorrect'), findsOneWidget);
      expect(find.text('common.account.currentPassword'), findsNothing);
      await open();
      await t.enterText(_labelled('common.account.currentPassword'), 'owner-pass-1');
      await t.enterText(_labelled('common.account.newPassword'), 'owner-new-1');
      await t.enterText(_labelled('common.account.confirmPassword'), 'owner-new-1');
      // The show / hide toggle.
      expect(button('login.showPassword'), findsNWidgets(3));
      final toggle = button('login.showPassword').evaluate().first;
      toggle.owner!.performAction(toggle.id, SemanticsAction.tap);
      await settle(t);
      expect(button('login.hidePassword'), findsOneWidget);
      expect(button('login.showPassword'), findsNWidgets(2));
      await tapButton(t, 'common.operation.reset');
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
      expect(f.accounts.byEmail('owner@example.com')!.password, 'owner-new-1');
    });

    testWidgets('Change Email: a code to the current address, a free new address, its code, then signed out', (
      t,
    ) async {
      final f = await _signedIn(mail: true);
      await f.auth.start(); // reads the system features (mail)
      await f.auth.signIn(email: 'owner@example.com', password: 'owner-pass-1');
      await _pump(t, f.auth, const AccountPage());
      String code(String to) => f.accounts.sentMails.lastWhere((m) => m.to == to).code!;

      await tapButton(t, 'common.operation.change');
      expect(find.text('common.account.changeEmail.title'), findsOneWidget);
      await tapButton(t, 'common.account.changeEmail.sendVerifyCode');
      expect(f.accounts.sentMails.single.kind, FakeMail.changeEmailOld);
      expect(find.text('common.account.changeEmail.verifyEmail'), findsOneWidget);
      expect(find.text('common.account.changeEmail.resendCount:{"count":60}'), findsOneWidget);
      // A wrong code: Dify's toast; the field is cleared.
      await t.enterText(
        _labelled('common.account.changeEmail.codeLabel'),
        '000000' == code('owner@example.com') ? '111111' : '000000',
      );
      await t.pump();
      await tapButton(t, 'common.account.changeEmail.continue');
      expect(find.text('Error verifying email: Email code is invalid or expired.'), findsOneWidget);
      await t.enterText(_labelled('common.account.changeEmail.codeLabel'), code('owner@example.com'));
      await t.pump();
      await tapButton(t, 'common.account.changeEmail.continue');
      expect(find.text('common.account.changeEmail.newEmail'), findsOneWidget);

      // A taken address is named after the debounce and blocks sending.
      await t.enterText(_labelled('common.account.changeEmail.emailLabel'), 'TAKEN@example.com');
      await settle(t);
      expect(find.text('common.account.changeEmail.existingEmail'), findsOneWidget);
      expect(
        button('common.account.changeEmail.sendVerifyCode')
            .evaluate()
            .single
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        isNot(true),
      );
      await t.enterText(_labelled('common.account.changeEmail.emailLabel'), 'new@example.com');
      await settle(t);
      expect(find.text('common.account.changeEmail.existingEmail'), findsNothing);
      await tapButton(t, 'common.account.changeEmail.sendVerifyCode');
      expect(f.accounts.sentMails.last.kind, FakeMail.changeEmailNew);
      expect(find.text('common.account.changeEmail.verifyNew'), findsOneWidget);
      await t.enterText(_labelled('common.account.changeEmail.codeLabel'), code('new@example.com'));
      await t.pump();
      await tapButton(t, 'common.account.changeEmail.changeTo:{"email":"new@example.com"}');
      await settle(t);
      expect(f.accounts.byId.values.any((a) => a.email == 'new@example.com'), isTrue);
      expect(f.accounts.sentMails.last.kind, FakeMail.changeEmailCompleted);
      // Dify signs out after the change.
      expect(f.auth.signedIn, isFalse);
      expect(f.auth.route, isA<SignInRoute>());
    });

    testWidgets('the header goes home; its avatar menu logs out', (t) async {
      final f = await _signedIn();
      await _pump(
        t,
        f.auth,
        Builder(
          builder: (context) => Center(
            child: TextButton(onPressed: () => openAccountPage(context), child: const Text('open')),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      expect(find.text('common.account.account'), findsOneWidget);
      await tapButton(t, 'common.mainNav.home');
      expect(find.byType(AccountPage), findsNothing);
      await t.tap(find.text('open'));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('account-avatar-trigger')));
      await settle(t, 3);
      await t.tap(find.text('common.userProfile.logout'));
      await settle(t);
      expect(f.auth.signedIn, isFalse);
    });

    testWidgets('the main navigation\'s account menu opens the Account page', (t) async {
      final f = await _signedIn();
      await _pump(
        t,
        f.auth,
        Align(
          alignment: Alignment.bottomLeft,
          child: AccountSection(account: f.auth.account!),
        ),
      );
      await t.tap(find.byKey(const ValueKey('account-trigger')));
      await settle(t, 3);
      expect(find.text('common.account.account'), findsOneWidget);
      await t.tap(find.text('common.account.account'));
      await settle(t);
      expect(find.byType(AccountPage), findsOneWidget);
      expect(find.text('common.account.myAccount'), findsOneWidget);
    });
  });

  group('AccountTime (useTimestamp)', () {
    final instant = DateTime.utc(2026, 7, 1, 12, 30, 15).millisecondsSinceEpoch ~/ 1000;

    test('formats in the account\'s time zone', () {
      expect(const AccountTime('Asia/Tokyo').formatTime(instant, 'YYYY-MM-DD HH:mm:ss'), '2026-07-01 21:30:15');
      expect(const AccountTime('Asia/Kolkata').formatTime(instant, 'HH:mm'), '18:00');
      // Daylight saving time in New York in July, not in January.
      expect(const AccountTime('America/New_York').formatTime(instant, 'hh:mm A'), '08:30 AM');
      final winter = DateTime.utc(2026, 1, 15, 12).millisecondsSinceEpoch ~/ 1000;
      expect(const AccountTime('America/New_York').formatTime(winter, 'HH:mm'), '07:00');
      expect(const AccountTime('UTC').formatTime(instant, 'HH:mm'), '12:30');
    });

    test('without a zone (or with one nobody knows) times are the system\'s', () {
      final local = DateTime.fromMillisecondsSinceEpoch(instant * 1000);
      final hhmm = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
      expect(const AccountTime(null).formatTime(instant, 'HH:mm'), hhmm);
      expect(const AccountTime('Unsupported/Timezone').formatTime(instant, 'HH:mm'), hhmm);
      expect(const AccountTime(null).isLocal, isTrue);
    });

    test('the start of the zone\'s day as an instant', () {
      final now = DateTime.utc(2026, 7, 1, 20); // 05:00 on July 2 in Tokyo
      expect(const AccountTime('Asia/Tokyo').startOfDay(now).toUtc(), DateTime.utc(2026, 7, 1, 15));
      expect(const AccountTime('Asia/Tokyo').startOfDay(now, days: 1).toUtc(), DateTime.utc(2026, 6, 30, 15));
      expect(const AccountTime('America/New_York').startOfDay(now).toUtc(), DateTime.utc(2026, 7, 1, 4));
    });

    testWidgets('of(context) follows the signed-in account', (t) async {
      final f = await _signedIn();
      late AccountTime seen;
      await _pump(
        t,
        f.auth,
        Builder(
          builder: (context) {
            seen = AccountTime.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen.timezone, isNull);
      await f.auth.session.updateProfile(timezone: 'Asia/Tokyo');
      await settle(t);
      expect(seen, const AccountTime('Asia/Tokyo'));
    });
  });
}
