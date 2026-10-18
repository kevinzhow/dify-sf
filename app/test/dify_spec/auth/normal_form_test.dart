// dify-spec: web/app/signin/__tests__/normal-form.spec.tsx
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/signin_page.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

const _invitee = 'invitee@example.com';

/// The sign-in page for [route] with [signedInAs] signed in (an account of the fake, `null`: signed out).
Future<(RecordingAuthApi, AuthController)> _render(
  WidgetTester t, {
  SignInRoute route = const SignInRoute(),
  String? signedInAs,
  String? inviteEmail,
}) async {
  final api = RecordingAuthApi()
    ..addAccount(email: _invitee)
    ..addAccount(email: 'current@example.com');
  if (inviteEmail != null) api.invitations['invite-token'] = (email: inviteEmail, role: 'normal');
  final auth = await authOn(api, signedInAs: signedInAs);
  auth.go(route);
  await renderAuth(t, auth, bareForm(NormalForm(route: route)));
  return (api, auth);
}

const _invite = SignInRoute(inviteToken: 'invite-token');

void main() {
  group('NormalForm', () {
    testWidgets('exposes the page title as the main heading', (t) async {
      await _render(t);
      expect(
        find.semantics.byPredicate((n) => n.getSemanticsData().headingLevel == 1 && n.label == 'login.pageTitle'),
        findsOne,
      );
    });

    group('Default Redirects', () {
      testWidgets('should send logged-in visitors without a redirect target to the console home', (t) async {
        final (_, auth) = await _render(t, signedInAs: _invitee);
        expect(auth.route, isA<HomeRoute>());
      });

      // dify-sf has no redirect targets: a signed-in visitor always goes home.
      testWidgets('should send logged-in visitors with an external redirect target to the console home', (t) async {
        final (_, auth) = await _render(t, signedInAs: _invitee);
        expect(auth.route, isA<HomeRoute>());
      });
    });

    group('Invite Redirects', () {
      testWidgets('should send logged-in invite visitors to the invite confirmation page', (t) async {
        final (_, auth) = await _render(t, route: _invite, signedInAs: _invitee, inviteEmail: _invitee);
        expect(auth.route, isA<InviteSettingsRoute>().having((r) => r.inviteToken, 'inviteToken', 'invite-token'));
      });

      testWidgets('should keep a different logged-in account on the invitation sign-in form', (t) async {
        final (_, auth) = await _render(t, route: _invite, signedInAs: 'current@example.com', inviteEmail: _invitee);
        expect(find.text('login.signBtn'), findsOneWidget);
        expect(auth.route, isA<SignInRoute>());
      });

      testWidgets('should match the logged-in account email case-insensitively', (t) async {
        final (_, auth) = await _render(t, route: _invite, signedInAs: _invitee, inviteEmail: 'Invitee@Example.com');
        expect(auth.route, isA<InviteSettingsRoute>());
      });
    });

    testWidgets('should describe password visibility through its changing action name', (t) async {
      await _render(t);
      expect(find.bySemanticsLabel('login.showPassword'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('login.showPassword'));
      await t.pump();
      expect(find.bySemanticsLabel('login.hidePassword'), findsOneWidget);
      expect(t.widget<EditableText>(byLabel('login.password')).obscureText, isFalse);
    });

    // Dify's case turns mail on (`is_email_setup`), which makes "Forgot your password?" the next stop; dify-sf has no
    // mail server, and Dify then takes the link out of the tab order (`tabIndex={-1}`), as here.
    testWidgets('keeps credential inputs together before secondary password actions in the tab order', (t) async {
      await _render(t);
      await t.tap(byLabel('login.email'));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocus(t, 'login.password'), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      Widget? focusedIn<T extends Widget>() =>
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<T>();
      expect(focusedIn<DifyIconButton>()?.key, const ValueKey('reveal-password'));
      // The disabled reset link is skipped: the next stop is "Sign in".
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(focusedIn<DifyButton>()?.key, const ValueKey('signin-submit'));
    });

    testWidgets('associates input validation errors with the invalid credential field', (t) async {
      final (api, _) = await _render(t);
      await typeInto(t, 'login.email', 'invalid-email');
      await typeInto(t, 'login.password', 'password');
      await t.tap(find.text('login.signBtn'));
      await settleAuth(t);
      expect(find.text('login.error.emailInValid'), findsOneWidget);
      expect(hasFocus(t, 'login.email'), isTrue);
      expect(api.callNames, isNot(contains('login')));
    });

    testWidgets('should not expose SSO when it is enforced without a configured protocol', (t) async {
      await _render(t);
      expect(find.text('login.withSSO'), findsNothing);
      expect(find.bySemanticsLabel('login.withSSO'), findsNothing);
    });
  });
}
