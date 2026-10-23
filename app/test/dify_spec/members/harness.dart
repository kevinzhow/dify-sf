import 'dart:ui' show Tristate;

import 'package:collab_client/testing.dart' show FakeAccounts, FakeAuthApi;
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

/// A workspace on the in-memory accounts server: the owner `owner@example.com` ("Owner User") and an admin
/// `admin@example.com` ("Admin User"), plus [more] members (email, name, role); signed in as [as].
class MembersFixture {
  MembersFixture._(this.accounts, this.auth, this.members);

  final FakeAccounts accounts;
  final AuthController auth;
  final WorkspaceMembers members;

  static Future<MembersFixture> create({
    String as = 'owner@example.com',
    List<(String email, String name, String role)> more = const [],
  }) async {
    final accounts = FakeAccounts()
      ..addMember(email: 'owner@example.com', name: 'Owner User', role: AccountRole.owner)
      ..addMember(email: 'admin@example.com', name: 'Admin User', role: AccountRole.admin);
    for (final (email, name, role) in more) {
      accounts.addMember(email: email, name: name, role: role);
    }
    final auth = AuthController.on(server: 'http://test', api: FakeAuthApi(accounts), store: MemoryTokenStore());
    await auth.signIn(email: as, password: 'password-1');
    final members = WorkspaceMembers(auth);
    await members.refresh();
    return MembersFixture._(accounts, auth, members);
  }

  String idOf(String email) => accounts.byEmail(email)!.id;
}

/// Dify's `renderWithConsoleQuery`: [child] with Dify's test translator (`<ns>.<key>`), the app's toast host (toasts
/// stay until closed) and the session, on a 1440 x 900 page.
Future<void> renderMembers(WidgetTester t, Widget child, {AuthController? auth}) async {
  useDifyTestTranslator();
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  Widget home = Material(child: child);
  if (auth != null) home = AuthScope(controller: auth, child: home);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: home,
      builder: (context, c) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await settle(t);
}

/// Lets the fake's futures, the dialogs' transitions and the pages' effects run.
Future<void> settle(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The widget with the semantics label [label] that is a button.
SemanticsFinder button(String label) => find.semantics.byPredicate(
  (n) => n.getSemanticsData().flagsCollection.isButton && n.label == label,
  describeMatch: (_) => 'button "$label"',
);

/// A button whose label matches [pattern].
SemanticsFinder buttonMatching(Pattern pattern) => find.semantics.byPredicate(
  (n) => n.getSemanticsData().flagsCollection.isButton && n.label.contains(pattern),
  describeMatch: (_) => 'button matching "$pattern"',
);

/// Taps the semantics node of the button labelled [label] (its tap action, as a screen reader would).
Future<void> tapButton(WidgetTester t, String label) async {
  final node = button(label).evaluate().single;
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await settle(t);
}

/// Whether the semantics node of the button labelled [label] is enabled.
bool isEnabled(String label) =>
    button(label).evaluate().single.getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;

// ---- the recipient composer -------------------------------------------------------------------------------------

/// The composer's text input.
Finder get emailInput => find.byKey(const ValueKey('email-recipients-input'));

EditableText _editable(WidgetTester t) =>
    t.widget<EditableText>(find.descendant(of: emailInput, matching: find.byType(EditableText)));

/// The composer's draft text.
String draftText(WidgetTester t) => _editable(t).controller.text;

/// Whether the composer's input has focus.
bool emailHasFocus(WidgetTester t) => _editable(t).focusNode.hasFocus;

/// Focuses the composer (a click) and connects the test keyboard.
Future<void> focusEmail(WidgetTester t) async {
  await t.showKeyboard(emailInput);
  await t.pump();
}

/// The test clipboard (Clipboard.setData / getData), installed by [useTestClipboard].
String? testClipboard;

/// Answers the platform's clipboard calls from [testClipboard].
void useTestClipboard(WidgetTester t) {
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') testClipboard = (call.arguments as Map)['text'] as String?;
    if (call.method == 'Clipboard.getData') return testClipboard == null ? null : {'text': testClipboard};
    if (call.method == 'Clipboard.hasStrings') return {'value': testClipboard != null};
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

/// Pastes [text] from the keyboard (Ctrl+V) where the composer's caret is, as `user.paste` does.
Future<void> pasteText(WidgetTester t, String text) async {
  if (!emailHasFocus(t)) await focusEmail(t);
  useTestClipboard(t);
  testClipboard = text;
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyV);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
  await t.pump();
}

/// Types [text] one character at a time (`user.type`); `{Enter}` presses Enter, `{Backspace}` Backspace.
Future<void> typeText(WidgetTester t, String text) async {
  if (!emailHasFocus(t)) await focusEmail(t);
  final parts = RegExp(r'\{(\w+)\}|.', dotAll: true).allMatches(text);
  for (final m in parts) {
    final key = m[1];
    if (key != null) {
      await t.sendKeyEvent(switch (key) {
        'Enter' => LogicalKeyboardKey.enter,
        'Backspace' => LogicalKeyboardKey.backspace,
        'ArrowLeft' => LogicalKeyboardKey.arrowLeft,
        'ArrowRight' => LogicalKeyboardKey.arrowRight,
        'Delete' => LogicalKeyboardKey.delete,
        _ => throw ArgumentError(key),
      });
      await t.pump();
      continue;
    }
    if (!emailHasFocus(t)) {
      // A key moved focus away (to a chip); typing continues wherever focus is, as in the browser.
      continue;
    }
    final v = _editable(t).controller.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final next = v.text.replaceRange(sel.start, sel.end, m[0]!);
    t.testTextInput.updateEditingValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: sel.start + 1),
      ),
    );
    await t.pump();
  }
}

/// Presses [key] where focus is.
Future<void> press(WidgetTester t, LogicalKeyboardKey key) async {
  await t.sendKeyEvent(key);
  await t.pump();
}

/// The chip of [value].
Finder chip(String value) => find.byKey(ValueKey('recipient-$value'));

/// Whether the chip of [value] has focus.
bool chipHasFocus(WidgetTester t, String value) => Focus.of(
  t.element(find.descendant(of: chip(value), matching: find.byType(GestureDetector)).first),
).hasFocus;

/// Whether the focused widget is [finder]'s widget or inside it.
bool focusIsIn(Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final targets = finder.evaluate().toSet();
  var inside = targets.contains(focused);
  focused.visitAncestorElements((e) {
    if (targets.contains(e)) inside = true;
    return !inside;
  });
  return inside;
}

/// Whether the semantics node of the button whose label contains [label] is enabled.
bool buttonEnabled(Pattern label) =>
    buttonMatching(label).evaluate().first.getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;
