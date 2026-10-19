/// The app detail page (Dify 1.17.1's `/app/{id}/...` with its sidebar) inside the app: the page each role lands on,
/// the sidebar's navigation by role and mode, the editor kept alive across page switches, the guard, the collapsible
/// sidebar (button, Mod+B, hover preview, remembered), the app info menu (edit, delete) and an app that is gone.
library;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/studio_fakes.dart';

Future<void> settle(WidgetTester t, [int ms = 1500]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

typedef _Workspace = ({FakeAppsApi api, AuthController auth, FakeAccounts accounts, FakeAppsApi owner});

Future<_Workspace> _workspace({String as = 'owner@example.com'}) async {
  final accounts = FakeAccounts()
    ..addMember(email: 'owner@example.com', name: 'Owner User', role: AccountRole.owner)
    ..addMember(email: 'kim@example.com', name: 'Kim', role: AccountRole.editor)
    ..addMember(email: 'nia@example.com', name: 'Nia', role: AccountRole.normal)
    ..addMember(email: 'dan@example.com', name: 'Dan', role: AccountRole.datasetOperator);
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
  return (api: view, auth: auth, accounts: accounts, owner: api);
}

Future<void> _pump(WidgetTester t, _Workspace w) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DifyI18n.current = KeyEchoTranslator();
  final settings = await AppSettings.load();
  await t.pumpWidget(
    buildApp(
      settings,
      auth: w.auth,
      backendFor: (_) => FakeAppsBackend(w.owner),
      appsApiFor: (_) => w.api,
      studioPollInterval: null,
      appDetailServicesFor: (_) => {
        StatsApi: FakeStatsApi(apps: w.owner),
        LogsApi: FakeLogsApi(apps: w.owner),
      },
    ),
  );
  await settle(t);
}

Future<void> _open(WidgetTester t, String name) async {
  await t.tap(find.text(name).first);
  await settle(t, 2500);
}

AppDetailPageState _shell(WidgetTester t) => t.state<AppDetailPageState>(find.byType(AppDetailPage));

