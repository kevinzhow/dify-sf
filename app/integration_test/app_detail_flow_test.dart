// The app detail pages end to end on a desktop (the real canvas renderer): the Studio opens an app at the page its
// role leads to (owner: the editor; normal member: Monitoring; dataset operator: Access Point), the sidebar switches
// pages while the editor keeps its session, the Logs show the mock runs, and the sidebar's Studio link goes back.
//   xvfb-run -a -s "-screen 0 1600x1000x24" flutter test integration_test/app_detail_flow_test.dart -d linux
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/studio_fakes.dart';

Future<void> settle(WidgetTester t, [int ms = 2000]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _start(WidgetTester t, String email, FakeAppsApi owner, FakeAccounts accounts) async {
  final auth = AuthController.on(server: 'http://test', api: FakeAuthApi(accounts), store: MemoryTokenStore());
  await auth.signIn(email: email, password: 'password-1');
  final me = auth.account!;
  final api = me.role == AccountRole.owner ? owner : owner.asAccount(me.id, name: me.name, role: me.role);
  DifyI18n.current = KeyEchoTranslator();
  await t.pumpWidget(
    buildApp(
      await AppSettings.load(),
      auth: auth,
      backendFor: (_) => FakeAppsBackend(owner),
      appsApiFor: (_) => api,
      studioPollInterval: null,
      appDetailServicesFor: (_) => {
        StatsApi: FakeStatsApi(apps: owner, mock: true),
        LogsApi: FakeLogsApi(apps: owner, mock: true),
        AccessApi: FakeAccessApi(owner),
        AnnotationsApi: FakeAnnotationsApi(owner),
        VersionsApi: FakeVersionsApi(owner),
      },
    ),
  );
  await settle(t);
}

AppDetailPageState _shell(WidgetTester t) => t.state(find.byType(AppDetailPage));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Studio -> app (editor) -> Logs -> editor again (same session) -> Studio, and each role lands right', (
    t,
  ) async {
    final accounts = FakeAccounts()
      ..addMember(email: 'owner@example.com', name: 'Owner User', role: AccountRole.owner)
      ..addMember(email: 'nia@example.com', name: 'Nia', role: AccountRole.normal)
      ..addMember(email: 'dan@example.com', name: 'Dan', role: AccountRole.datasetOperator);
    final owner = FakeAppsApi(
      accountId: accounts.byEmail('owner@example.com')!.id,
      accountName: 'Owner User',
      role: AccountRole.owner,
    );
    owner.seed(name: 'Support triage');

    await _start(t, 'owner@example.com', owner, accounts);
    await t.tap(find.text('Support triage'));
    await settle(t, 3000);
    expect(_shell(t).page, AppDetailPageId.workflow);
    final canvas = find.byType(WorkflowCanvas);
    for (
      var i = 0;
      i < 200 && (canvas.evaluate().isEmpty || t.state<WorkflowCanvasState>(canvas).graph.length == 0);
      i++
    ) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(
      t.state<WorkflowCanvasState>(canvas).graph.length,
      greaterThan(0),
      reason: "the app's document on the canvas",
    );
    final editor = t.state(find.byType(EditorPage));

    await t.tap(find.byKey(const ValueKey('app-nav-logs')));
    await settle(t);
    expect(_shell(t).page, AppDetailPageId.logs);
    expect(
      find.byWidgetPredicate((w) => '${w.key}'.contains('workflow-log-row-')),
      findsWidgets,
      reason: "the mock runs in the workflow log",
    );

    await t.tap(find.byKey(const ValueKey('app-nav-overview')));
    await settle(t);
    expect(_shell(t).page, AppDetailPageId.overview);

    await t.tap(find.byKey(const ValueKey('app-nav-workflow')));
    await settle(t);
    expect(t.state(find.byType(EditorPage)), same(editor), reason: 'the editor kept its session');

    await t.tap(find.byKey(const ValueKey('app-detail-studio')));
    await settle(t);
    expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
    expect(find.byType(AppDetailPage), findsNothing);

    for (final (email, page) in [
      ('nia@example.com', AppDetailPageId.overview),
      ('dan@example.com', AppDetailPageId.accessPoint),
    ]) {
      await t.pumpWidget(const SizedBox());
      await settle(t, 500);
      await _start(t, email, owner, accounts);
      await t.tap(find.text('Support triage'));
      await settle(t, 3000);
      expect(_shell(t).page, page, reason: email);
      expect(find.byType(WorkflowCanvas, skipOffstage: false), findsNothing, reason: '$email has no editor');
      expect(find.byKey(const ValueKey('app-nav-workflow')), findsNothing);
    }
    await t.pumpWidget(const SizedBox());
    await settle(t, 1000);
  });
}
