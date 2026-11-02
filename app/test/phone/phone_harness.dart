// Shared set-up for the phone shell tests (compact windows): the real app (buildApp) on fake servers at phone sizes
// with the system bars' insets.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/studio_fakes.dart';

export '../support/studio_fakes.dart';

/// Gesture navigation: a 32 dp status bar and a 24 dp gesture handle.
const gestureInsets = EdgeInsets.only(top: 32, bottom: 24);

/// Three-button navigation: a 32 dp status bar and a 48 dp navigation bar.
const threeButtonInsets = EdgeInsets.only(top: 32, bottom: 48);

/// The phone windows the brief names: a 411x914 phone and a 360x780 one.
const phoneSizes = [Size(411, 914), Size(360, 780)];

/// The window sizes and insets every phone screen is checked in.
const phoneWindows = [
  (size: Size(411, 914), insets: gestureInsets, name: '411x914 gesture'),
  (size: Size(411, 914), insets: threeButtonInsets, name: '411x914 three-button'),
  (size: Size(360, 780), insets: gestureInsets, name: '360x780 gesture'),
  (size: Size(360, 780), insets: threeButtonInsets, name: '360x780 three-button'),
];

Future<void> settle(WidgetTester t, [int ms = 1500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A phone window [size] dp at a device pixel ratio of 1 with the system bars' [insets] (no keyboard).
void phoneWindow(WidgetTester t, {Size size = const Size(411, 914), EdgeInsets insets = gestureInsets}) {
  FakeViewPadding fake(EdgeInsets e) => FakeViewPadding(left: e.left, top: e.top, right: e.right, bottom: e.bottom);
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  t.view.padding = fake(insets);
  t.view.viewPadding = fake(insets);
  t.view.viewInsets = FakeViewPadding.zero;
  addTearDown(t.view.reset);
}

/// Opens the soft keyboard ([height] dp) over [insets]: Android reports the bars' full size as the view padding and
/// no bottom padding under the keyboard.
void openKeyboard(WidgetTester t, {double height = 300, EdgeInsets insets = gestureInsets}) {
  t.view.viewPadding = FakeViewPadding(top: insets.top, bottom: insets.bottom);
  t.view.padding = FakeViewPadding(top: insets.top);
  t.view.viewInsets = FakeViewPadding(bottom: height);
}

void closeKeyboard(WidgetTester t, {EdgeInsets insets = gestureInsets}) {
  t.view.padding = FakeViewPadding(top: insets.top, bottom: insets.bottom);
  t.view.viewInsets = FakeViewPadding.zero;
}

typedef Workspace = ({FakeAppsApi api, AuthController auth, FakeAccounts accounts});

/// A workspace (owner, editor Kim, normal member Nia) signed in as [as]; the apps server's caller is that account.
Future<Workspace> workspace({String as = 'owner@example.com'}) async {
  final accounts = FakeAccounts()
    ..addMember(email: 'owner@example.com', name: 'Owner User', role: AccountRole.owner)
    ..addMember(email: 'kim@example.com', name: 'Kim', role: AccountRole.editor)
    ..addMember(email: 'nia@example.com', name: 'Nia', role: AccountRole.normal);
  final auth = AuthController.on(server: 'http://test', api: FakeAuthApi(accounts), store: MemoryTokenStore());
  await auth.signIn(email: as, password: 'password-1');
  final me = auth.account!;
  final owner = accounts.byEmail('owner@example.com')!;
  final api = FakeAppsApi(
    accountId: owner.id,
    accountName: 'Owner User',
    role: AccountRole.owner,
    clock: () => DateTime.utc(2026, 10, 19, 8),
  );
  final view = me.id == owner.id ? api : api.asAccount(me.id, name: me.name, role: me.role);
  return (api: view, auth: auth, accounts: accounts);
}

/// The app as `main` builds it, signed in to [w], in the window set up before.
Future<void> pumpApp(WidgetTester t, Workspace w, {AppTheme? theme}) async {
  final settings = await AppSettings.load();
  await t.pumpWidget(
    buildApp(
      settings,
      auth: w.auth,
      backendFor: (_) => FakeAppsBackend(w.api),
      appsApiFor: (_) => w.api,
      studioPollInterval: null,
      theme: theme,
    ),
  );
  await settle(t);
}

/// Scrolls [finder] into view (the chip row scrolls sideways) and taps it.
Future<void> tapVisible(WidgetTester t, Finder finder) async {
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  await settle(t);
}

/// Unmounts the app and lets its timers run out.
Future<void> unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 20));
}

/// Android back (the system navigation's back); returns whether the app handled it (false: the system leaves the app).
Future<bool> systemBack(WidgetTester t) async {
  final handled = await t.binding.handlePopRoute();
  await settle(t, 800);
  return handled;
}

/// Records `SystemNavigator.pop` (the app asking the system to leave it).
List<String> recordSystemPops(WidgetTester t) {
  final calls = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.pop') calls.add(call.method);
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

/// [finder]'s rectangle lies inside the window's safe area ([insets] off [size]).
Matcher insideSafeArea(Size size, EdgeInsets insets) => _InsideSafe(insets.deflateRect(Offset.zero & size));

class _InsideSafe extends Matcher {
  _InsideSafe(this.safe);
  final Rect safe;

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    final r = item as Rect;
    return r.left >= safe.left - .01 &&
        r.top >= safe.top - .01 &&
        r.right <= safe.right + .01 &&
        r.bottom <= safe.bottom + .01;
  }

  @override
  Description describe(Description d) => d.add('inside the safe area $safe');
}
