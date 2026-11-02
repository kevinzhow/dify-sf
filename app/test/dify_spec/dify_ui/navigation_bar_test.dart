// dify-sf phone layout (no Dify spec): the bottom navigation and the floating action button (mockups 1, 2).
import 'phone_harness.dart';

const _destinations = [
  DifyNavigationDestination(icon: RemixIcon('apps-2-line', size: 22), label: 'Studio'),
  DifyNavigationDestination(icon: RemixIcon('puzzle-2-line', size: 22), label: 'Integrations', badgeCount: 3),
  DifyNavigationDestination(icon: RemixIcon('user-line', size: 22), label: 'Account', badgeCount: 120),
];

void main() {
  group('DifyNavigationBar', () {
    testWidgets('lays out equal destinations in a 64 px bar and reports a tap', (t) async {
      phoneView(t);
      var selected = 0;
      await renderControl(
        t,
        StatefulBuilder(
          builder: (context, set) => DifyNavigationBar(
            destinations: _destinations,
            selectedIndex: selected,
            onDestinationSelected: (i) => set(() => selected = i),
          ),
        ),
      );
      expect(t.getSize(find.byType(DifyNavigationBar)).height, DifyNavigationBar.height);
      final cells = [
        for (final l in ['Studio', 'Integrations', 'Account']) t.getCenter(find.text(l)).dx,
      ];
      expect(cells[1] - cells[0], closeTo(cells[2] - cells[1], 0.5));
      await t.tap(find.text('Account'));
      await t.pump();
      expect(selected, 2);
      // The whole column is the target: a tap just under the top border selects too.
      await t.tapAt(Offset(cells[1], t.getRect(find.byType(DifyNavigationBar)).top + 4));
      await t.pump();
      expect(selected, 1);
    });

    testWidgets('marks the selected destination with the accent pill, text and semantics', (t) async {
      final handle = t.ensureSemantics();
      phoneView(t);
      await renderControl(t, const DifyNavigationBar(destinations: _destinations, selectedIndex: 0));
      final pills = t
          .widgetList<DecoratedBox>(
            find.descendant(of: find.byType(DifyNavigationBar), matching: find.byType(DecoratedBox)),
          )
          .where((d) => (d.decoration as BoxDecoration).borderRadius == BorderRadius.circular(15))
          .toList();
      expect(pills, hasLength(3));
      expect((pills[0].decoration as BoxDecoration).color, DifyColors.stateAccentActive);
      expect((pills[1].decoration as BoxDecoration).color, isNull);
      RichText label(String s) =>
          t.widget<RichText>(find.descendant(of: find.text(s), matching: find.byType(RichText)).first);
      expect(label('Studio').text.style!.color, DifyColors.textAccent);
      expect(label('Studio').text.style!.fontWeight, FontWeight.w600);
      expect(label('Account').text.style!.color, DifyColors.textTertiary);
      final studio = t.getSemantics(find.text('Studio')).getSemanticsData();
      expect(studio.flagsCollection.isSelected, Tristate.isTrue);
      expect(t.getSemantics(find.text('Account')).getSemanticsData().flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('shows badge counts, 99+ above 99, and none for 0', (t) async {
      final handle = t.ensureSemantics();
      phoneView(t);
      await renderControl(t, const DifyNavigationBar(destinations: _destinations, selectedIndex: 0));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
      expect(find.byType(DifyCountBadge), findsNWidgets(2));
      expect(t.getSemantics(find.text('Integrations')).getSemanticsData().value, '3');
      handle.dispose();
    });

    testWidgets('asserts 3 to 5 destinations', (t) async {
      await renderControl(t, DifyNavigationBar(destinations: _destinations.take(2).toList(), selectedIndex: 0));
      expect(t.takeException(), isAssertionError);
    });
  });

  group('DifyFab', () {
    testWidgets('regular: a 52 px primary square, radius 16, shadow-lg, named for assistive technology', (t) async {
      var taps = 0;
      await renderControl(
        t,
        Center(
          child: DifyFab(icon: const RemixIcon('add-line', size: 28), label: 'Add step', onPressed: () => taps++),
        ),
      );
      expect(t.getSize(find.byType(DifyFab)), const Size(52, 52));
      final surface = t.widget<DifyButtonSurface>(find.byType(DifyButtonSurface));
      expect(surface.radius, 16);
      expect(surface.look.background, DifyColors.componentsButtonPrimaryBg);
      expect(surface.look.shadows, DifyShadows.lg);
      expect(find.bySemanticsLabel('Add step'), findsOneWidget);
      await t.tap(find.byType(DifyFab));
      expect(taps, 1);
    });

    testWidgets('extended: icon and label, 52 px tall; disabled loses the shadow and the tap', (t) async {
      var taps = 0;
      await renderControl(
        t,
        Column(
          children: [
            DifyFab.extended(icon: const RemixIcon('add-line', size: 22), label: 'Create', onPressed: () => taps++),
            DifyFab.extended(
              key: const ValueKey('off'),
              icon: const RemixIcon('add-line', size: 22),
              label: 'Off',
              disabled: true,
              onPressed: () => taps++,
            ),
          ],
        ),
      );
      final size = t.getSize(find.byType(DifyFab).first);
      expect(size.height, 52);
      expect(size.width, greaterThan(52));
      expect(find.text('Create'), findsOneWidget);
      final off = t.widget<DifyButtonSurface>(
        find.descendant(of: find.byKey(const ValueKey('off')), matching: find.byType(DifyButtonSurface)),
      );
      expect(off.look.shadows, isEmpty);
      await t.tap(find.text('Off'));
      await t.tap(find.text('Create'));
      expect(taps, 1);
    });
  });
}
