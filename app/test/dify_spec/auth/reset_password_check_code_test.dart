// dify-spec: web/app/reset-password/check-code/__tests__/page.spec.tsx
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/reset_password_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

const _route = ResetPasswordCheckCodeRoute(email: 'user@example.com', token: 'email-token');

Future<(RecordingAuthApi, AuthController)> _render(WidgetTester t) async {
  final api = RecordingAuthApi()..emailSetup = true;
  final auth = await authOn(api);
  auth.go(_route);
  await renderAuth(t, auth, bareForm(const ResetPasswordCheckCodeForm(route: _route)));
  return (api, auth);
}

void main() {
  group('ResetPasswordCheckCodePage', () {
    testWidgets('labels the one-time code field and submits it with Enter', (t) async {
      final (api, auth) = await _render(t);
      final field = t.widget<EditableText>(byLabel('login.checkCode.verificationCode'));
      expect(field.keyboardType, TextInputType.number);
      expect(field.autofillHints, [AutofillHints.oneTimeCode]);

      await typeInto(t, 'login.checkCode.verificationCode', '123456');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleAuth(t);

      expect(api.calls.where((c) => c.$1 == 'checkResetCode').map((c) => c.$2), [
        {'email': 'user@example.com', 'code': '123456', 'token': 'email-token'},
      ]);
      // `/reset-password/set-password?email=user%40example.com&token=verified-token`.
      expect(auth.route, isA<ResetPasswordSetRoute>().having((r) => r.token, 'token', 'verified-token'));
    });

    testWidgets('associates an incomplete code error with the field', (t) async {
      final (api, _) = await _render(t);
      await typeInto(t, 'login.checkCode.verificationCode', '123');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleAuth(t);

      expect(find.text('login.checkCode.invalidCode'), findsOneWidget);
      expect(hasFocus(t, 'login.checkCode.verificationCode'), isTrue);
      expect(api.callNames, isNot(contains('checkResetCode')));
    });
  });
}
