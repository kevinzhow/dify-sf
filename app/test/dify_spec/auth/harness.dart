import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/controls.dart' show DifyInput;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import '../dify_test_i18n.dart';

/// A controller on [api] (signed out unless [signedInAs] names an account of it).
Future<AuthController> authOn(RecordingAuthApi api, {String? signedInAs, String password = 'Password123'}) async {
  final auth = AuthController.on(server: 'http://test', api: api, store: MemoryTokenStore());
  if (signedInAs != null) await auth.signIn(email: signedInAs, password: password);
  return auth;
}

/// Dify's `renderWithConsoleQuery`: [child] in the app's scopes (the session, the UI language) with Dify's test
/// translator (`<ns>.<key>`), on a 1440 x 900 page.
Future<void> renderAuth(
  WidgetTester t,
  AuthController auth,
  Widget child, {
  AppLocale? locale,
  Translator? translator,
}) async {
  useDifyTestTranslator();
  if (translator != null) DifyI18n.current = translator;
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AppLocaleScope(
        locale: locale ?? AppLocale('en-US'),
        child: AuthScope(
          controller: auth,
          child: Material(child: child),
        ),
      ),
    ),
  );
  await settleAuth(t);
}

/// Lets the fake's futures and the pages' effects run (not pumpAndSettle: the loading squares never settle).
Future<void> settleAuth(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The text field labelled [label] (`getByLabelText`: the input's accessible name).
Finder byLabel(String label) => find
    .descendant(
      of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == label),
      matching: find.byType(EditableText),
    )
    .first;

/// Types into the field labelled [label].
Future<void> typeInto(WidgetTester t, String label, String text) async {
  await t.tap(byLabel(label));
  await t.enterText(byLabel(label), text);
  await t.pump();
}

/// The focused text field's label, if a labelled field has focus.
bool hasFocus(WidgetTester t, String label) => t.widget<EditableText>(byLabel(label)).focusNode.hasFocus;

/// A form on its own (Dify renders it without the page): 400 px wide, scrolling.
Widget bareForm(Widget form) => SingleChildScrollView(
  child: Center(child: SizedBox(width: 400, child: form)),
);
