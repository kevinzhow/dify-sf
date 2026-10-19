/// The Studio as the app's home (protocol 1.10, FakeAppsApi): listing, opening an app (the app detail page, at the
/// page its role leads to) and coming back,
/// creating from blank, rights by role, stars, search, paging, and an app deleted while it is open.
library;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/studio_fakes.dart';

Future<void> settle(WidgetTester t, [int ms = 1500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A workspace (owner, editor Kim, normal member Nia) signed in as [as]; the apps server's caller is that account.
Future<({FakeAppsApi api, AuthController auth, FakeAccounts accounts})> _workspace({
  String as = 'owner@example.com',
}) async {
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

Future<void> _pump(WidgetTester t, FakeAppsApi api, AuthController auth) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DifyI18n.current = KeyEchoTranslator();
  final settings = await AppSettings.load();
  await t.pumpWidget(
    buildApp(
      settings,
      auth: auth,
      backendFor: (_) => FakeAppsBackend(api),
      appsApiFor: (_) => api,
      studioPollInterval: null,
    ),
  );
  await settle(t);
}

Future<void> _hover(WidgetTester t, Finder f) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(t.getCenter(f));
  await t.pump();
}

/// Back to the Studio from an opened app: the sidebar's "/ Studio" breadcrumb.
Future<void> _leaveEditor(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('app-detail-studio')));
  await settle(t);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the Studio is home: it lists the apps, a card opens the editor, and back is the Studio again', (
    t,
  ) async {
    final w = await _workspace();
    final a = w.api.seed(name: 'Support triage', description: 'Routes tickets', creatorName: 'Owner User');
    w.api.seed(name: 'Release notes', mode: AppModes.advancedChat);
    await _pump(t, w.api, w.auth);
    expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
    expect(find.text('Support triage'), findsOneWidget);
    expect(find.text('Release notes'), findsOneWidget);
    expect(find.text('Routes tickets'), findsOneWidget);
    expect(find.textContaining('Owner User'), findsWidgets, reason: 'the author on the card');

    await t.tap(find.text('Support triage'));
    await settle(t, 2500);
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget, reason: "the app's document in the editor");
    w.api.server(a.id); // still there

    await _leaveEditor(t);
    expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('Create from Blank makes a chatflow and opens it', (t) async {
    final w = await _workspace();
    await _pump(t, w.api, w.auth);
    expect(find.byKey(const ValueKey('studio-first-empty')), findsOneWidget, reason: 'no apps yet');
    await t.tap(find.byKey(const ValueKey('studio-first-empty-blank')));
    await settle(t);
    expect(find.byKey(const ValueKey('create-app-type-advanced-chat')), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('create-app-name')), matching: find.byType(EditableText)),
      'Helpdesk bot',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey('create-app-submit')));
    await settle(t, 3000);
    final created = (await w.api.list()).data.single;
    expect((created.name, created.mode), ('Helpdesk bot', AppModes.advancedChat));
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('node-answer')), findsWidgets, reason: "Dify's chatflow seed");
    await _leaveEditor(t);
    expect(find.text('Helpdesk bot'), findsOneWidget, reason: 'the list was refetched');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('a normal member sees every card and stars, but has no Create and no More menu; cards open the Overview', (
    t,
  ) async {
    final w = await _workspace(as: 'nia@example.com');
    final a = w.api.seed(name: 'Support triage');
    await _pump(t, w.api, w.auth);
    expect(find.byKey(const ValueKey('studio-create')), findsNothing);
    expect(find.byKey(const ValueKey('studio-drop-hint')), findsNothing);
    await _hover(t, find.byKey(ValueKey('app-card-${a.id}')));
    expect(find.byKey(ValueKey('app-card-star-${a.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('app-card-more-${a.id}')), findsNothing);

    await t.tap(find.byKey(ValueKey('app-card-star-${a.id}')));
    await settle(t);
    expect((await w.api.starred()).data.map((x) => x.id), [a.id]);
    expect(find.byKey(ValueKey('starred-${a.id}')), findsOneWidget, reason: 'the starred row');

    await t.tap(find.byKey(ValueKey('app-card-link-${a.id}')).last);
    await settle(t, 2500);
    // Dify's getRedirectionPath: no layout access, so the Overview (`app.acl.monitor`); no Orchestrate in the sidebar.
    expect(find.byKey(const ValueKey('app-detail-page-overview')), findsOneWidget);
    expect(find.byKey(const ValueKey('node-start')), findsNothing);
    expect(find.byKey(const ValueKey('app-nav-workflow')), findsNothing);
    expect(find.byKey(const ValueKey('app-nav-overview')), findsOneWidget);
    await _leaveEditor(t);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('search narrows the list after the debounce; scrolling loads the next page of 30', (t) async {
    final w = await _workspace();
    for (var i = 0; i < 40; i++) {
      w.api.seed(
        name: 'App ${i.toString().padLeft(2, '0')}',
        updatedAt: DateTime.utc(2026, 10, 1).add(Duration(hours: i)),
      );
    }
    await _pump(t, w.api, w.auth);
    expect(w.api.requests['list'], 1);
    expect(find.text('App 39'), findsOneWidget, reason: 'last modified first');
    await t.drag(find.byKey(const ValueKey('studio-catalog')), const Offset(0, -3000));
    await settle(t);
    expect(w.api.requests['list'], 2, reason: 'page 2');
    await t.drag(find.byKey(const ValueKey('studio-catalog')), const Offset(0, -3000));
    await settle(t);
    expect(find.text('App 00'), findsOneWidget);

    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('studio-search')), matching: find.byType(EditableText)),
      'app 1',
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('App 39'), findsOneWidget, reason: 'not yet: the search waits 500 ms');
    await settle(t);
    expect(find.text('App 39'), findsNothing);
    expect(find.text('App 15'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('an app deleted while it is open in an editor: the editor says so and goes back to the Studio', (
    t,
  ) async {
    final w = await _workspace();
    final a = w.api.seed(name: 'Support triage');
    w.api.seed(name: 'Other');
    await _pump(t, w.api, w.auth);
    await t.tap(find.text('Support triage'));
    await settle(t, 2500);
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget);

    await w.api.asAccount(w.accounts.byEmail('kim@example.com')!.id, name: 'Kim').delete(a.id);
    await settle(t, 6000);
    expect(find.byKey(const ValueKey('node-start')), findsNothing);
    expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
    expect(find.text('appDeleted'), findsOneWidget, reason: 'the toast');
    expect(find.text('Support triage'), findsNothing, reason: 'the list was refetched');
    expect(find.text('Other'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 20));
  });
}
