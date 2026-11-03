// The touch desktop's tables and the create dialog (device-check leftovers): with touch on a tablet the Logs table's
// rows, the Annotations table's Edit / Remove, the Members table's row menu and Create from Blank's close are touch-sized
// (44 dp); a mouse keeps Dify's sizes.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/settings/members/members_page.dart';
import 'package:dify_sf_app/src/studio/create_app_modal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dify_spec/members/harness.dart' show MembersFixture, renderMembers;
import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';

const _tablet = Size(1280, 800);
const _insets = EdgeInsets.only(top: 24, bottom: 20);

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

Future<void> _openPage(WidgetTester t, String name, AppDetailPageId page) async {
  await t.tap(find.text(name).first);
  await settle(t, 2500);
  t.state<AppDetailPageState>(find.byType(AppDetailPage, skipOffstage: false)).navigate(page);
  await settle(t, 1500);
}

/// [control]'s touch box (its [DifyTouchArea]) or the control itself.
Finder _box(Finder control) {
  final box = find.ancestor(of: control, matching: find.byType(DifyTouchArea));
  return box.evaluate().isEmpty ? control : box.first;
}

void _sized(WidgetTester t, Finder f, bool touch, String reason) {
  final size = t.getSize(f);
  if (touch) {
    expect(size.height, greaterThanOrEqualTo(44), reason: '$reason: $size');
    expect(size.width, greaterThanOrEqualTo(44), reason: '$reason: $size');
  } else {
    expect(size.height, lessThan(44), reason: "$reason: a mouse keeps Dify's size, $size");
  }
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => DifyInteraction.debugDefault = null);

  for (final touch in [true, false]) {
    final input = touch ? 'touch' : 'mouse';

    testWidgets('1280x800 $input: the Logs table\'s rows are ${touch ? 'touch-high' : "Dify's"}', (t) async {
      phoneWindow(t, size: _tablet, insets: _insets);
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await _pumpApp(t, ws);
      await _openPage(t, 'Support triage', AppDetailPageId.logs);
      expect(find.byType(DifyTable), findsOneWidget);
      final trigger = find.byType(LogDrawerTrigger);
      expect(trigger, findsWidgets);
      final h = t.getSize(trigger.first).height;
      touch ? expect(h, greaterThanOrEqualTo(44)) : expect(h, lessThan(44));
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('1280x800 $input: the Annotations table\'s Edit / Remove are ${touch ? 'touch-sized' : "Dify's"}', (
      t,
    ) async {
      phoneWindow(t, size: _tablet, insets: _insets);
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      final ws = await workspace();
      final app = ws.api.seed(name: 'Help desk bot', mode: AppModes.advancedChat);
      await FakeAnnotationsApi(ws.api).create(app.id, question: 'How do I reset it?', answer: 'Open Settings.');
      await _pumpApp(t, ws);
      await _openPage(t, 'Help desk bot', AppDetailPageId.annotations);
      expect(find.byType(DifyTable), findsOneWidget);
      for (final key in ['feature.annotation.edit', 'feature.annotation.remove']) {
        final label = DifyI18n.tr('appDebug', key);
        final button = find.byWidgetPredicate((w) => w is DifyIconButton && w.label == label);
        expect(button, findsWidgets, reason: key);
        _sized(t, _box(button.first), touch, key);
      }
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('1440x900 $input: the Members table\'s row menu is ${touch ? 'touch-sized' : "Dify's"}', (t) async {
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      final f = await MembersFixture.create();
      await renderMembers(t, SingleChildScrollView(child: MembersPage(members: f.members)));
      final menu = find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('member-actions-'),
      );
      expect(menu, findsWidgets);
      _sized(t, _box(menu.first), touch, 'row menu');
      expect(t.takeException(), isNull);
    });

    testWidgets('800x1280 $input: Create from Blank\'s close is ${touch ? '44' : '36'} dp', (t) async {
      phoneWindow(t, size: const Size(800, 1280), insets: _insets);
      DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          navigatorKey: nav,
          home: const DifyPage(body: SizedBox.expand()),
        ),
      );
      final shown = showCreateAppDialogShell<void>(
        nav.currentContext!,
        title: 'Create from Blank',
        builder: (_) => const SizedBox.expand(),
      );
      await settle(t, 600);
      final close = find.byKey(const ValueKey('create-app-shell-close'));
      expect(t.getSize(close), touch ? const Size(44, 44) : const Size(36, 36));
      await t.tap(close);
      await settle(t, 600);
      await shown;
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }
}
