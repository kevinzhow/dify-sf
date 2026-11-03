// The phone PRs' forms are a question of width, not of input (stacking the phone fixes, the sub-pages and the tablet
// PRs): with touch, a phone (411x914) gets the phone forms and a tablet (800x1280, 1280x800) or a landscape phone
// (914x411) keeps the desktop structure with touch sizes, although DifyTouch.compactOf is true for all of them.
// - A dialog is a sheet on the phone and the centred dialog in landscape and on a tablet, re-presented on rotation
//   with the typed text kept.
// - An annotation drawer is a page on the phone and Dify's inset drawer on a tablet; a rotation keeps the typed text
//   and the focus.
// - On a touch tablet Logs and Annotations keep their tables (no phone rows); the log detail and the annotation drawer
//   are inset drawers, not pages, and Back closes them before the page.
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/version_info_modal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';

const _phone = Size(411, 914);
const _landscape = Size(914, 411);
const _tabletPortrait = Size(800, 1280);
const _tabletLandscape = Size(1280, 800);
const _tabletInsets = EdgeInsets.only(top: 24, bottom: 20);

Future<GlobalKey<NavigatorState>> _bare(WidgetTester t, Size size, {Widget body = const SizedBox.expand()}) async {
  phoneWindow(t, size: size);
  DifyInteraction.debugDefault = DifyInteractionMode.touch;
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: nav,
      home: DifyPage(edgeToEdge: true, body: body),
    ),
  );
  await settle(t, 300);
  return nav;
}