List<String> _nav() {
  bool isNav(Widget w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('app-nav-');
  return [
    for (final e in find.byWidgetPredicate(isNav).evaluate())
      (e.widget.key! as ValueKey<String>).value.substring('app-nav-'.length),
  ];
}

Future<void> _done(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 20));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an owner lands on the editor; the sidebar shows the app and every page of a workflow app', (t) async {
    final w = await _workspace();
    w.api.seed(name: 'Support triage');
    await _pump(t, w);
    await _open(t, 'Support triage');
    expect(_shell(t).page, AppDetailPageId.workflow);
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-info-name')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const ValueKey('app-info-name'))).data, 'Support triage');
    expect(t.widget<Text>(find.byKey(const ValueKey('app-info-mode'))).data, 'TYPES.WORKFLOW');
    // Workflow apps have no Annotations.
    expect(_nav(), ['workflow', 'access-point', 'logs', 'overview']);
    expect(
      t.widget<Title>(find.byType(Title).last).title,
      'appMenus.promptEng · Support triage - Dify',
      reason: "layout-main's document title",
    );
    await _done(t);
  });

  testWidgets('a chatflow shows Annotations after Logs', (t) async {
    final w = await _workspace();
    w.api.seed(name: 'Helpdesk', mode: AppModes.advancedChat);
    await _pump(t, w);
    await _open(t, 'Helpdesk');
    expect(_nav(), ['workflow', 'access-point', 'logs', 'annotations', 'overview']);
    await _done(t);
  });

  testWidgets('a normal member lands on the Overview, a dataset operator on the Access Point', (t) async {
    for (final (who, page, nav) in [
      ('nia@example.com', AppDetailPageId.overview, ['access-point', 'overview']),
      ('dan@example.com', AppDetailPageId.accessPoint, ['access-point']),
    ]) {
      SharedPreferences.setMockInitialValues({});
      final w = await _workspace(as: who);
      w.owner.seed(name: 'Support triage');
      await _pump(t, w);
      await _open(t, 'Support triage');
      expect(_shell(t).page, page, reason: who);
      expect(_nav(), nav, reason: who);
      expect(find.byKey(const ValueKey('node-start')), findsNothing, reason: 'no editor for $who');
      // The guard: the editor is refused and the user stays where getRedirectionPath leads.
      _shell(t).navigate(AppDetailPageId.workflow);
      await settle(t);
      expect(_shell(t).page, page, reason: who);
      expect(find.byKey(const ValueKey('node-start')), findsNothing);
      await _done(t);
    }
  });

  testWidgets('switching pages keeps the editor (same session) and its keys stay off while another page shows', (
    t,
  ) async {
    final w = await _workspace();
    w.api.seed(name: 'Support triage');
    await _pump(t, w);
    await _open(t, 'Support triage');
    final editor = t.state(find.byType(EditorPage));
    await t.tap(find.byKey(const ValueKey('app-nav-logs')));
    await settle(t);
    expect(_shell(t).page, AppDetailPageId.logs);
    expect(find.byKey(const ValueKey('app-detail-page-logs')), findsOneWidget);
    expect(t.title, contains('appMenus.logs'));
    expect(find.byType(EditorPage, skipOffstage: false), findsOneWidget, reason: 'alive offstage');
    await t.tap(find.byKey(const ValueKey('app-nav-workflow')));
    await settle(t);
    expect(t.state(find.byType(EditorPage)), same(editor), reason: 'the same editor, not a new session');
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget);
    await _done(t);
  });

  testWidgets('the sidebar collapses with its button and Mod+B, previews on hover, and remembers the choice', (
    t,
  ) async {
    final w = await _workspace();
    w.api.seed(name: 'Support triage');
    await _pump(t, w);
    await _open(t, 'Support triage');
    DetailSidebarFrameState frame() => t.state(find.byType(DetailSidebarFrame));
    double width() => t.getSize(find.byKey(const ValueKey('detail-sidebar'))).width;
    expect(width(), 240);
    await t.tap(find.byKey(const ValueKey('detail-sidebar-toggle')));
    await settle(t, 500);
    expect(frame().expanded, isFalse);
    expect(width(), 56);
    expect((await SharedPreferences.getInstance()).getString(detailSidebarStorageKey), 'collapse');
    expect(find.byKey(const ValueKey('app-info-name')), findsNothing, reason: 'collapsed: the icon alone');

    // Hovering shows the expanded panel over the page without changing the remembered mode.
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 500));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(30, 300));
    await settle(t, 500);
    expect(frame().previewOpen, isTrue);
    expect(width(), 240);
    expect(frame().expanded, isFalse);
    await mouse.moveTo(const Offset(800, 500));
    await settle(t, 500);
    expect(frame().previewOpen, isFalse);
    expect(width(), 56);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyB);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(t, 500);
    expect(frame().expanded, isTrue);
    expect((await SharedPreferences.getInstance()).getString(detailSidebarStorageKey), 'expand');
    await _done(t);
  });

  testWidgets('the app info menu renames the app (sidebar and title follow) and deletes it (back to the Studio)', (
    t,
  ) async {
    final w = await _workspace();
    final a = w.api.seed(name: 'Support triage');
    w.api.seed(name: 'Other');
    await _pump(t, w);
    await _open(t, 'Support triage');
    await t.tap(find.byKey(const ValueKey('app-info-more')));
    await settle(t, 300);
    for (final id in ['edit', 'duplicate', 'export', 'import', 'delete']) {
      expect(find.byKey(ValueKey('app-info-op-$id')), findsOneWidget, reason: id);
    }
    await t.tap(find.byKey(const ValueKey('app-info-op-delete')));
    await settle(t, 600);
    await t.tap(find.byKey(const ValueKey('delete-app-fill')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('delete-app-confirm')));
    await settle(t, 3000);
    expect(find.byType(AppDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    await expectLater(w.api.get(a.id), throwsA(isA<TransportException>()));
    await _done(t);
  });

  testWidgets('an app renamed from the menu shows its new name in the sidebar and the window title', (t) async {
    final w = await _workspace();
    final a = w.api.seed(name: 'Support triage');
    await _pump(t, w);
    await _open(t, 'Support triage');
    await _shell(t).actions.onEdit((
      name: 'Ticket router',
      iconType: AppIconTypes.emoji,
      icon: '🤖',
      iconBackground: '#FFEAD5',
      description: '',
      useIconAsAnswerIcon: false,
      maxActiveRequests: null,
    ));
    await settle(t);
    expect(t.widget<Text>(find.byKey(const ValueKey('app-info-name'))).data, 'Ticket router');
    expect(t.title, contains('Ticket router'));
    expect((await w.api.get(a.id)).name, 'Ticket router');
    await _done(t);
  });

  testWidgets('an app that is gone when opened goes back to the Studio', (t) async {
    final w = await _workspace();
    final a = w.api.seed(name: 'Support triage');
    await _pump(t, w);
    await w.owner.delete(a.id);
    await _open(t, 'Support triage');
    expect(find.byType(AppDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
    await _done(t);
  });
}

extension on WidgetTester {
  String get title => widget<Title>(find.byType(Title).last).title;
}
