// An opened app's pages on a phone (the subpages PR): Logs (workflow and chatflow), Annotations, Access Point and
// Monitoring, pushed over the editor, and the workspace's Members. Each is checked at 411x914 and 360x780 (gesture and
// three-button insets): no overflow, the phone layout (rows instead of tables, filters as chips with sheets, the
// detail drawer as a page, the compact pagination), the key actions by touch with 44 dp targets, and the rows'
// accessible names.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/settings/members/member_row.dart';
import 'package:dify_sf_app/src/shell/phone_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

String _c(String key) => DifyI18n.tr('common', key);

/// The app as `main` builds it with every page's API on fakes (mock logs and statistics).
Future<void> _pump(WidgetTester t, Workspace w) async {
  final settings = await AppSettings.load();
  await t.pumpWidget(
    buildApp(
      settings,
      auth: w.auth,
      backendFor: (_) => FakeAppsBackend(w.api),
      appsApiFor: (_) => w.api,
      studioPollInterval: null,
      appDetailServicesFor: (_) => {
        StatsApi: FakeStatsApi(apps: w.api, mock: true),
        LogsApi: FakeLogsApi(apps: w.api, mock: true),
        AccessApi: FakeAccessApi(w.api),
        AnnotationsApi: FakeAnnotationsApi(w.api),
        VersionsApi: FakeVersionsApi(w.api),
      },
    ),
  );
  await settle(t);
}

/// Opens [name] from the Studio and pushes its [page] over the editor.
Future<void> _openPage(WidgetTester t, String name, AppDetailPageId page) async {
  await t.tap(find.text(name).first);
  await settle(t, 2500);
  t.state<AppDetailPageState>(find.byType(AppDetailPage)).navigate(page);
  await settle(t, 1500);
  expect(find.byType(PhonePage), findsOneWidget);
}

Finder _keyed(String prefix) => find.byWidgetPredicate(
  (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix),
);

Finder _pressable(String label) => find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label);

/// [f] is at least 44 dp in each direction (the control or its touch box).
void _touchSized(WidgetTester t, Finder f, String reason) {
  final size = t.getSize(f);
  expect(size.height, greaterThanOrEqualTo(44), reason: '$reason: height');
  expect(size.width, greaterThanOrEqualTo(44), reason: '$reason: width');
}

