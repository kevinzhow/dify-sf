// dify-spec: web/app/install/installForm.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/install_page.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

Future<(RecordingAuthApi, AuthController)> _render(WidgetTester t, {bool setupDone = false}) async {
  final api = RecordingAuthApi(setupDone: setupDone);
  final auth = await authOn(api);
  auth.go(const InstallRoute());
  await renderAuth(t, auth, const InstallPage());
  return (api, auth);
}

Finder _submit() => find.byKey(const ValueKey('install-submit'));

Future<void> _fill(WidgetTester t) async {
  await typeInto(t, 'login.email', 'admin@example.com');
  await typeInto(t, 'login.name', 'Admin');
  await typeInto(t, 'login.password', 'Password123');
}

void main() {
  group('InstallForm', () {
    testWidgets('should render form after loading', (t) async {
      await _render(t);
      final email = t.widget<EditableText>(byLabel('login.email'));
      final name = t.widget<EditableText>(byLabel('login.name'));
      final password = t.widget<EditableText>(byLabel('login.password'));
      expect(email.keyboardType, TextInputType.emailAddress);
      expect(email.autofillHints, [AutofillHints.email]);
      expect(name.autofillHints, [AutofillHints.name]);
      expect(
        t.widget<TextField>(find.ancestor(of: byLabel('login.name'), matching: find.byType(TextField))).maxLength,
        30,
      );
      expect(password.autofillHints, [AutofillHints.newPassword]);
      expect(
        find.semantics.byPredicate((n) => n.getSemanticsData().headingLevel == 1 && n.label == 'login.setAdminAccount'),
        findsOne,
      );
      expect(find.text('login.installBtn'), findsOneWidget);
    });

    testWidgets('should reveal and hide the password with an accessible action', (t) async {
      await _render(t);
      bool obscured() => t.widget<EditableText>(byLabel('login.password')).obscureText;
      expect(obscured(), isTrue);
      await t.tap(find.bySemanticsLabel('login.showPassword'));
      await t.pump();
      expect(obscured(), isFalse);
      await t.tap(find.bySemanticsLabel('login.hidePassword'));
      await t.pump();
      expect(obscured(), isTrue);
    });

    testWidgets('should identify required fields only after submission', (t) async {
      final (api, _) = await _render(t);
      expect(find.text('login.error.emailInValid'), findsNothing);
      expect(find.text('login.error.nameEmpty'), findsNothing);
      // The password rule shows as the field's description until the field fails.
      expect(find.text('login.error.passwordInvalid'), findsOneWidget);
      expect(find.byKey(const ValueKey('field-description')), findsOneWidget);

      await t.tap(_submit());
      await settleAuth(t);
      expect(find.text('login.error.emailInValid'), findsOneWidget);
      expect(find.text('login.error.nameEmpty'), findsOneWidget);
      expect(find.text('login.error.passwordInvalid'), findsOneWidget);
      expect(find.byKey(const ValueKey('field-error')), findsNWidgets(3));
      expect(find.byKey(const ValueKey('field-description')), findsNothing);
      expect(api.callNames, isNot(contains('setup')));
    });

    testWidgets('should identify an invalid email and focus the field', (t) async {
      final (api, _) = await _render(t);
      await typeInto(t, 'login.email', 'invalid-email');
      await t.tap(_submit());
      await settleAuth(t);
      expect(find.text('login.error.emailInValid'), findsOneWidget);
      expect(hasFocus(t, 'login.email'), isTrue);
      expect(api.callNames, isNot(contains('setup')));
    });

    testWidgets('should enforce the password requirements before submission', (t) async {
      final (api, _) = await _render(t);
      await typeInto(t, 'login.email', 'admin@example.com');
      await typeInto(t, 'login.name', 'Admin');
      await typeInto(t, 'login.password', 'abcdefgh');
      await t.tap(_submit());
      await settleAuth(t);
      expect(find.byKey(const ValueKey('field-error')), findsOneWidget);
      expect(hasFocus(t, 'login.password'), isTrue);
      expect(api.callNames, isNot(contains('setup')));
    });

    testWidgets('should submit and redirect to the console root on successful login', (t) async {
      final (api, auth) = await _render(t);
      await _fill(t);
      await t.tap(_submit());
      await settleAuth(t);
      expect(api.calls.where((c) => c.$1 == 'setup').single.$2, {
        'email': 'admin@example.com',
        'name': 'Admin',
        'password': 'Password123',
        'language': 'en-US',
      });
      // Protocol 1.8's setup answers with the session: signed in without a second request.
      expect(auth.signedIn, isTrue);
      expect(auth.route, isA<HomeRoute>());
    });

    testWidgets('should disable submit while request is in flight', (t) async {
      final (api, _) = await _render(t);
      final gate = api.hold['setup'] = Completer<void>();
      await _fill(t);
      await t.tap(_submit());
      await t.pump();
      expect(t.widget<DifyButton>(_submit()).loading, isTrue);
      await t.tap(_submit());
      await t.pump();
      expect(api.callNames.where((n) => n == 'setup'), hasLength(1));
      gate.complete();
      await settleAuth(t);
      expect(api.callNames.where((n) => n == 'setup'), hasLength(1));
    });

    testWidgets('should redirect to sign in when setup is finished', (t) async {
      final (_, auth) = await _render(t, setupDone: true);
      expect(auth.route, isA<SignInRoute>());
    });
  });
}
