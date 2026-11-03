// The app around the editor on tablets and landscape phones (batch 5): with touch, the Studio keeps the desktop grid
// with the cards' actions always shown at touch size (no hover), an opened app fills a tablet with the editor's touch
// chrome (its other pages keep the sidebar) and a landscape phone keeps the phone's app shell; with a mouse nothing
// changes.
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_card.dart';
import 'package:dify_sf_app/src/studio/app_row.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';

String _c(String key) => DifyI18n.tr('common', key);

const _tablet = EdgeInsets.only(top: 24, bottom: 20);
const _landscape = EdgeInsets.only(top: 24, left: 32, right: 48);

Future<void> _open(WidgetTester t, String name) async {
  await t.tap(find.text(name).first);
  await settle(t, 2500);
}

/// Whether the card's action bar takes taps and paints (it fades in on hover with a mouse).
bool _barShown(WidgetTester t, String appId) {
  final star = find.byKey(ValueKey('app-card-star-$appId'));
  final ignore = t.widget<IgnorePointer>(find.ancestor(of: star, matching: find.byType(IgnorePointer)).first);
  return !ignore.ignoring;
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (size, touch) in const [
    (Size(800, 1280), true),
    (Size(1280, 800), true),
    (Size(800, 1280), false),
    (Size(1280, 800), false),
  ]) {
    final name = '${size.width.toInt()}x${size.height.toInt()} ${touch ? 'touch' : 'mouse'}';
    testWidgets('$name: the Studio grid; the cards\' actions ${touch ? 'always shown, touch-size' : 'on hover'}', (
      t,
    ) async {
      phoneWindow(t, size: size, insets: _tablet);
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      final ws = await workspace();
      final app = ws.api.seed(name: 'Support triage');
      ws.api.seed(name: 'Release notes', starred: true);
      await pumpApp(t, ws);
      expect(t.takeException(), isNull);
      // The wider grid, not the phone's rows.
      expect(find.byType(AppCard), findsWidgets);
      expect(find.byType(AppListRow), findsNothing);
      expect(_barShown(t, app.id), touch);
      if (touch) {
        final star = find.byKey(ValueKey('app-card-star-${app.id}'));
        final box = find.ancestor(of: star, matching: find.byType(DifyTouchArea)).first;
        expect(t.getSize(box), const Size(44, 44));
        // The "…" opens the card's menu by touch.
        await t.tap(find.byKey(ValueKey('app-card-more-${app.id}')));
        await settle(t, 600);
        expect(find.text(DifyI18n.tr('app', 'editApp')), findsOneWidget);
      }
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }

  testWidgets('800x1280 touch: an opened app fills the tablet with the editor\'s touch chrome; its other pages keep '
      'the sidebar', (t) async {
    phoneWindow(t, size: const Size(800, 1280), insets: _tablet);
    DifyInteraction.debugDefault = DifyInteractionMode.touch;
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await _open(t, 'Support triage');
    expect(t.takeException(), isNull);
    expect(find.byType(DetailSidebarFrame), findsNothing);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(t.getRect(find.byType(EditorPage)), Offset.zero & const Size(800, 1280));
    // The editor's "…" has the app's other pages: Logs shows with the sidebar, at touch sizes.
    await t.tap(find.byKey(const ValueKey('phone-editor-more')));
    await settle(t, 800);
    final logs = find.text(_c('appMenus.logs'));
    await t.ensureVisible(logs);
    await t.pump();
    await t.tap(logs);
    await settle(t, 1500);
    expect(t.takeException(), isNull);
    final detail = t.state<AppDetailPageState>(find.byType(AppDetailPage, skipOffstage: false));
    expect(detail.page, AppDetailPageId.logs);
    expect(find.byType(DetailSidebarFrame), findsOneWidget);
    // Back to the editor from the sidebar: the editor again, without the sidebar.
    await t.tap(find.text(_c('appMenus.promptEng')).first);
    await settle(t, 1500);
    expect(detail.page, AppDetailPageId.workflow);
    expect(find.byType(DetailSidebarFrame), findsNothing);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  testWidgets('914x411 touch: an opened app keeps the phone\'s shell (no sidebar); a rotation changes nothing there', (
    t,
  ) async {
    phoneWindow(t, size: const Size(411, 914), insets: gestureInsets);
    DifyInteraction.debugDefault = DifyInteractionMode.touch;
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await _open(t, 'Support triage');
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    final editor = t.state(find.byType(EditorPage));
    t.view.physicalSize = const Size(914, 411);
    t.view.padding = FakeViewPadding(left: _landscape.left, top: _landscape.top, right: _landscape.right);
    t.view.viewPadding = FakeViewPadding(left: _landscape.left, top: _landscape.top, right: _landscape.right);
    await settle(t, 1500);
    expect(t.takeException(), isNull);
    expect(find.byType(DetailSidebarFrame), findsNothing);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(t.state(find.byType(EditorPage)), same(editor), reason: 'the editor kept its state');
    expect(t.getRect(find.byType(EditorPage)), Offset.zero & const Size(914, 411));
    // The app's other pages are pushed pages, as on the phone.
    await t.tap(find.byKey(const ValueKey('phone-editor-more')));
    await settle(t, 800);
    final logs = find.text(_c('appMenus.logs'));
    await t.ensureVisible(logs);
    await t.pump();
    await t.tap(logs);
    await settle(t, 1500);
    expect(find.byWidgetPredicate((x) => x is DifyTopAppBar && x.title == _c('appMenus.logs')), findsOneWidget);
    expect(await systemBack(t), isTrue);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  testWidgets('1280x800 mouse: an opened app keeps the sidebar and the desktop editor', (t) async {
    phoneWindow(t, size: const Size(1280, 800), insets: EdgeInsets.zero);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await _open(t, 'Support triage');
    expect(find.byType(DetailSidebarFrame), findsOneWidget);
    expect(find.byType(PhoneEditorFrame), findsNothing);
    expect(find.byType(HeaderInNormal), findsOneWidget);
    expect(t.takeException(), isNull);
    await unmount(t);
  });
}
