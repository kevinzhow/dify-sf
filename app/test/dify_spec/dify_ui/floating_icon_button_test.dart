// dify-sf phone layout (no Dify spec): the canvas's small floating controls (mockup 3: pan / select, fit to screen).

import 'phone_harness.dart';

void main() {
  testWidgets('a 44 px secondary square, radius 12, shadow-md; a 48 px hit area; named for assistive technology', (
    t,
  ) async {
    var taps = 0;
    await renderControl(
      t,
      Center(
        child: DifyFloatingIconButton(
          label: 'Fit to screen',
          icon: const RemixIcon('focus-2-line', size: 22),
          onPressed: () => taps++,
        ),
      ),
    );
    final button = find.byType(DifyFloatingIconButton);
    expect(t.getSize(button), const Size(44, 44));
    final surface = t.widget<DifyButtonSurface>(find.byType(DifyButtonSurface));
    expect(surface.radius, DifyFloatingIconButton.radius);
    expect(surface.look.background, DifyColors.componentsButtonSecondaryBg);
    expect(surface.look.ring, DifyColors.componentsButtonSecondaryBorder);
    expect(surface.look.foreground, DifyColors.textSecondary);
    expect(surface.look.shadows, DifyShadows.md);
    expect(find.bySemanticsLabel('Fit to screen'), findsOneWidget);
    // The 48 px target: 2 px outside the square still taps it.
    final r = t.getRect(button);
    await t.tapAt(Offset(r.left - 1.5, r.center.dy));
    await t.tapAt(Offset(r.center.dx, r.bottom + 1.5));
    expect(taps, 2);
  });

  testWidgets('a toggle: selected is the accent state and reports toggled; disabled takes no tap', (t) async {
    final handle = t.ensureSemantics();
    var on = false, taps = 0;
    await renderControl(
      t,
      StatefulBuilder(
        builder: (context, set) => Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            DifyFloatingIconButton(
              key: const ValueKey('mode'),
              label: 'Select mode',
              selected: on,
              icon: RemixIcon(on ? 'cursor-line' : 'hand', size: 22),
              onPressed: () => set(() => on = !on),
            ),
            DifyFloatingIconButton(
              key: const ValueKey('off'),
              label: 'Off',
              disabled: true,
              icon: const RemixIcon('hand', size: 22),
              onPressed: () => taps++,
            ),
          ],
        ),
      ),
    );
    DifyButtonSurface surface(String key) => t.widget<DifyButtonSurface>(
      find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(DifyButtonSurface)),
    );
    expect(t.getSemantics(find.bySemanticsLabel('Select mode')).flagsCollection.isToggled, Tristate.isFalse);
    await t.tap(find.byKey(const ValueKey('mode')));
    await t.pump();
    expect(on, isTrue);
    expect(surface('mode').look.background, DifyColors.stateAccentActive);
    expect(surface('mode').look.foreground, DifyColors.textAccent);
    expect(t.getSemantics(find.bySemanticsLabel('Select mode')).flagsCollection.isToggled, Tristate.isTrue);
    await t.tap(find.byKey(const ValueKey('off')), warnIfMissed: false);
    expect(taps, 0);
    expect(surface('off').look.foreground, DifyColors.textDisabled);
    handle.dispose();
  });
}
