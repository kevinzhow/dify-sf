// An opened app on a phone (batch 3a): no sidebar; the editor fills the page and its "…" opens the app's other pages
// (pushed, with an app bar; back returns to the editor) and the app's operations; back from the editor returns to
// the Studio; a rotation through the desktop layout keeps the editor.
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_row.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

String _c(String key) => DifyI18n.tr('common', key);

Future<void> _open(WidgetTester t, String name) async {
  await t.tap(find.text(name));
  await settle(t, 2500);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in phoneWindows) {
    testWidgets('${w.name}: the editor fills the app; its "…" opens the app\'s pages as pushed pages', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await pumpApp(t, ws);
      await _open(t, 'Support triage');
      expect(t.takeException(), isNull);
      expect(find.byType(DetailSidebarFrame), findsNothing);
      expect(find.byType(PhoneEditorFrame), findsOneWidget);
      expect(t.getRect(find.byType(EditorPage)), Offset.zero & w.size);

      await t.tap(find.byKey(const ValueKey('phone-editor-more')));
      await settle(t, 800);
      // The app's other pages and its operations follow the editor's own entries.
      for (final label in [
        _c('appMenus.accessPoint'),
        _c('appMenus.logs'),
        _c('appMenus.overview'),
        DifyI18n.tr('app', 'editApp'),
        DifyI18n.tr('app', 'duplicate'),
        DifyI18n.tr('app', 'export'),
        _c('operation.delete'),
      ]) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text(_c('appMenus.promptEng')), findsNothing, reason: 'the editor is the page itself');
      final logs = find.text(_c('appMenus.logs'));
      await t.ensureVisible(logs);
      await t.pump();
      await t.tap(logs);
      await settle(t, 1500);
      expect(t.takeException(), isNull);
      // A pushed page: the page's title and the app's name in its app bar, over the editor.
      final bar = find.byWidgetPredicate((x) => x is DifyTopAppBar && x.title == _c('appMenus.logs'));
      expect(bar, findsOneWidget);
      expect(t.widget<DifyTopAppBar>(bar).subtitle, 'Support triage');
      expect(t.getRect(bar).top, 0);
      expect(find.byType(PhoneEditorFrame), findsNothing, reason: 'covered by the pushed page');
      final detail = t.state<AppDetailPageState>(find.byType(AppDetailPage, skipOffstage: false));
      expect(detail.page, AppDetailPageId.workflow, reason: 'the editor stays the app\'s page');

      expect(await systemBack(t), isTrue);
      await settle(t, 800);
      expect(bar, findsNothing);
      expect(find.byType(PhoneEditorFrame), findsOneWidget);

      expect(await systemBack(t), isTrue);
      await settle(t, 1000);
      expect(find.byType(AppDetailPage), findsNothing);
      expect(find.byType(AppListRow), findsOneWidget);
      await unmount(t);
    });
  }

  testWidgets('a rotation through the desktop layout keeps the editor and its document', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await _open(t, 'Support triage');
    final editor = t.state(find.byType(EditorPage));
    t.view.physicalSize = const Size(914, 411);
    t.view.padding = const FakeViewPadding(left: 32, right: 48);
    t.view.viewPadding = const FakeViewPadding(left: 32, right: 48);
    await settle(t, 1000);
    expect(find.byType(DetailSidebarFrame), findsOneWidget);
    expect(find.byType(PhoneEditorFrame), findsNothing);
    expect(t.state(find.byType(EditorPage)), same(editor));
    t.view.physicalSize = const Size(411, 914);
    t.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    t.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    await settle(t, 1000);
    expect(find.byType(DetailSidebarFrame), findsNothing);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(t.state(find.byType(EditorPage)), same(editor));
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  testWidgets('a link to another page of the app pushes it over the editor', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await _open(t, 'Support triage');
    final detail = t.state<AppDetailPageState>(find.byType(AppDetailPage));
    detail.navigate(AppDetailPageId.overview);
    await settle(t, 1500);
    expect(find.byWidgetPredicate((x) => x is DifyTopAppBar && x.title == _c('appMenus.overview')), findsOneWidget);
    expect(detail.page, AppDetailPageId.workflow);
    // Navigating to the editor shows it again.
    detail.navigate(AppDetailPageId.workflow);
    await settle(t, 1000);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(find.byWidgetPredicate((x) => x is DifyTopAppBar && x.title == _c('appMenus.overview')), findsNothing);
    await unmount(t);
  });
}
