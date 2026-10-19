// dify-spec: web/app/reset-password/set-password/__tests__/page.spec.tsx
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/reset_password_page.dart';
import 'package:dify_sf_app/src/auth/widgets/auth_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

Future<(RecordingAuthApi, AuthController)> _render(WidgetTester t, {String? inviteToken}) async {
  final api = RecordingAuthApi();
  final auth = await authOn(api);
  final route = ResetPasswordSetRoute(token: 'reset-token', inviteToken: inviteToken);
  auth.go(route);
  await renderAuth(t, auth, bareForm(SetPasswordForm(route: route)));
  return (api, auth);
}

/// The window title shown (`useDocumentTitle`).
String _documentTitle(WidgetTester t) => t.widgetList<Title>(find.byType(Title)).last.title;

Future<(RecordingAuthApi, AuthController)> _completePasswordChange(WidgetTester t, {String? inviteToken}) async {
  final r = await _render(t, inviteToken: inviteToken);
  expect(find.text('login.changePassword'), findsOneWidget);
  await typeInto(t, 'common.account.newPassword', 'ValidPass123!');
  await typeInto(t, 'common.account.confirmPassword', 'ValidPass123!');
  await t.tap(find.text('login.changePasswordBtn'));
  await settleAuth(t, 2);
  expect(find.textContaining('login.passwordChanged ('), findsOneWidget);
  expect(find.text('login.passwordChangedTip'), findsOneWidget);
  expect(_documentTitle(t), DifyDocumentTitle.format('login.passwordChangedTip'));
  return r;
}

void main() {
  group('Reset Password Set Password Page', () {
    testWidgets('reconciles the initial route title with client branding', (t) async {
      await _render(t);
      expect(_documentTitle(t), DifyDocumentTitle.format('login.changePassword'));
    });

    testWidgets('supports password reveal and native form submission', (t) async {
      final (api, _) = await _render(t);
      final password = byLabel('common.account.newPassword'), confirm = byLabel('common.account.confirmPassword');
      expect(t.widget<EditableText>(password).autofillHints, [AutofillHints.newPassword]);
      expect(t.widget<EditableText>(confirm).autofillHints, [AutofillHints.newPassword]);
      // The rule is the new password's description until it fails.
      expect(find.text('login.error.passwordInvalid'), findsOneWidget);

      await typeInto(t, 'common.account.newPassword', 'ValidPass123!');
      await t.tap(find.bySemanticsLabel('login.showPassword').first);
      await t.pump();
      expect(t.widget<EditableText>(password).obscureText, isFalse);
      expect(find.bySemanticsLabel('login.hidePassword'), findsOneWidget);

      await typeInto(t, 'common.account.confirmPassword', 'ValidPass123!');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleAuth(t, 2);
      expect(api.calls.where((c) => c.$1 == 'resetPassword').map((c) => c.$2), [
        {'token': 'reset-token', 'new_password': 'ValidPass123!', 'password_confirm': 'ValidPass123!'},
      ]);
    });

    testWidgets('revalidates the confirmation field when the password changes', (t) async {
      final (api, _) = await _render(t);
      await typeInto(t, 'common.account.newPassword', 'ValidPass123!');
      await typeInto(t, 'common.account.confirmPassword', 'DifferentPass123!');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleAuth(t, 2);

      expect(find.text('common.account.notEqual'), findsOneWidget);
      expect(hasFocus(t, 'common.account.confirmPassword'), isTrue);
      expect(api.callNames, isNot(contains('resetPassword')));

      await t.enterText(byLabel('common.account.newPassword'), '');
      await t.pump();
      await t.enterText(byLabel('common.account.newPassword'), 'DifferentPass123!');
      await t.pump();
      expect(find.text('common.account.notEqual'), findsNothing);
      expect(api.callNames, isNot(contains('resetPassword')));
    });

    group('Post-reset navigation', () {
      // dify-sf has no redirect targets (no `redirect_url`): returning to sign in is the plain sign-in page.
      testWidgets('should preserve redirect_url when the user returns to sign in manually', (t) async {
        final (_, auth) = await _completePasswordChange(t);
        await t.tap(find.textContaining('login.passwordChanged ('));
        await t.pump();
        expect(auth.route, isA<SignInRoute>().having((r) => r.isInvite, 'invite', isFalse));
      });

      testWidgets('should preserve redirect_url when the countdown returns to sign in automatically', (t) async {
        final (_, auth) = await _completePasswordChange(t);
        expect(auth.route, isA<ResetPasswordSetRoute>());
        await t.pump(const Duration(seconds: 5));
        expect(auth.route, isA<SignInRoute>());
      });

      testWidgets('should preserve the activation redirect when an invite token is present', (t) async {
        final (_, auth) = await _completePasswordChange(t, inviteToken: 'invite-token');
        await t.tap(find.textContaining('login.passwordChanged ('));
        await t.pump();
        expect(auth.route, isA<ActivateRoute>().having((r) => r.token, 'token', 'invite-token'));
      });

      testWidgets('should return to plain sign in when no redirect target is present', (t) async {
        final (_, auth) = await _completePasswordChange(t);
        await t.tap(find.textContaining('login.passwordChanged ('));
        await t.pump();
        expect(auth.route, isA<SignInRoute>());
      });
    });
  });
}
