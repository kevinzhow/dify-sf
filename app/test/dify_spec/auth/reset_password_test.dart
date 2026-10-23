// dify-spec: web/app/reset-password/__tests__/page.spec.tsx
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/reset_password_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

Future<(RecordingAuthApi, AuthController)> _render(WidgetTester t) async {
  final api = RecordingAuthApi()..emailSetup = true;
  final auth = await authOn(api);
  auth.go(const ResetPasswordRoute());
  await renderAuth(t, auth, bareForm(const ResetPasswordForm()));
  return (api, auth);
}

void main() {
  group('ResetPasswordPage', () {
    testWidgets('labels the email field and submits it with Enter', (t) async {
      final (api, auth) = await _render(t);
      final field = t.widget<EditableText>(byLabel('login.email'));
      expect(field.autofillHints, [AutofillHints.email]);

      await typeInto(t, 'login.email', 'user@example.com');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleAuth(t);

      expect(api.calls.where((c) => c.$1 == 'sendResetCode').map((c) => c.$2), [
        {'email': 'user@example.com', 'language': 'en-US'},
      ]);
      // `/reset-password/check-code?token=reset-token&email=user%2540example.com`, the countdown started.
      expect(
        auth.route,
        isA<ResetPasswordCheckCodeRoute>()
            .having((r) => r.email, 'email', 'user@example.com')
            .having((r) => r.token, 'token', 'reset-token'),
      );
      expect(auth.countdownLeftMs, resendCountdownMs);
    });

    testWidgets('keeps one associated error when an invalid email is cleared', (t) async {
      final (api, _) = await _render(t);
      await typeInto(t, 'login.email', 'invalid-email');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleAuth(t);

      expect(find.text('login.error.emailInValid'), findsOneWidget);
      expect(hasFocus(t, 'login.email'), isTrue);
      expect(api.callNames, isNot(contains('sendResetCode')));

      await t.enterText(byLabel('login.email'), '');
      await t.pump();
      await t.tap(find.text('login.sendVerificationCode'));
      await settleAuth(t);

      expect(find.text('login.error.emailEmpty'), findsOneWidget);
      expect(find.text('login.error.emailInValid'), findsNothing);
      expect(hasFocus(t, 'login.email'), isTrue);
      expect(api.callNames, isNot(contains('sendResetCode')));
    });
  });
}
