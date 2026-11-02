// dify-sf phone step list (no Dify spec; mockup 2-steps and 7-run): cards, connectors, lane labels, links, add rows
// and the lane rails.
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;

import 'phone_harness.dart';

Widget _list(List<Widget> rows) => DifyPage(
  body: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
  ),
);

BoxDecoration _decorationOf(WidgetTester t, Finder card) =>
    t
            .widgetList<AnimatedContainer>(find.descendant(of: card, matching: find.byType(AnimatedContainer)))
            .first
            .decoration!
        as BoxDecoration;

void main() {
  group('DifyStepCard', () {
    testWidgets('a 64 px card: icon, title and summary on one line each, a chevron; tap, long press, right click', (
      t,
    ) async {
      phoneView(t, size: const Size(411, 914));
      var taps = 0, longPresses = 0;
      await pumpPhoneApp(
        t,
        _list([
          DifyStepCard(
            key: const ValueKey('card'),
            leading: const SizedBox.square(dimension: 32),
            title: 'Count Android words in a title that is far too long for one line',
            subtitle: 'Python 3 · Output: words, python, and a summary much too long for a phone',
            onTap: () => taps++,
            onLongPress: () => longPresses++,
          ),
        ]),
      );
      final card = find.byKey(const ValueKey('card'));
      expect(t.getSize(card).height, inInclusiveRange(62, 66));
      for (final text in t.widgetList<RichText>(find.descendant(of: card, matching: find.byType(RichText)))) {
        expect(text.maxLines, 1);
      }
      expect(t.takeException(), isNull);
      expect(
        find.descendant(of: card, matching: find.byType(RemixIcon)),
        findsOneWidget,
        reason: 'the chevron',
      );
      final d = _decorationOf(t, card);
      expect((d.border! as Border).top.color, DifyColors.componentsPanelBorder);
      expect((d.borderRadius! as BorderRadius).topLeft.x, DifyStepCard.radius);
      expect(d.color, DifyColors.componentsPanelBg);

      await t.tap(card);
      await t.longPress(card);
      await t.tapAt(t.getCenter(card), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await t.pump();
      expect((taps, longPresses), (1, 2));
      final named = find.bySemanticsLabel(RegExp('^Count Android.*, Python 3'));
      expect(named, findsOneWidget);
      final data = t.getSemantics(named).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap) && data.hasAction(SemanticsAction.longPress), isTrue);
    });

    testWidgets('selected, run status, highlighted and waiting looks', (t) async {
      phoneView(t, size: const Size(411, 914));
      await pumpPhoneApp(
        t,
        _list([
          const DifyStepCard(key: ValueKey('selected'), title: 'A', selected: true),
          DifyStepCard(key: const ValueKey('status'), title: 'B', statusColor: DifyColors.stateSuccessSolid),
          const DifyStepCard(key: ValueKey('highlighted'), title: 'C', highlighted: true, selected: true),
          const DifyStepCard(key: ValueKey('waiting'), title: 'D', dimmed: true, chevron: false),
        ]),
      );
      await t.pump(const Duration(milliseconds: 300));
      Border border(String key) => _decorationOf(t, find.byKey(ValueKey(key))).border! as Border;
      expect(
        (border('selected').top.color, border('selected').top.width),
        (
          DifyColors.componentsOptionCardOptionSelectedBorder,
          2.0,
        ),
      );
      expect((border('status').top.color, border('status').top.width), (DifyColors.stateSuccessSolid, 1.5));
      expect(border('highlighted').top.color, DifyColors.stateAccentSolid, reason: 'the highlight wins');
      expect(
        _decorationOf(t, find.byKey(const ValueKey('highlighted'))).color,
        Color.alphaBlend(DifyColors.stateAccentHover, DifyColors.componentsPanelBg),
      );
      final waiting = find.byKey(const ValueKey('waiting'));
      expect(t.widget<Opacity>(find.ancestor(of: find.text('D'), matching: find.byType(Opacity)).first).opacity, 0.7);
      expect(find.descendant(of: waiting, matching: find.byType(RemixIcon)), findsNothing);
    });
  });

  group('DifyStepConnector', () {
    testWidgets('a 48 px row; the "+" is a 24 px circle on the line with a 48 px target, named for assistive tech', (
      t,
    ) async {
      phoneView(t, size: const Size(411, 914));
      var adds = 0;
      await pumpPhoneApp(
        t,
        _list([
          DifyStepConnector(key: const ValueKey('plus'), addLabel: 'Add a step here', onAdd: () => adds++),
          const DifyStepConnector(key: ValueKey('line')),
          DifyStepConnector(key: const ValueKey('end'), end: true, onAdd: () => adds++),
        ]),
      );
      final plus = find.byKey(const ValueKey('plus'));
      expect(t.getSize(plus).height, DifyStepMetrics.rowHeight);
      final row = t.getRect(plus);
      final center = row.topLeft + const Offset(DifyStepMetrics.lineX, 24);
      final circle = t.getRect(
        find.descendant(of: plus, matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 24)).first,
      );
      expect(circle.center, center);
      // 23 px from the circle's centre, outside the circle, inside the 48 px target.
      await t.tapAt(center + const Offset(0, 23));
      await t.tapAt(center + const Offset(-23, -23));
      expect(adds, 2);
      expect(t.getSemantics(find.descendant(of: plus, matching: find.byType(DifyPressable))).label, 'Add a step here');
      expect(
        find.descendant(of: find.byKey(const ValueKey('line')), matching: find.byType(DifyPressable)),
        findsNothing,
      );
      // After the last step the line stops at the "+".
      final line = find.descendant(of: find.byKey(const ValueKey('end')), matching: find.byType(ColoredBox));
      expect(t.getSize(line).height, DifyStepMetrics.rowHeight / 2);
    });
  });

  group('lanes and rows', () {
    testWidgets('rails one indent per level; a lane label is a tinted chip; links and add rows are 48 px targets', (
      t,
    ) async {
      phoneView(t, size: const Size(411, 914));
      var links = 0, adds = 0;
      final cyan = DifyColors.utilColorsCyanCyan500, grey = DifyColors.textQuaternary;
      await pumpPhoneApp(
        t,
        _list([
          DifyStepRails(
            rails: [cyan],
            opensLane: true,
            child: DifyStepLaneLabel('IF words > 0', key: const ValueKey('label'), color: cyan),
          ),
          DifyStepRails(
            rails: [cyan, grey],
            child: DifyStepLinkRow(key: const ValueKey('link'), label: 'Continues at End', onTap: () => links++),
          ),
          DifyStepRails(
            rails: [grey],
            child: DifyStepAddRow(key: const ValueKey('add'), label: 'Add step', onTap: () => adds++),
          ),
          const DifyStepAddRow(key: ValueKey('disabled'), label: 'Add step'),
        ]),
      );
      final page = t.getTopLeft(find.byType(Column).first);
      expect(t.getTopLeft(find.byKey(const ValueKey('label'))).dx - page.dx, DifyStepMetrics.indent);
      expect(t.getTopLeft(find.byKey(const ValueKey('link'))).dx - page.dx, 2 * DifyStepMetrics.indent);
      final chip = t.widget<DecoratedBox>(
        find.descendant(of: find.byKey(const ValueKey('label')), matching: find.byType(DecoratedBox)),
      );
      expect((chip.decoration as BoxDecoration).color, cyan.withValues(alpha: cyan.a * 0.13));
      expect(t.widget<DifyText>(find.byType(DifyText).first).color, cyan);
      expect(t.getSize(find.byKey(const ValueKey('link'))).height, DifyStepMetrics.rowHeight);
      expect(t.getSize(find.byKey(const ValueKey('add'))).height, DifyStepMetrics.rowHeight);
      await t.tap(find.byKey(const ValueKey('link')));
      await t.tap(find.byKey(const ValueKey('add')));
      await t.tap(find.byKey(const ValueKey('disabled')), warnIfMissed: false);
      expect((links, adds), (1, 1));
      expect(find.byType(CustomPaint), findsWidgets);
      expect(t.takeException(), isNull);
    });
  });
}