/// The app as `main` builds it with the app pages' APIs on fakes (mock logs).
Future<void> _pumpApp(WidgetTester t, Workspace w) async {
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

/// Opens [name] from the Studio and shows its [page].
Future<void> _openPage(WidgetTester t, String name, AppDetailPageId page) async {
  await t.tap(find.text(name).first);
  await settle(t, 2500);
  t.state<AppDetailPageState>(find.byType(AppDetailPage, skipOffstage: false)).navigate(page);
  await settle(t, 1500);
}

Finder _keyed(String prefix) => find.byWidgetPredicate(
  (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix),
);

/// A drawer in its page form (a phone's).
final _drawerPage = find.byWidgetPredicate((w) => w is DifyDrawerPage && w.page);

String _a(String key) => DifyI18n.tr('app-annotation', key);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('touch: a dialog is a sheet on the phone, the centred dialog in landscape and on a tablet, and keeps '
      'the typed text across the rotations', (t) async {
    final nav = await _bare(t, _phone);
    expect(DifyTouch.compactOf(nav.currentContext!), isTrue);
    unawaited(showVersionInfoModal(nav.currentContext!, onPublish: (_) {}));
    await settle(t, 600);
    final fields = find.byType(EditableText);
    DifyDialogForm? form() => DifyDialogFrame.maybeOf(t.element(fields.first));
    expect(form(), DifyDialogForm.sheet);
    await t.enterText(fields.at(0), 'v1');
    await settle(t, 200);
    for (final (size, expected) in [
      (_landscape, DifyDialogForm.dialog),
      (_tabletPortrait, DifyDialogForm.dialog),
      (_tabletLandscape, DifyDialogForm.dialog),
      (_phone, DifyDialogForm.sheet),
    ]) {
      t.view.physicalSize = size;
      await settle(t, 600);
      expect(DifyTouch.compactOf(nav.currentContext!), isTrue, reason: '$size: touch sizes everywhere');
      expect(form(), expected, reason: '$size');
      expect(find.byType(DifySheetHeader), expected == DifyDialogForm.sheet ? findsOneWidget : findsNothing);
      expect(t.widget<EditableText>(fields.at(0)).controller.text, 'v1', reason: '$size: the title');
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('touch: Add Annotation Reply is a page on the phone and the inset drawer on a tablet; a rotation keeps '
      'the text and the focus', (t) async {
    var hidden = 0;
    await _bare(
      t,
      _phone,
      body: StatefulBuilder(
        builder: (context, s) => AddAnnotationModal(
          isShow: hidden == 0,
          onHide: () => s(() => hidden++),
          onAdd: (_) async {},
        ),
      ),
    );
    final drawer = find.byKey(const ValueKey('annotation-drawer'));
    expect(t.getRect(drawer), Offset.zero & _phone);
    expect(find.text(_a('addModal.title')), findsOneWidget);
    final field = find.byType(EditableText).first;
    await t.tap(field);
    t.testTextInput.enterText('Draft question');
    await settle(t, 300);
    final node = t.widget<EditableText>(field).focusNode;
    for (final size in [_tabletPortrait, _landscape, _phone]) {
      t.view.physicalSize = size;
      await settle(t, 600);
      final page = size == _phone;
      expect(_drawerPage, page ? findsOneWidget : findsNothing, reason: '$size');
      if (!page) {
        // Dify's drawer: inset from the right edge, 480 wide.
        final r = t.getRect(drawer);
        expect(r.width, 480, reason: '$size: $r');
        expect(r.right, size.width - 8, reason: '$size: $r');
      }
      expect(t.widget<EditableText>(field).controller.text, 'Draft question', reason: '$size');
      expect(t.widget<EditableText>(field).focusNode, same(node));
      expect(node.hasFocus, isTrue, reason: '$size: the field keeps the focus');
    }
    expect(t.takeException(), isNull);
  });

  for (final size in [_tabletPortrait, _tabletLandscape]) {
    final at = '${size.width.toInt()}x${size.height.toInt()} touch';

    testWidgets('$at: Logs keep the table; a run opens as the inset drawer, not a page; Back closes it first', (
      t,
    ) async {
      phoneWindow(t, size: size, insets: _tabletInsets);
      DifyInteraction.debugDefault = DifyInteractionMode.touch;
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await _pumpApp(t, ws);
      await _openPage(t, 'Support triage', AppDetailPageId.logs);
      expect(t.takeException(), isNull);
      expect(find.byType(DifyTable), findsOneWidget);
      expect(find.byType(LogPhoneRow), findsNothing);
      expect(find.byType(DifyFilterChip), findsNothing, reason: "the desktop's filters");
      final rows = _keyed('workflow-log-row-');
      expect(rows, findsWidgets);
      await t.tap(rows.first);
      await settle(t, 1500);
      expect(find.byKey(const ValueKey('log-drawer')), findsOneWidget);
      expect(_drawerPage, findsNothing);
      expect(t.getRect(find.byType(DifyDrawerPopup)).width, lessThan(size.width));
      expect(await systemBack(t), isTrue);
      expect(find.byType(DifyDrawerPopup), findsNothing);
      final detail = t.state<AppDetailPageState>(find.byType(AppDetailPage, skipOffstage: false));
      expect(detail.page, AppDetailPageId.logs, reason: 'Back closed the drawer, not the page');
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at: Annotations keep the table; Add opens the inset drawer, not a page; Back closes it first', (
      t,
    ) async {
      phoneWindow(t, size: size, insets: _tabletInsets);
      DifyInteraction.debugDefault = DifyInteractionMode.touch;
      final ws = await workspace();
      final app = ws.api.seed(name: 'Help desk bot', mode: AppModes.advancedChat);
      final annotations = FakeAnnotationsApi(ws.api);
      for (var i = 0; i < 3; i++) {
        await annotations.create(app.id, question: 'How do I reset my password ($i)?', answer: 'Open Settings.');
      }
      await _pumpApp(t, ws);
      await _openPage(t, 'Help desk bot', AppDetailPageId.annotations);
      expect(t.takeException(), isNull);
      expect(find.byType(DifyTable), findsOneWidget);
      expect(find.byType(DifyActionRow), findsNothing, reason: "the phone's rows");
      // The reply switch's pill is touch-high (touch sizes), in the desktop header.
      final pill = find.ancestor(of: find.byType(DifySwitch), matching: find.byType(Container)).first;
      expect(t.getSize(pill).height, DifyTouch.controlHeight);
      await t.tap(find.text(DifyI18n.tr('appAnnotation', 'table.header.addAnnotation')));
      await settle(t, 1000);
      final drawer = find.byKey(const ValueKey('annotation-drawer'));
      expect(drawer, findsOneWidget);
      expect(_drawerPage, findsNothing);
      expect(t.getRect(drawer).width, 480);
      expect(await systemBack(t), isTrue);
      expect(drawer, findsNothing);
      final detail = t.state<AppDetailPageState>(find.byType(AppDetailPage, skipOffstage: false));
      expect(detail.page, AppDetailPageId.annotations, reason: 'Back closed the drawer, not the page');
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }
}