/// The drawer shown as a page fills the window.
void _isPage(WidgetTester t, Size window) {
  expect(t.getRect(find.byType(DifyDrawerPopup)), Offset.zero & window);
  expect(find.byType(DifyDrawerPage), findsOneWidget);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final win in phoneWindows) {
    final width = win.size.width;

    testWidgets('${win.name}: workflow logs are rows with chip filters; the detail is a page; compact pages', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      phoneWindow(t, size: win.size, insets: win.insets);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await _pump(t, ws);
      await _openPage(t, 'Support triage', AppDetailPageId.logs);
      expect(t.takeException(), isNull);

      // Rows across the page instead of the table, each named by its start time, status and figures.
      expect(find.byType(DifyTable), findsNothing);
      final rows = _keyed('workflow-log-row-');
      expect(rows, findsNWidgets(appPageLimit));
      final firstRect = t.getRect(rows.first);
      expect(firstRect.width, closeTo(width, .5));
      expect(firstRect.height, greaterThanOrEqualTo(DifyListRow.minHeightWithSubtitle));
      final row = t.widget<LogPhoneRow>(rows.first);
      expect(row.status, 'Success');
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(row.title)}, Success, .*tokens')), findsOneWidget);

      // The search spans the page; the filters are chips (touch-high) that open action sheets.
      expect(t.getSize(find.byKey(const ValueKey('workflow-log-keyword'))).width, closeTo(width - 32, .5));
      final status = find.descendant(
        of: find.byKey(const ValueKey('workflow-log-status')),
        matching: find.byType(DifyFilterChip),
      );
      expect(t.getSize(status).height, greaterThanOrEqualTo(DifyFilterChip.height));
      // On the phone page the chip is a 44 dp touch box (also its accessible bounds).
      _touchSized(t, find.descendant(of: status, matching: find.byType(DifyTouchArea)).first, 'status chip');
      await t.tap(status);
      await settle(t, 800);
      await t.tap(find.text('Fail').last);
      await settle(t, 1500);
      expect(t.takeException(), isNull);
      expect(rows, findsWidgets);
      for (final e in rows.evaluate()) {
        expect((e.widget as LogPhoneRow).status, 'Failure');
      }
      await t.tap(
        find.descendant(of: find.byKey(const ValueKey('workflow-log-status')), matching: find.byType(DifyFilterChip)),
      );
      await settle(t, 800);
      await t.tap(find.text('All').last);
      await settle(t, 1500);
      expect(rows, findsNWidgets(appPageLimit));

      // Sorting by the start time is the list's header row (44 px).
      expect(t.getSize(find.byKey(const ValueKey('workflow-log-sort'))).height, greaterThanOrEqualTo(44));

      // The compact pagination: 44 px previous / next, the page size; no page buttons.
      final next = _pressable(_c('pagination.next'));
      _touchSized(t, next, 'next page');
      expect(find.bySemanticsLabel('Go to page 2'), findsNothing);
      await t.ensureVisible(next);
      await t.tap(next);
      await settle(t, 1500);
      expect(rows, findsNWidgets(2), reason: '12 runs: the second page');

      // A row opens the run's detail as a page over the window; back closes it, then leaves the page.
      await t.tap(rows.first);
      await settle(t, 1500);
      _isPage(t, win.size);
      expect(find.byKey(const ValueKey('log-drawer')), findsOneWidget);
      // Its icon controls (the close, Test With Params) are in 44 px touch boxes, the close's glyph inside the window.
      for (final key in const ['workflow-log-detail-close', 'workflow-log-replay']) {
        final control = find.byKey(ValueKey(key));
        if (key == 'workflow-log-replay' && control.evaluate().isEmpty) continue;
        _touchSized(t, find.ancestor(of: control, matching: find.byType(DifyTouchArea)).first, key);
        final r = t.getRect(control);
        expect(r.right <= width && r.top >= win.insets.top, isTrue, reason: '$key: $r');
      }
      expect(await systemBack(t), isTrue);
      expect(find.byType(DifyDrawerPopup), findsNothing);
      expect(find.byType(PhonePage), findsOneWidget);
      expect(t.takeException(), isNull);
      semantics.dispose();
      await unmount(t);
    });

    testWidgets('${win.name}: chatflow logs: rows, sort chips, the conversation as a page', (t) async {
      phoneWindow(t, size: win.size, insets: win.insets);
      final ws = await workspace();
      ws.api.seed(name: 'Help desk bot', mode: AppModes.advancedChat);
      await _pump(t, ws);
      await _openPage(t, 'Help desk bot', AppDetailPageId.logs);
      expect(t.takeException(), isNull);
      expect(find.byType(DifyTable), findsNothing);
      final rows = _keyed('chat-log-row-');
      expect(rows, findsWidgets);
      expect(t.getRect(rows.first).width, closeTo(width, .5));
      expect(t.widget<LogPhoneRow>(rows.first).status, isNotNull, reason: 'a chatflow row shows its status');

      // Sort by: an action sheet; the order: a chip that flips it.
      await tapVisible(t, find.byKey(const ValueKey('log-sort-phone')));
      expect(find.text(DifyI18n.tr('appLog', 'table.header.updatedTime')), findsWidgets);
      await t.tap(find.text(DifyI18n.tr('appLog', 'table.header.updatedTime')).last);
      await settle(t, 1500);
      expect(
        t.widget<DifyFilterChip>(find.byKey(const ValueKey('log-sort-phone'))).label,
        contains(DifyI18n.tr('appLog', 'table.header.updatedTime')),
      );
      final order = find.byKey(const ValueKey('log-sort-order-phone'));
      final before = t.widget<DifyFilterChip>(order).label;
      await tapVisible(t, order);
      expect(t.widget<DifyFilterChip>(order).label, isNot(before));
      expect(t.takeException(), isNull);

      await t.tap(rows.first);
      await settle(t, 1500);
      _isPage(t, win.size);
      expect(find.byKey(const ValueKey('conversation-detail')), findsOneWidget);
      _touchSized(t, find.byKey(const ValueKey('conversation-detail-close')), 'close');
      await t.tap(find.byKey(const ValueKey('conversation-detail-close')));
      await settle(t, 1000);
      expect(find.byType(DifyDrawerPopup), findsNothing);
      expect(find.byType(PhonePage), findsOneWidget);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('${win.name}: annotations are rows with Edit / Remove; the annotation opens as a page', (t) async {
      phoneWindow(t, size: win.size, insets: win.insets);
      final ws = await workspace();
      final app = ws.api.seed(name: 'Help desk bot', mode: AppModes.advancedChat);
      final annotations = FakeAnnotationsApi(ws.api);
      for (var i = 0; i < 3; i++) {
        await annotations.create(app.id, question: 'How do I reset my password ($i)?', answer: 'Open Settings.');
      }
      await _pump(t, ws);
      await _openPage(t, 'Help desk bot', AppDetailPageId.annotations);
      expect(t.takeException(), isNull);
      expect(find.byType(DifyTable), findsNothing);
      final rows = _keyed('annotation-row-');
      expect(rows, findsNWidgets(3));
      expect(t.getRect(rows.first).width, closeTo(width, .5));
      expect(t.getSize(rows.first).height, greaterThanOrEqualTo(DifyActionRow.minHeight));

      // Add and More stay inside the page (they wrap under the reply switch on a narrow phone).
      final add = find.text(DifyI18n.tr('appAnnotation', 'table.header.addAnnotation'));
      expect(t.getRect(add).right, lessThanOrEqualTo(width - 16));
      expect(t.getRect(find.byKey(const ValueKey('annotation-more'))).right, lessThanOrEqualTo(width - 16 + .5));

      // "…" (44 px) offers Edit and Remove; Remove asks first, and back closes that question only.
      final more = find.byKey(const ValueKey('dify-action-row-more-How do I reset my password (2)?'));
      _touchSized(t, more, 'row more');
      await t.tap(more);
      await settle(t, 800);
      final edit = DifyI18n.tr('appDebug', 'feature.annotation.edit');
      final remove = DifyI18n.tr('appDebug', 'feature.annotation.remove');
      expect(find.text(edit), findsWidgets);
      await t.tap(find.text(remove).last);
      await settle(t, 800);
      expect(find.byKey(const ValueKey('annotation-alert-dialog')), findsOneWidget);
      expect(await systemBack(t), isTrue);
      expect(find.byKey(const ValueKey('annotation-alert-dialog')), findsNothing);
      expect(find.byType(PhonePage), findsOneWidget, reason: 'back closed the question, not the page');
      expect(rows, findsNWidgets(3));

      // A row opens the annotation as a page; back closes it and keeps the page.
      await t.tap(rows.first);
      await settle(t, 1000);
      expect(t.getRect(find.byKey(const ValueKey('annotation-drawer'))), Offset.zero & win.size);
      final close = find.descendant(
        of: find.byKey(const ValueKey('annotation-drawer')),
        matching: find.byWidgetPredicate((w) => w is DifyIconButton && w.label == _c('operation.close')),
      );
      expect(t.getRect(close).top, greaterThanOrEqualTo(win.insets.top), reason: 'the content stays safe');
      _touchSized(t, close, 'close');
      expect(await systemBack(t), isTrue);
      expect(find.byKey(const ValueKey('annotation-drawer')), findsNothing);
      expect(find.byType(PhonePage), findsOneWidget);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('${win.name}: access point cards fit; the header scrolls away; actions are touch-sized', (t) async {
      phoneWindow(t, size: win.size, insets: win.insets);
      final ws = await workspace();
      final app = ws.api.seed(name: 'Support triage');
      await FakeVersionsApi(ws.api).publish(app.id);
      await _pump(t, ws);
      await _openPage(t, 'Support triage', AppDetailPageId.accessPoint);
      expect(t.takeException(), isNull);
      final cards = find.byType(AccessPointCard);
      expect(cards, findsWidgets);
      for (final e in cards.evaluate()) {
        final r = t.getRect(find.byWidget(e.widget));
        expect(r.left, greaterThanOrEqualTo(16 - .5));
        expect(r.right, lessThanOrEqualTo(width - 16 + .5));
      }
      // The endpoint's actions have their own row under the value, each 44 px.
      final copy = find.descendant(of: find.byType(DifyCopyFeedback).first, matching: find.byType(DifyIconButton));
      _touchSized(t, copy, 'copy');
      _touchSized(t, find.byKey(const ValueKey('qrcode-trigger')), 'QR code');
      expect(t.getSize(find.byKey(const ValueKey('web-app-settings'))).height, greaterThanOrEqualTo(44));

      // One scroll: the page's title moves with the cards.
      final title = find.text(_c('appMenus.accessPoint')).last;
      final top = t.getRect(title).top;
      await t.drag(cards.first, const Offset(0, -300));
      await settle(t, 800);
      expect(t.getRect(title).top, lessThan(top));
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('${win.name}: monitoring scrolls as one page; the period picker is a touch-high sheet', (t) async {
      phoneWindow(t, size: win.size, insets: win.insets);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await _pump(t, ws);
      await _openPage(t, 'Support triage', AppDetailPageId.overview);
      expect(t.takeException(), isNull);
      final period = find.byKey(const ValueKey('overview-period'));
      expect(t.getSize(period).height, greaterThanOrEqualTo(44));
      final panel = find.byKey(const ValueKey('apikey-info-panel'));
      if (panel.evaluate().isNotEmpty) {
        // The panel's box (its Container's margin keeps it 16 px from the edges).
        final r = t.getRect(find.descendant(of: panel, matching: find.byType(DecoratedBox)).first);
        expect(r.left, closeTo(16, .5));
        expect(r.right, closeTo(width - 16, .5));
      }
      final top = t.getRect(period).top;
      await t.drag(period, const Offset(0, -300));
      await settle(t, 800);
      expect(t.getRect(period).top, lessThan(top), reason: 'the header scrolls with the charts');
      await tapVisible(t, period);
      await t.tap(find.text(DifyI18n.tr('appLog', 'filter.period.last4weeks')).last);
      await settle(t, 1500);
      expect(find.text(DifyI18n.tr('appLog', 'filter.period.last4weeks')), findsWidgets);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('${win.name}: members are rows; a manager\'s member menu is touch-sized', (t) async {
      phoneWindow(t, size: win.size, insets: win.insets);
      final ws = await workspace();
      await _pump(t, ws);
      await t.tap(find.text(_c('account.account')).last);
      await settle(t);
      await t.tap(find.byKey(const ValueKey('account-tab-members')));
      await settle(t);
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('members-table-scroll')), findsNothing);
      final rows = find.byType(MemberRow);
      expect(rows, findsNWidgets(3));
      for (final e in rows.evaluate()) {
        final r = t.getRect(find.byWidget(e.widget));
        expect(r.height, greaterThanOrEqualTo(DifyListRow.minHeightWithSubtitle));
        expect(r.right, lessThanOrEqualTo(width - 16 + .5));
      }
      final kim = ws.accounts.byEmail('kim@example.com')!;
      final menu = find.byKey(ValueKey('member-actions-${kim.id}'));
      _touchSized(t, menu, 'member actions');
      await t.tap(menu);
      await settle(t, 800);
      expect(find.byKey(const ValueKey('member-edit-role')), findsOneWidget);
      expect(await systemBack(t), isTrue);
      expect(find.byKey(const ValueKey('member-edit-role')), findsNothing);
      // The whole row opens the member's details.
      expect(find.bySemanticsLabel(RegExp('Kim')), findsWidgets);
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }

  for (final width in [320.0, 360.0, 411.0]) {
    testWidgets('the compact pagination fits $width dp with 44 dp controls', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 400);
      addTearDown(t.view.reset);
      var page = 3;
      int? size;
      await t.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.bottomCenter,
              child: DifyPagination(
                page: page,
                totalPages: 40,
                pageSize: 10,
                onPageChange: (p) => setState(() => page = p),
                onPageSizeChange: (v) => size = v,
              ),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      for (final label in [_c('pagination.previous'), _c('pagination.next')]) {
        _touchSized(t, _pressable(label), label);
      }
      expect(find.text('3'), findsOneWidget, reason: 'the summary; no page buttons');
      expect(find.text('40'), findsOneWidget);
      await t.tap(_pressable(_c('pagination.next')));
      await t.pump();
      expect(page, 4);
      await t.tap(find.text('25'));
      await t.pump();
      expect(size, 25);
    });
  }
}
