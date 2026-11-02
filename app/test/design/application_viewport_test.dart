import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
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

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 800);
    t.view.viewPadding = const FakeViewPadding(left: 12, top: 30, right: 18, bottom: 24);
    t.view.padding = const FakeViewPadding(left: 12, top: 30, right: 18, bottom: 24);
    addTearDown(t.view.reset);
  }

  testWidgets('pages, fullscreen dialogs and rotation avoid system bars exactly once', (t) async {
    phone(t);
    final navigator = GlobalKey<NavigatorState>();
    const body = ValueKey('page-body'), dialogBody = ValueKey('dialog-body');
    await t.pumpWidget(
      DifyApplication(
        navigatorKey: navigator,
        theme: difyTheme(),
        home: const DifyPage(body: SizedBox.expand(key: body)),
      ),
    );
    expect(t.getRect(find.byKey(body)), const Rect.fromLTRB(12, 30, 382, 776));

    final dialog = showDifyDialog<void>(
      navigator.currentContext!,
      builder: (_) => const SizedBox.expand(key: dialogBody),
    );
    await t.pumpAndSettle();
    expect(t.getRect(find.byKey(dialogBody)), const Rect.fromLTRB(12, 30, 382, 776));
    expect(MediaQuery.paddingOf(t.element(find.byKey(dialogBody))), EdgeInsets.zero);
    navigator.currentState!.pop();
    await t.pumpAndSettle();
    await dialog;

    // A keyboard must still reach the page's Scaffold, without a second inset.
    t.view.viewInsets = const FakeViewPadding(bottom: 280);
    t.view.padding = const FakeViewPadding(left: 12, top: 30, right: 18);
    await t.pumpAndSettle();
    expect(t.getRect(find.byKey(body)), const Rect.fromLTRB(12, 30, 382, 520));

    t.view.viewInsets = const FakeViewPadding();
    t.view.physicalSize = const Size(800, 400);
    t.view.viewPadding = const FakeViewPadding(left: 32, right: 12, bottom: 16);
    t.view.padding = const FakeViewPadding(left: 32, right: 12, bottom: 16);
    await t.pumpAndSettle();
    expect(t.getRect(find.byKey(body)), const Rect.fromLTRB(32, 0, 788, 384));
    expect(t.takeException(), isNull);
  });

  testWidgets('global toast stays inside the safe viewport and keeps the system bar style', (t) async {
    phone(t);
    final manager = DifyToastManager();
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(brightness: Brightness.dark),
        home: const SizedBox.expand(),
        builder: (_, child) => Stack(
          fit: StackFit.expand,
          children: [
            child!,
            DifyToastHost(manager: manager, timeout: Duration.zero),
          ],
        ),
      ),
    );
    final region = find.byType(AnnotatedRegion<SystemUiOverlayStyle>);
    SystemUiOverlayStyle bars() => t.widget<AnnotatedRegion<SystemUiOverlayStyle>>(region).value;
    final before = bars();
    manager.add(const DifyToastData(id: 'failure', title: 'Connection failed', type: DifyToastType.error));
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(DifyToastHost)), const Rect.fromLTRB(12, 30, 382, 776));
    expect(t.getTopLeft(find.text('Connection failed')).dy, greaterThanOrEqualTo(46));
    expect(bars(), before);
    expect(bars().statusBarColor, Colors.transparent);
    expect(bars().statusBarIconBrightness, Brightness.light);
    expect(bars().systemNavigationBarIconBrightness, Brightness.light);
    // The insets have an opaque app background even when the page has no Scaffold.
    expect(
      find.byWidgetPredicate(
        (w) => w is ColoredBox && t.getRect(find.byWidget(w)) == const Rect.fromLTWH(0, 0, 400, 800),
      ),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('native sign-in server chrome has a body style without yellow double underlines', (t) async {
    phone(t);
    await t.pumpWidget(
      buildApp(
        AppSettings(serverUrl: 'https://server.example', journaled: true, lastDoc: ''),
        authApiFor: (_) => RecordingAuthApi(),
        tokenStore: MemoryTokenStore(),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final banner = find.byKey(const ValueKey('server-change'));
    expect(banner, findsOneWidget);
    expect(t.getTopLeft(banner).dy, greaterThanOrEqualTo(30));
    final label = find.descendant(of: banner, matching: find.byType(RichText));
    final style = t.widget<RichText>(label).text.style!;
    expect(style.decoration, TextDecoration.none);
    expect(style.fontSize, lessThan(20));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
