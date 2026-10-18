// dify-spec: web/app/signin/invite-settings/__tests__/page.spec.tsx
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/invite_settings_page.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import '../dify_test_i18n.dart';
import 'harness.dart';

const _token = 'invite-token';
const _invitee = 'invitee@example.com';

/// Dify's mocks: `login.joinWorkspace` translates to "Rejoindre {{workspaceName}}".
class _Translator extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      ns == 'login' && key == 'joinWorkspace' ? 'Rejoindre ${params['workspaceName']}' : super.t(ns, key, params);
}

/// The page after the invitation's sign-in step (dify-sf: the password kept for the activation; [signedInAs]: an
/// account that is signed in instead).
Future<(RecordingAuthApi, AuthController)> _render(
  WidgetTester t, {
  String locale = 'zh-Hans',
  InvitationCheck? check,
  String? signedInAs,
}) async {
  final api = RecordingAuthApi()..addAccount(email: 'current@example.com');
  api.invitations[_token] = (email: _invitee, role: AccountRole.normal);
  if (check != null) {
    api.checkAnswers[_token] = check;
    if (check.accountStatus == 'active') api.addAccount(email: _invitee, name: 'Invitee', role: AccountRole.normal);
  }
  final auth = await authOn(api, signedInAs: signedInAs);
  if (signedInAs == null) {
    auth.continueInvite(inviteToken: _token, password: 'Password123');
  } else {
    auth.go(const InviteSettingsRoute(_token));
  }
  await renderAuth(
    t,
    auth,
    bareForm(InviteSettingsForm(inviteToken: _token, browserTimezone: () => 'Asia/Shanghai')),
    locale: AppLocale(locale),
    translator: _Translator(),
  );
  return (api, auth);
}

const _active = InvitationCheck(
  isValid: true,
  email: _invitee,
  workspaceName: 'Acme',
  accountStatus: 'active',
  requiresSetup: false,
);

Map<String, Object?> _activation(RecordingAuthApi api) => api.calls.where((c) => c.$1 == 'activate').single.$2;

/// `getByRole('button', { name: 'Rejoindre Acme' })`.
Finder _button() => find.byKey(const ValueKey('invite-submit'));

String _title(WidgetTester t) => t.widget<Title>(find.byType(Title).last).title;

void main() {
  group('InviteSettingsPage', () {
    testWidgets('exposes the page title as the main heading', (t) async {
      await _render(t);
      expect(find.semantics.byPredicate((n) => n.getSemanticsData().headingLevel == 1), findsOne);
      expect(_title(t), 'login.setYourAccount - Dify');
    });

    testWidgets('uses the workspace invitation as the page title for an active account', (t) async {
      await _render(t, check: _active);
      expect(_title(t), 'Rejoindre Acme - Dify');
    });

    group('Activation payload', () {
      testWidgets('associates a missing name error with the account field', (t) async {
        final (api, _) = await _render(t);
        await t.tap(_button());
        await settleAuth(t);
        expect(find.text('login.enterYourName'), findsOneWidget);
        expect(hasFocus(t, 'login.name'), isTrue);
        expect(api.callNames, isNot(contains('activate')));
      });

      testWidgets('should default language to the current UI locale', (t) async {
        final (api, _) = await _render(t);
        await typeInto(t, 'login.name', 'Invitee');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await settleAuth(t);
        // dify-sf activates with the password from the sign-in step (protocol 1.8).
        expect(_activation(api), {
          'token': _token,
          'name': 'Invitee',
          'password': 'Password123',
          'interface_language': 'zh-Hans',
          'timezone': 'Asia/Shanghai',
        });
      });

      testWidgets('should fall back to configured default locale when current locale is unsupported', (t) async {
        final (api, _) = await _render(t, locale: 'unsupported-locale');
        await typeInto(t, 'login.name', 'Invitee');
        await t.tap(_button());
        await settleAuth(t);
        expect(_activation(api)['interface_language'], 'en-US');
        expect(_activation(api)['timezone'], 'Asia/Shanghai');
      });

      testWidgets('should submit setup fields when the invitation requires account setup', (t) async {
        final (api, _) = await _render(
          t,
          check: const InvitationCheck(
            isValid: true,
            email: _invitee,
            workspaceName: 'Acme',
            accountStatus: 'active',
            requiresSetup: true,
          ),
        );
        await typeInto(t, 'login.name', 'Invitee');
        await t.tap(_button());
        await settleAuth(t);
        expect(_activation(api), {
          'token': _token,
          'name': 'Invitee',
          'password': 'Password123',
          'interface_language': 'zh-Hans',
          'timezone': 'Asia/Shanghai',
        });
      });
    });

    group('Post-activation redirect', () {
      // dify-sf has no redirect targets: the console home.
      testWidgets('should use the console home when the redirect target is external', (t) async {
        final (_, auth) = await _render(t);
        await typeInto(t, 'login.name', 'Invitee');
        await t.tap(_button());
        await settleAuth(t);
        expect(auth.route, isA<HomeRoute>());
        expect(auth.account?.email, _invitee);
      });
    });

    group('Invitation account guard', () {
      testWidgets('should redirect a different logged-in account back to the invitation sign-in form', (t) async {
        final (api, auth) = await _render(t, signedInAs: 'current@example.com');
        expect(auth.route, isA<SignInRoute>().having((r) => r.inviteToken, 'inviteToken', _token));
        expect(_button(), findsNothing);
        expect(api.callNames, isNot(contains('activate')));
      });

      testWidgets('should allow case-insensitive email matches', (t) async {
        final (_, auth) = await _render(
          t,
          check: const InvitationCheck(isValid: true, email: 'Invitee@Example.com', workspaceName: 'Acme'),
        );
        expect(find.descendant(of: _button(), matching: find.text('Rejoindre Acme')), findsOneWidget);
        expect(auth.route, isA<InviteSettingsRoute>());
      });
    });
  });
}
