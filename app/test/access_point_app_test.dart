/// The Access Point inside the app: reached from the sidebar of an opened app, and directly with `?app=…&page=…`
/// (the launch option the visual tests use to open Dify and us on the same page), on the in-memory server.
library;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_page.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/studio_fakes.dart';

Future<void> _settle(WidgetTester t, [int ms = 2500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<({FakeAppsApi api, AuthController auth})> _workspace(String email) async {
  final accounts = FakeAccounts()
    ..addMember(email: 'owner@example.com', name: 'Owner User', role: AccountRole.owner)
    ..addMember(email: 'dan@example.com', name: 'Dan', role: AccountRole.datasetOperator);
  final auth = AuthController.on(server: 'http://test', api: FakeAuthApi(accounts), store: MemoryTokenStore());
  await auth.signIn(email: email, password: 'password-1');
  final owner = accounts.byEmail('owner@example.com')!;
  final api = FakeAppsApi(accountId: owner.id, accountName: 'Owner User', clock: () => DateTime.utc(2026, 10, 19, 8));
  final me = auth.account!;
  return (api: me.id == owner.id ? api : api.asAccount(me.id, name: me.name, role: me.role), auth: auth);
}

Future<void> _pump(WidgetTester t, ({FakeAppsApi api, AuthController auth}) w, {LaunchOptions? launch}) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DifyI18n.current = KeyEchoTranslator();
  await t.pumpWidget(
    buildApp(
      await AppSettings.load(),
      auth: w.auth,
      launch: launch,
      backendFor: (_) => FakeAppsBackend(w.api),
      appsApiFor: (_) => w.api,
      studioPollInterval: null,
      appDetailServicesFor: (_) => {AccessApi: FakeAccessApi(w.api), VersionsApi: FakeVersionsApi(w.api)},
    ),
  );
  await _settle(t);
}

Future<void> _done(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 20));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the sidebar opens the Access Point of a chatflow with the app\'s site', (t) async {
    final w = await _workspace('owner@example.com');
    final app = await w.api.create(name: 'Support Bot', mode: AppModes.advancedChat);
    await _pump(t, w);
    await t.tap(find.text('Support Bot').first);
    await _settle(t);
    await t.tap(find.byKey(const ValueKey('app-nav-access-point')));
    await _settle(t);
    expect(find.byType(AccessPointPage), findsOneWidget);
    final site = (await w.api.get(app.id)).site!;
    expect(find.text('${site.appBaseUrl}/chat/${site.accessToken}'), findsOneWidget);
    await _done(t);
  });

  testWidgets('?app=…&page=access-point opens the app at its Access Point (a dataset operator\'s only page)', (
    t,
  ) async {
    final owner = await _workspace('owner@example.com');
    final app = await owner.api.create(name: 'Support Bot', mode: AppModes.workflow);
    final w = await _workspace('dan@example.com');
    // The same workspace seen by the dataset operator.
    final view = owner.api.asAccount(w.auth.account!.id, name: 'Dan', role: AccountRole.datasetOperator);
    await _pump(t, (api: view, auth: w.auth), launch: LaunchOptions(app: app.id, page: 'access-point'));
    expect(find.byType(AccessPointPage), findsOneWidget);
    // Read-only: nothing to manage.
    expect(find.text('deployments.studio.accessPoint.noPublishedTitle'), findsNothing);
    await _done(t);
  });
}
