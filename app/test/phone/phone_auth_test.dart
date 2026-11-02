/// The sign-in, server connection, install, activation and password-reset pages on a phone: full bleed (no centred
/// card, no gap above the title), edge to edge with the insets, the server row under the header, the focused field
/// and the submit button above the keyboard, and the keyboard's Done / Go submitting.
library;

import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/auth/activate_page.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/install_page.dart';
import 'package:dify_sf_app/src/auth/reset_password_page.dart';
import 'package:dify_sf_app/src/auth/server_address_form.dart';
import 'package:dify_sf_app/src/auth/signin_page.dart';
import 'package:dify_sf_app/src/auth/widgets/auth_widgets.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/auth_fakes.dart';
import '../support/app_fonts.dart';
import 'phone_harness.dart';

/// The app at [server] signed out (the sign-in page), on the accounts of [accounts].
Future<void> _pumpSignedOut(WidgetTester t, FakeAccounts accounts, {String server = 'https://server.example'}) async {
  await t.pumpWidget(
    buildApp(
      AppSettings(serverUrl: server, journaled: true, lastDoc: ''),
      authApiFor: (_) => FakeAuthApi(accounts),
      tokenStore: MemoryTokenStore(),
      studioPollInterval: null,
    ),
  );
  await settle(t);
}

FakeAccounts _accounts() =>
    FakeAccounts()..addMember(email: 'owner@example.com', name: 'Owner User', role: AccountRole.owner);

