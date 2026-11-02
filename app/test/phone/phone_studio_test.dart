/// The Studio on a phone (mockup 1): one-line rows, the filter chip row with its sheets, the inline search, the
/// "…" action sheet, Create as a floating button with an action sheet, pull to refresh, and the empty states.
library;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_row.dart';
import 'package:dify_sf_app/src/studio/studio_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

List<String> _rows(WidgetTester t) => [
  for (final r in t.widgetList<AppListRow>(find.byType(AppListRow))) r.app.name,
];

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in phoneWindows) {
    testWidgets('${w.name}: rows, chips and Create fit without overflow', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      final ws = await workspace();
      final long = ws.api.seed(
        name: 'A workflow with a name far too long to fit on one line of a phone',
        creatorName: 'Owner',
      );
      ws.api.seed(name: 'Support bot', mode: AppModes.advancedChat, starred: true);
      await pumpApp(t, ws);
      expect(t.takeException(), isNull);

      // A row: the 44 px icon, the name on one line, "type · edited time", the "…" button.
      final row = find.byKey(ValueKey('row-${long.id}'));
      expect(t.getSize(row).height, DifyListRow.minHeightWithSubtitle);
      expect(find.descendant(of: row, matching: find.textContaining('Workflow · Edited at')), findsOneWidget);
      expect(find.byKey(ValueKey('app-row-more-${long.id}')), findsOneWidget);
      // The starred app shows in its section and in the list.
      expect(find.text('STARRED'), findsOneWidget);
      expect(find.text('ALL APPS'), findsOneWidget);

      // The chips scroll sideways as one row under the app bar.
      final chips = find.byKey(const ValueKey('studio-filter-chips'));
      expect(t.getSize(chips).height, 48);
      for (final key in ['studio-type-chip-all', 'studio-type-chip-workflow', 'studio-type-chip-advanced-chat']) {
        expect(t.getSize(find.byKey(ValueKey(key))).height, DifyFilterChip.height, reason: key);
      }
      expect(find.byKey(const ValueKey('studio-creators-chip')), findsOneWidget);
      expect(find.byKey(const ValueKey('studio-sort-chip')), findsOneWidget);
      expect(find.byKey(const ValueKey('studio-create-fab')), findsOneWidget);
      await unmount(t);
    });
  }

  testWidgets('type chips filter the list; the sort and creators pickers are sheets', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    final kim = ws.accounts.byEmail('kim@example.com')!;
    ws.api.seed(name: 'Flow one', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1));
    ws.api.seed(
      name: 'Chat two',
      mode: AppModes.advancedChat,
      createdBy: kim.id,
      creatorName: 'Kim',
      createdAt: DateTime.utc(2026, 10, 2),
      updatedAt: DateTime.utc(2026, 10, 2),
    );
    await pumpApp(t, ws);
    expect(_rows(t), ['Chat two', 'Flow one']);

    await tapVisible(t, find.byKey(const ValueKey('studio-type-chip-workflow')));
    expect(_rows(t), ['Flow one']);
    final chip = t.widget<DifyFilterChip>(find.byKey(const ValueKey('studio-type-chip-workflow')));
    expect(chip.selected, isTrue);
    await tapVisible(t, find.byKey(const ValueKey('studio-type-chip-all')));
    expect(_rows(t), ['Chat two', 'Flow one']);

    // Sort: an action sheet of the orders, the current one checked.
    await tapVisible(t, find.byKey(const ValueKey('studio-sort-chip')));
    expect(find.text('Earliest created'), findsOneWidget);
    await t.tap(find.text('Earliest created'));
    await settle(t);
    expect(_rows(t), ['Flow one', 'Chat two']);
    expect(
      find.descendant(of: find.byKey(const ValueKey('studio-sort-chip')), matching: find.text('Earliest created')),
      findsOneWidget,
    );

    // Creators: a sheet with search and a checkbox row per member; each tap filters at once.
    await tapVisible(t, find.byKey(const ValueKey('studio-creators-chip')));
    final kimRow = find.byKey(ValueKey('studio-creator-row-${kim.id}'));
    expect(kimRow, findsOneWidget);
    expect(t.getSize(kimRow).height, greaterThanOrEqualTo(DifyTouch.minTarget));
    await t.tap(kimRow);
    await settle(t);
    expect(find.byKey(const ValueKey('studio-creators-sheet-reset')), findsOneWidget);
    // The filter follows each tap; back closes the sheet.
    expect(await systemBack(t), isTrue);
    expect(_rows(t), ['Chat two']);
    expect(find.text('Creators · 1'), findsOneWidget);
    await unmount(t);
  });

  testWidgets('search opens in the app bar and keeps the list logic; closing it clears the query', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    ws.api.seed(name: 'Release notes');
    await pumpApp(t, ws);
    await t.tap(find.byKey(const ValueKey('studio-search-open')));
    await settle(t);
    expect(find.byKey(const ValueKey('studio-create-fab')), findsNothing, reason: 'no Create over the results');
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('studio-search')), matching: find.byType(EditableText)),
      'Support',
    );
    await settle(t);
    expect(_rows(t), ['Support triage']);
    await t.tap(find.byType(DifyAppBarBackButton));
    await settle(t);
    expect(find.byKey(const ValueKey('studio-search')), findsNothing);
    expect(_rows(t), hasLength(2));
    await unmount(t);
  });

  testWidgets('"…" opens the app operations as an action sheet: star, edit, duplicate, export, delete', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    final app = ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);

    await t.tap(find.byKey(ValueKey('app-row-more-${app.id}')));
    await settle(t);
    for (final label in ['Star app', 'Edit Info', 'Duplicate', 'Export DSL', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await t.tap(find.text('Star app'));
    await settle(t);
    expect(ws.api.requests['star'], 1);
    expect(find.text('STARRED'), findsOneWidget);

    // A long press opens the same sheet; Delete asks first (the existing dialog).
    await t.longPress(find.byKey(ValueKey('row-${app.id}')));
    await settle(t);
    expect(find.text('Unstar app'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await settle(t);
    expect(find.text('Delete this app?'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-app-confirm')), findsOneWidget);
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  testWidgets('Create opens its options as an action sheet; From blank opens the create dialog', (t) async {
    phoneWindow(t, size: const Size(360, 780));
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await t.tap(find.byKey(const ValueKey('studio-create-fab')));
    await settle(t);
    expect(find.text('Import DSL file'), findsOneWidget);
    await t.tap(find.text('Create from Blank'));
    await settle(t);
    expect(find.byKey(const ValueKey('create-app-name')), findsOneWidget);
    expect(t.takeException(), isNull, reason: 'the create dialog fits 360 dp');
    await unmount(t);
  });

  testWidgets('pull to refresh refetches the list (touch only)', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    final before = ws.api.requests['list'] ?? 0;
    await t.fling(find.byKey(const ValueKey('studio-catalog')), const Offset(0, 400), 1000);
    await t.pump();
    expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsOneWidget);
    await settle(t);
    expect(ws.api.requests['list'], greaterThan(before));
    expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsNothing);
    await unmount(t);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a narrow desktop window gets the phone layout but no pull gesture', (t) async {
    phoneWindow(t, insets: EdgeInsets.zero);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    expect(find.byType(AppListRow), findsOneWidget);
    expect(find.byType(DifyRefreshIndicator), findsNothing);
    await unmount(t);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('the first-run empty state and the no-match state keep working', (t) async {
    phoneWindow(t, size: const Size(360, 780));
    final ws = await workspace();
    await pumpApp(t, ws);
    expect(find.byKey(const ValueKey('studio-first-empty')), findsOneWidget);
    expect(t.takeException(), isNull);
    ws.api.seed(name: 'Flow one');
    t.state<StudioPageState>(find.byType(StudioPage)).list.setCategory(AppModes.advancedChat);
    await settle(t);
    expect(find.byKey(const ValueKey('studio-empty')), findsOneWidget);
    expect(t.takeException(), isNull);
    await unmount(t);
  });
}
