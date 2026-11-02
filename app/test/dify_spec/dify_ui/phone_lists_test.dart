// dify-sf phone layout (no Dify spec): list rows, section headers, filter chips, the search app bar and pull to
// refresh (mockup 1).
import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;

import 'phone_harness.dart';

void main() {
  group('DifyListRow', () {
    testWidgets('52 px, 64 px with a subtitle; one line each; the whole row is the target', (t) async {
      phoneView(t);
      var taps = 0, longPresses = 0, more = 0;
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Column(
            children: [
              DifyListRow(
                key: const ValueKey('plain'),
                leading: const RemixIcon('group-2-line', size: 20),
                title: 'Members',
                trailing: const [DifyListChevron()],
                onTap: () => taps++,
              ),
              DifyListRow(
                key: const ValueKey('sub'),
                title: 'A row title much too long to fit on one line of a phone screen, so it is cut with an ellipsis',
                subtitle: 'Workflow · Edited at 22:52, and a subtitle long enough to be cut as well on a phone',
                strong: true,
                onTap: () => taps++,
                onLongPress: () => longPresses++,
                actions: [
                  DifyTouchIconButton(
                    label: 'More',
                    icon: const RemixIcon('more-fill', size: 20),
                    onPressed: () => more++,
                  ),
                ],
              ),
              const DifyListRow(key: ValueKey('static'), title: 'Read only', divider: false),
            ],
          ),
        ),
      );
      expect(t.getSize(find.byKey(const ValueKey('plain'))).height, DifyListRow.minHeight);
      expect(t.getSize(find.byKey(const ValueKey('sub'))).height, DifyListRow.minHeightWithSubtitle);
      for (final text in t.widgetList<RichText>(
        find.descendant(of: find.byKey(const ValueKey('sub')), matching: find.byType(RichText)),
      )) {
        expect(text.maxLines, 1);
      }
      expect(t.takeException(), isNull);

      // The chevron's side of the row is part of its target; the action keeps its own.
      final plain = t.getRect(find.byKey(const ValueKey('plain')));
      await t.tapAt(plain.centerRight - const Offset(8, 0));
      expect(taps, 1);
      await t.tap(find.byType(DifyTouchIconButton));
      expect((taps, more), (1, 1));
      await t.longPress(
        find.text('Workflow · Edited at 22:52, and a subtitle long enough to be cut as well on a phone'),
      );
      expect(longPresses, 1);
      expect(find.bySemanticsLabel('More'), findsOneWidget, reason: 'the action stays its own node');
    });

    testWidgets('destructive rows are text-destructive; section headers are upper-case headings', (t) async {
      phoneView(t);
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Column(
            children: [
              const DifyListSectionHeader('Workspace'),
              DifyListRow(title: 'Log out', destructive: true, onTap: () {}),
            ],
          ),
        ),
      );
      expect(find.text('WORKSPACE'), findsOneWidget);
      final style = t.widget<RichText>(find.descendant(of: find.byType(DifyListRow), matching: find.byType(RichText)));
      expect(style.text.style!.color, DifyColors.textDestructive);
      final handle = t.ensureSemantics();
      expect(t.getSemantics(find.text('WORKSPACE')).flagsCollection.isHeader, isTrue);
      handle.dispose();
    });
  });

  group('DifyFilterChip', () {
    testWidgets('34 px chips with a 48 px target in a sideways scrolling bar; selected is accent', (t) async {
      phoneView(t, size: const Size(360, 780));
      final tapped = <String>[];
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Column(
            children: [
              DifyChipBar(
                children: [
                  for (final (i, l) in ['All', 'Workflow', 'Chatflow', 'Creators', 'Last modified'].indexed)
                    DifyFilterChip(
                      key: ValueKey(l),
                      label: l,
                      selected: i == 0,
                      leading: i > 2 ? const RemixIcon('filter-3-line', size: 16) : null,
                      onPressed: () => tapped.add(l),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
      expect(t.getSize(find.byKey(const ValueKey('All'))).height, DifyFilterChip.height);
      expect(t.getSize(find.byType(DifyChipBar)).height, 48);
      final all = t.getRect(find.byKey(const ValueKey('All')));
      await t.tapAt(Offset(all.center.dx, all.top - 6));
      expect(tapped, ['All'], reason: '6 px above the chip is still its target');
      final box = t.widget<DecoratedBox>(
        find.descendant(of: find.byKey(const ValueKey('All')), matching: find.byType(DecoratedBox)).first,
      );
      expect((box.decoration as BoxDecoration).color, DifyColors.stateAccentActive);
      final handle = t.ensureSemantics();
      expect(t.getSemantics(find.text('All')).getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
      expect(t.getSemantics(find.text('Workflow')).getSemanticsData().flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
      // The last chip is off screen and scrolls into view.
      await t.drag(find.byType(DifyChipBar), const Offset(-300, 0));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('Last modified')));
      expect(tapped.last, 'Last modified');
      expect(t.takeException(), isNull);
    });
  });

  group('DifyTopAppBar.search', () {
    testWidgets('a back button that closes the search and the field in place of the title', (t) async {
      phoneView(t, padding: const EdgeInsets.only(top: 32, bottom: 24));
      var closed = 0;
      await pumpPhoneApp(
        t,
        DifyPage(
          edgeToEdge: true,
          body: Column(
            children: [
              DifyTopAppBar.search(
                onBack: () => closed++,
                field: DifySearchInput(value: '', height: 40, onValueChange: (_) {}),
              ),
            ],
          ),
        ),
        edgeToEdge: true,
      );
      final bar = t.getRect(find.byType(DifyTopAppBar));
      expect(bar.top, 0);
      expect(bar.height, 32 + DifyTopAppBar.height);
      // Batch 4a: every text field is at least 44 px in a compact window (DifyInput), the 40 asked for included.
      expect(t.getSize(find.byType(DifySearchInput)).height, 44);
      expect(t.getTopLeft(find.byType(DifySearchInput)).dy, greaterThan(32));
      await t.tap(find.byType(DifyAppBarBackButton));
      expect(closed, 1);
    });
  });

  group('DifyRefreshIndicator', () {
    Widget list(Future<void> Function() onRefresh) => DifyPage(
      body: DifyRefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [for (var i = 0; i < 3; i++) SizedBox(height: 60, child: DifyTextLine('Row $i'))],
        ),
      ),
    );

    testWidgets('a pull past the trigger distance refreshes and spins until the future completes', (t) async {
      phoneView(t);
      final done = Completer<void>();
      var calls = 0;
      await pumpPhoneApp(
        t,
        list(() {
          calls++;
          return done.future;
        }),
      );
      expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsNothing);
      await t.fling(find.text('Row 0'), const Offset(0, 300), 1000);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
      expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsOneWidget);
      expect(t.getSize(find.byKey(const ValueKey('dify-refresh-indicator'))), const Size.square(40));
      done.complete();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a short pull goes back without refreshing (also with a bouncing list)', (t) async {
      phoneView(t);
      var calls = 0;
      await pumpPhoneApp(t, list(() async => calls++));
      final g = await t.startGesture(t.getCenter(find.text('Row 0')), kind: PointerDeviceKind.touch);
      await g.moveBy(const Offset(0, 20));
      await g.moveBy(const Offset(0, 20));
      await t.pump();
      expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsOneWidget);
      await g.up();
      await t.pumpAndSettle();
      expect(calls, 0);
      expect(find.byKey(const ValueKey('dify-refresh-indicator')), findsNothing);
    }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
  });
}