Finder _field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in phoneWindows) {
    testWidgets('${w.name}: sign-in is full bleed and edge to edge, the server row under the header', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      await _pumpSignedOut(t, _accounts());
      expect(find.byType(SignInPage), findsOneWidget);
      expect(t.takeException(), isNull);

      // Full bleed: the page's own colour fills the window (no burn frame, no card border).
      final page = find.byWidgetPredicate(
        (wdg) => wdg is ColoredBox && wdg.color == DifyColors.backgroundDefaultSubtle,
      );
      expect(t.getRect(page.first), Offset.zero & w.size);
      expect(
        find.byWidgetPredicate((wdg) => wdg is ColoredBox && wdg.color == DifyColors.backgroundDefaultBurn),
        findsNothing,
      );

      // The header sits below the status bar; the server row is part of the page under it, not over it.
      final header = t.getRect(find.byType(SignInHeader));
      expect(header.top, w.insets.top);
      final server = t.getRect(find.byKey(const ValueKey('server-change')));
      expect(server.top, greaterThanOrEqualTo(header.bottom));
      // No gap: the form starts right under the header and the server row.
      final email = t.getRect(find.byKey(const ValueKey('signin-email')));
      expect(email.top - server.bottom, lessThan(160));
      expect(t.getRect(find.byKey(const ValueKey('signin-submit'))), insideSafeArea(w.size, w.insets));
      await unmount(t);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final size in phoneSizes) {
    testWidgets('${size.width.toInt()} dp: the keyboard keeps the password field and Sign in above it', (t) async {
      phoneWindow(t, size: size);
      await _pumpSignedOut(t, _accounts());
      await t.tap(_field('signin-email'));
      await t.enterText(_field('signin-email'), 'owner@example.com');
      await t.tap(_field('signin-password'));
      openKeyboard(t);
      await settle(t, 800);
      final keyboardTop = size.height - 300;
      final password = t.getRect(find.byKey(const ValueKey('signin-password')));
      final submit = t.getRect(find.byKey(const ValueKey('signin-submit')));
      expect(password.bottom, lessThanOrEqualTo(keyboardTop));
      expect(password.top, greaterThanOrEqualTo(gestureInsets.top));
      expect(submit.bottom, lessThanOrEqualTo(keyboardTop), reason: 'Sign in is reachable with the keyboard open');
      expect(find.byKey(const ValueKey('signin-submit')).hitTestable(), findsOneWidget);
      await unmount(t);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets("the keyboard's Next moves to the password and Done signs in", (t) async {
    phoneWindow(t);
    final accounts = _accounts();
    await _pumpSignedOut(t, accounts);
    await t.tap(_field('signin-email'));
    await t.enterText(_field('signin-email'), 'owner@example.com');
    await t.testTextInput.receiveAction(TextInputAction.next);
    await settle(t, 300);
    expect(t.widget<EditableText>(_field('signin-password')).focusNode.hasFocus, isTrue);
    await t.enterText(_field('signin-password'), 'password-1');
    expect(t.widget<EditableText>(_field('signin-password')).textInputAction, TextInputAction.done);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t, 2500);
    expect(find.byType(SignInPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget, reason: 'signed in');
    await unmount(t);
  });

  testWidgets('a hardware Enter in the password field signs in too', (t) async {
    phoneWindow(t);
    await _pumpSignedOut(t, _accounts());
    await t.tap(_field('signin-email'));
    await t.enterText(_field('signin-email'), 'owner@example.com');
    await t.tap(_field('signin-password'));
    await t.enterText(_field('signin-password'), 'password-1');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(t, 2500);
    expect(find.byType(SignInPage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    await unmount(t);
  });

  testWidgets('back closes the language menu before it leaves the sign-in page', (t) async {
    phoneWindow(t);
    final pops = recordSystemPops(t);
    await _pumpSignedOut(t, _accounts());
    await t.tap(find.byKey(const ValueKey('locale-menu')));
    await settle(t, 500);
    expect(find.text('English (United States)'), findsOneWidget);
    expect(await systemBack(t), isTrue);
    expect(find.text('English (United States)'), findsNothing);
    expect(find.byType(SignInPage), findsOneWidget);
    expect(pops, isEmpty);
    expect(await systemBack(t), isFalse);
    expect(pops, ['SystemNavigator.pop']);
    await unmount(t);
  });

  for (final size in phoneSizes) {
    testWidgets('${size.width.toInt()} dp: the server connection page; Go connects', (t) async {
      phoneWindow(t, size: size);
      await t.pumpWidget(
        buildApp(
          AppSettings(serverUrl: '', journaled: true, lastDoc: ''),
          tokenStore: MemoryTokenStore(),
        ),
      );
      await settle(t);
      expect(find.byType(ServerAddressPage), findsOneWidget);
      expect(t.takeException(), isNull);
      expect(t.getRect(find.byType(SignInHeader)).top, gestureInsets.top);
      final input = find.descendant(
        of: find.byKey(const ValueKey('server-address-input')),
        matching: find.byType(EditableText),
      );
      await t.tap(input);
      openKeyboard(t);
      await settle(t, 800);
      expect(find.byKey(const ValueKey('server-address-connect')).hitTestable(), findsOneWidget);
      expect(t.widget<EditableText>(input).textInputAction, TextInputAction.go);
      await t.enterText(input, 'not a url');
      await t.testTextInput.receiveAction(TextInputAction.go);
      await settle(t, 500);
      expect(find.byKey(const ValueKey('server-address-error')), findsOneWidget, reason: 'Go ran the connect');
      await unmount(t);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final w in phoneWindows) {
    testWidgets('${w.name}: install, activation and password reset use the phone frame', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      final auth = AuthController.on(server: 'http://test', api: RecordingAuthApi(), store: MemoryTokenStore());
      for (final page in <Widget>[
        const InstallPage(),
        const ActivatePage(token: 'token-1'),
        ResetPasswordPage(route: const ResetPasswordRoute()),
      ]) {
        await t.pumpWidget(
          DifyApplication(
            edgeToEdge: true,
            theme: ThemeData(),
            home: AuthScope(controller: auth, child: page),
          ),
        );
        await settle(t, 600);
        expect(t.takeException(), isNull, reason: '${page.runtimeType}');
        expect(t.getRect(find.byType(SignInHeader)).top, w.insets.top, reason: '${page.runtimeType}');
        expect(find.byType(DifyKeyboardScrollView), findsOneWidget, reason: '${page.runtimeType}');
      }
      await unmount(t);
    });
  }
}
