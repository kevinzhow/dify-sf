import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> render(WidgetTester t, Widget w, {EdgeInsets padding = const EdgeInsets.all(240)}) => t.pumpWidget(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(padding: padding, child: w),
      ),
    ),
  ),
);

Future<TestGesture> hover(WidgetTester t, Finder f) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(t.getCenter(f));
  await t.pump();
  return g;
}

DifyButtonLook look(WidgetTester t, [Finder? f]) =>
    t.widget<DifyButtonSurface>(f ?? find.byType(DifyButtonSurface)).look;

RenderDifyFloatingLayout floating(WidgetTester t, Finder inside) => t.renderObject<RenderDifyFloatingLayout>(
  find.ancestor(of: inside, matching: find.byType(DifyFloatingLayout)).first,
);

const icon = SizedBox.square(dimension: 16);

void main() {
  group('IconButton', () {
    testWidgets('sizes match icon-button/variants.ts', (t) async {
      for (final s in DifyIconButtonSize.values) {
        await render(t, DifyIconButton(label: 'x', icon: icon, size: s, onPressed: () {}));
        expect(t.getSize(find.byType(DifyIconButton)), Size.square(s.box), reason: s.name);
        expect(t.widget<DifyButtonSurface>(find.byType(DifyButtonSurface)).radius, s.radius);
      }
      expect([for (final s in DifyIconButtonSize.values) s.box], [16, 20, 24, 32, 36]);
      expect([for (final s in DifyIconButtonSize.values) s.padding], [0, 0, 2, 6, 8]);
    });

    testWidgets('default variant tints on hover, destructive tone in red', (t) async {
      await render(t, DifyIconButton(label: 'x', icon: icon, onPressed: () {}));
      expect(look(t).foreground, DifyColors.textTertiary);
      expect(look(t).background, isNull);
      await hover(t, find.byType(DifyIconButton));
      expect(look(t).background, DifyColors.stateBaseHover);
      expect(look(t).foreground, DifyColors.textSecondary);

      await render(t, DifyIconButton(label: 'x', icon: icon, tone: DifyButtonTone.destructive, onPressed: () {}));
      await t.pump();
      expect(look(t).background, DifyColors.stateDestructiveHover);
      expect(look(t).foreground, DifyColors.textDestructive);
    });

    testWidgets('pressed shows the hover look, disabled ignores hover and taps', (t) async {
      var taps = 0;
      await render(
        t,
        DifyIconButton(label: 'x', icon: icon, variant: DifyButtonVariant.ghost, onPressed: () => taps++),
      );
      final g = await t.startGesture(t.getCenter(find.byType(DifyIconButton)));
      await t.pump();
      expect(look(t).background, DifyColors.componentsButtonGhostBgHover);
      await g.up();
      expect(taps, 1);

      await render(t, DifyIconButton(label: 'x', icon: icon, disabled: true, onPressed: () => taps++));
      await hover(t, find.byType(DifyIconButton));
      expect(look(t).background, isNull);
      expect(look(t).foreground, DifyColors.textDisabled);
      await t.tap(find.byType(DifyIconButton), warnIfMissed: false);
      expect(taps, 1);
    });

    testWidgets('keyboard focus shows the 2 px accent ring and Enter activates', (t) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      final node = FocusNode();
      addTearDown(node.dispose);
      var taps = 0;
      await render(t, DifyIconButton(label: 'x', icon: icon, focusNode: node, onPressed: () => taps++));
      node.requestFocus();
      await t.pump();
      final surface = t.widget<DifyButtonSurface>(find.byType(DifyButtonSurface));
      expect(surface.focused, isTrue);
      final box = t.widget<DecoratedBox>(
        find.descendant(of: find.byType(DifyButtonSurface), matching: find.byType(DecoratedBox)).first,
      );
      final shadows = (box.decoration as BoxDecoration).boxShadow!;
      expect(
        box.decoration,
        isA<DifyFocusDecoration>(),
        reason: 'CSS ring paints outside without tinting the interior',
      );
      expect(shadows.last.spreadRadius, 2);
      expect(shadows.last.color, DifyColors.stateAccentSolid);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 1);
    });
  });

  group('Button', () {
    testWidgets('sizes match button/index.tsx', (t) async {
      final expected = {DifyButtonSize.small: 24.0, DifyButtonSize.medium: 32.0, DifyButtonSize.large: 36.0};
      for (final MapEntry(key: s, value: h) in expected.entries) {
        await render(t, DifyButton(size: s, onPressed: () {}, child: const Text('Run')));
        expect(t.getSize(find.byType(DifyButton)).height, h);
        final padding = t.widget<Padding>(
          find.descendant(of: find.byType(DifyButton), matching: find.byType(Padding)).first,
        );
        expect(padding.padding, EdgeInsets.symmetric(horizontal: s.paddingX));
      }
      expect([for (final s in DifyButtonSize.values) s.radius], [6, 8, 10]);
      expect([for (final s in DifyButtonSize.values) s.text.fontSize], [12, 13, 14]);
      expect(
        [for (final s in DifyButtonSize.values) s.text.fontWeight],
        [FontWeight.w500, FontWeight.w500, FontWeight.w600],
      );
    });

    testWidgets('primary small uses gap-0.75 px-2', (t) async {
      await render(
        t,
        DifyButton(
          variant: DifyButtonVariant.primary,
          size: DifyButtonSize.small,
          onPressed: () {},
          leading: icon,
          child: const Text('Publish'),
        ),
      );
      final padding = t.widget<Padding>(
        find.descendant(of: find.byType(DifyButton), matching: find.byType(Padding)).first,
      );
      expect(padding.padding, const EdgeInsets.symmetric(horizontal: 8));
      expect(t.widget<Row>(find.descendant(of: find.byType(DifyButton), matching: find.byType(Row))).spacing, 3);
    });

    testWidgets('variant looks', (t) async {
      final primary = difyButtonLook(DifyButtonVariant.primary, DifyButtonTone.normal);
      expect(primary.background, DifyColors.componentsButtonPrimaryBg);
      expect(primary.ring, DifyColors.componentsButtonPrimaryBorder);
      expect(primary.insetShadows, hasLength(3));
      final primaryHover = difyButtonLook(DifyButtonVariant.primary, DifyButtonTone.normal, hovered: true);
      expect(primaryHover.background, DifyColors.componentsButtonPrimaryBgHover);
      expect(primaryHover.shadows.single.color, DifyColors.shadowShadow3);
      final secondary = difyButtonLook(DifyButtonVariant.secondary, DifyButtonTone.normal);
      expect(secondary.blur, 5);
      expect(secondary.ring, DifyColors.componentsButtonSecondaryBorder);
      final secondaryOff = difyButtonLook(DifyButtonVariant.secondary, DifyButtonTone.normal, disabled: true);
      expect(secondaryOff.blur, 4);
      expect(secondaryOff.shadows, isEmpty);
      final danger = difyButtonLook(DifyButtonVariant.primary, DifyButtonTone.destructive, disabled: true);
      expect(danger.background, DifyColors.componentsButtonDestructivePrimaryBgDisabled);
      expect(danger.ring, DifyColors.componentsButtonDestructivePrimaryBgDisabled);
      final dangerSecondaryOff = difyButtonLook(
        DifyButtonVariant.secondary,
        DifyButtonTone.destructive,
        disabled: true,
      );
      expect(dangerSecondaryOff.foreground, DifyColors.componentsButtonDestructiveSecondaryTextDisabled);
      expect(dangerSecondaryOff.background, DifyColors.componentsButtonSecondaryBgDisabled);
      expect(
        difyButtonLook(DifyButtonVariant.ghostAccent, DifyButtonTone.normal, hovered: true).background,
        DifyColors.stateAccentHover,
      );
      expect(
        difyButtonLook(DifyButtonVariant.tertiary, DifyButtonTone.destructive).background,
        DifyColors.componentsButtonDestructiveTertiaryBg,
      );
    });

    testWidgets('loading appends a 12 px spinner and blocks presses', (t) async {
      var taps = 0;
      await render(t, DifyButton(loading: true, onPressed: () => taps++, child: const Text('Save')));
      expect(find.byType(RotationTransition), findsOneWidget);
      expect(t.getSize(find.byType(RotationTransition)), const Size.square(12));
      await t.tap(find.byType(DifyButton));
      expect(taps, 0);
      expect(look(t).foreground, DifyColors.componentsButtonSecondaryTextDisabled);
    });
  });

  group('Kbd', () {
    testWidgets('keycap box and colours', (t) async {
      await render(t, const DifyKbd('k'));
      expect(t.getSize(find.byType(DifyKbd)), const Size(16, 16));
      expect(find.text('K'), findsOneWidget, reason: 'capitalize');
      final text = t.widget<Text>(find.text('K'));
      expect(text.style!.fontSize, 12);
      expect(text.style!.fontWeight, FontWeight.w500);
      expect(text.style!.color, DifyColors.textTertiary);
      await render(t, const DifyKbd('ctrl', color: DifyKbdColor.white));
      expect(find.text('Ctrl'), findsOneWidget);
      expect(t.widget<Text>(find.text('Ctrl')).style!.color, DifyColors.textPrimaryOnSurface);
    });
  });

  group('ShortcutKbd', () {
    test('formats like TanStack formatForDisplay', () {
      String f(String k, DifyPlatform p) => formatHotkeyForDisplay(k, platform: p);
      expect(f('Mod', DifyPlatform.mac), '⌘');
      expect(f('Mod', DifyPlatform.windows), 'Ctrl');
      expect(f('Mod', DifyPlatform.linux), 'Ctrl');
      expect(f('Shift', DifyPlatform.mac), '⇧');
      expect(f('Alt', DifyPlatform.mac), '⌥');
      expect(f('Meta', DifyPlatform.linux), 'Super');
      expect(f('Meta', DifyPlatform.windows), 'Win');
      expect(f('Delete', DifyPlatform.windows), '⌦');
      expect(f('Escape', DifyPlatform.mac), 'Esc');
      expect(f('c', DifyPlatform.mac), 'C');
      expect(f('Mod+Shift+S', DifyPlatform.mac), '⌘ ⇧ S');
      expect(f('Mod+Shift+S', DifyPlatform.windows), 'Ctrl+Shift+S');
      expect(f('Control+Meta+K', DifyPlatform.mac), '⌃ ⌘ K');
    });

    test('splits workflow shortcuts into keycaps', () {
      expect(const DifyShortcutKbd(shortcut: 'workflow.zoom-in', platform: DifyPlatform.mac).keys, ['⌘', '=']);
      expect(const DifyShortcutKbd(shortcut: 'workflow.redo', platform: DifyPlatform.windows).keys, ['Ctrl', 'Y']);
      expect(
        const DifyShortcutKbd(shortcut: 'workflow.download-import-log', platform: DifyPlatform.mac).keys,
        ['⌘', '⇧', 'L'],
      );
      expect(const DifyShortcutKbd(shortcut: 'workflow.dim-other-nodes', platform: DifyPlatform.linux).keys, ['Shift']);
    });
  });

  group('Divider', () {
    testWidgets('horizontal and vertical', (t) async {
      await render(
        t,
        const SizedBox(width: 100, child: Column(children: [DifyDivider()])),
        padding: EdgeInsets.zero,
      );
      expect(t.getSize(find.byType(DifyDivider)), const Size(100, 16.5));
      final c = t.widget<Container>(find.descendant(of: find.byType(DifyDivider), matching: find.byType(Container)));
      expect((c.decoration! as BoxDecoration).color, DifyColors.dividerRegular);
      await render(
        t,
        const SizedBox(height: 20, child: Row(children: [DifyDivider.vertical()])),
        padding: EdgeInsets.zero,
      );
      expect(t.getSize(find.byType(DifyDivider)), const Size(17, 20));
    });
  });

  group('placement', () {
    const bounds = Size(800, 600);
    final anchor = const Offset(100, 100) & const Size(40, 20);
    test('offsets and alignment', () {
      final p = computeFloatingPosition(
        anchor: anchor,
        popup: const Size(60, 30),
        bounds: bounds,
        placement: DifyPlacement.bottomEnd,
        sideOffset: 4,
        alignOffset: 2,
      );
      expect(p.offset, const Offset(140 - 60 - 2, 124));
      expect((p.side, p.align), (DifySide.bottom, DifyAlign.end));
      final top = computeFloatingPosition(
        anchor: anchor,
        popup: const Size(60, 30),
        bounds: bounds,
        placement: DifyPlacement.top,
        sideOffset: 8,
      );
      expect(top.offset, const Offset(90, 100 - 8 - 30));
      expect(top.origin(const Size(60, 30), anchor), const Alignment(0, 1));
    });

    test('flips to the other side when there is no room', () {
      final p = computeFloatingPosition(
        anchor: const Offset(100, 560) & const Size(40, 20),
        popup: const Size(60, 100),
        bounds: bounds,
        placement: DifyPlacement.bottomStart,
        sideOffset: 4,
      );
      expect((p.side, p.align), (DifySide.top, DifyAlign.start));
      expect(p.offset.dy, 560 - 4 - 100);
    });

    test('a context menu at the origin keeps its side and flips its alignment', () {
      final p = computeFloatingPosition(
        anchor: Rect.zero,
        popup: const Size(120, 80),
        bounds: bounds,
        placement: DifyPlacement.topEnd,
        sideOffset: 12,
        alignOffset: -3,
        collision: DifyCollision.contextMenu,
      );
      expect((p.side, p.align), (DifySide.top, DifyAlign.start));
      expect(p.offset, const Offset(5, 5));
    });
  });

  group('Popover', () {
    testWidgets('opens with scale 0.95 + fade over 150 ms and closes on an outside tap', (t) async {
      await render(
        t,
        DifyPopover(
          builder: (context, c) => DifyButton(onPressed: c.toggle, child: const Text('Open')),
          content: const SizedBox(width: 100, height: 50, child: Text('Body')),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 75));
      final layout = floating(t, find.text('Body'));
      final mid = t.widget<DifyFloatingLayout>(find.byType(DifyFloatingLayout)).animation.value;
      expect(mid, inExclusiveRange(0, 1));
      await t.pump(const Duration(milliseconds: 80));
      expect(t.widget<DifyFloatingLayout>(find.byType(DifyFloatingLayout)).animation.value, 1);
      expect((layout.side, layout.align), (DifySide.bottom, DifyAlign.center));
      final trigger = t.getRect(find.byType(DifyButton));
      final popup = t.getRect(find.byType(DifyPopoverSurface));
      expect(popup.top, trigger.bottom + 8);
      expect(popup.center.dx, trigger.center.dx);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(find.text('Body'), findsNothing);
    });
  });

  group('Tooltip', () {
    testWidgets('opens after Dify\'s 300 ms provider delay and closes 200 ms after leaving', (t) async {
      await render(
        t,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DifyTooltip(
              content: Text('First tip'),
              child: SizedBox(width: 40, height: 20, child: Text('A')),
            ),
            SizedBox(width: 40),
            DifyTooltip(
              content: Text('Second tip'),
              child: SizedBox(width: 40, height: 20, child: Text('B')),
            ),
          ],
        ),
      );
      final g = await hover(t, find.text('A'));
      await t.pump(const Duration(milliseconds: 290));
      expect(find.text('First tip'), findsNothing);
      await t.pump(const Duration(milliseconds: 20));
      await t.pump();
      expect(find.text('First tip'), findsOneWidget);
      final tip = t.getRect(find.byType(DifyTooltipSurface));
      expect(tip.bottom, t.getRect(find.text('A')).top - 8);
      final surface = t.widget<Container>(
        find.descendant(of: find.byType(DifyTooltipSurface), matching: find.byType(Container)),
      );
      expect(surface.padding, const EdgeInsets.symmetric(horizontal: 12, vertical: 8));
      // Moving to the neighbour opens it at once (delay group) and closes the first instantly.
      await g.moveTo(t.getCenter(find.text('B')));
      await t.pump();
      await t.pump();
      expect(find.text('Second tip'), findsOneWidget);
      expect(t.widget<DifyFloatingLayout>(find.byType(DifyFloatingLayout).last).animation.value, 1);
      await g.moveTo(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 190));
      expect(find.text('Second tip'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 20));
      await t.pumpAndSettle();
      expect(find.text('Second tip'), findsNothing);
      await t.pump(const Duration(milliseconds: 400)); // the delay group's instant phase
    });

    testWidgets('TipPopup box with title and keycaps, 4 px away', (t) async {
      await render(
        t,
        const DifyTipPopup(title: 'Zoom in', shortcut: 'workflow.zoom-in', child: SizedBox(width: 32, height: 32)),
      );
      await hover(t, find.byType(SizedBox).last);
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.text('Zoom in'), findsOneWidget);
      expect(find.byType(DifyKbd), findsNWidgets(2));
      final box = t.getRect(find.byType(DifyTipPopupBox));
      expect(box.bottom, 240 - 4);
      final title = t.widget<Text>(find.text('Zoom in'));
      expect(title.style!.color, DifyColors.textSecondary);
      expect(title.style!.fontWeight, FontWeight.w500);
    });
  });

  group('Menu', () {
    Widget menu({ValueChanged<String>? onSelect}) => DifyDropdownMenu(
      builder: (context, c) => DifyButton(onPressed: c.toggle, child: const Text('Open')),
      children: [
        const DifyMenuGroupLabel('Actions'),
        DifyMenuItem(onSelect: () => onSelect?.call('copy'), child: const Text('Copy')),
        const DifyMenuItem(disabled: true, child: Text('Paste')),
        const DifyMenuSeparator(),
        DifyMenuItem(
          variant: DifyMenuItemVariant.destructive,
          onSelect: () => onSelect?.call('delete'),
          child: const Text('Delete'),
        ),
        const DifyMenuCheckboxItem(checked: true, child: Text('Snap')),
        const DifyMenuSubmenu(
          label: Text('More'),
          children: [DifyMenuItem(child: Text('Nested'))],
        ),
      ],
    );

    Color? rowColor(WidgetTester t, String label) {
      final c = t.widget<Container>(
        find.ancestor(of: find.text(label), matching: find.byType(Container)).first,
      );
      return (c.decoration as BoxDecoration?)?.color;
    }

    testWidgets('surface, rows, highlight and keyboard', (t) async {
      String? chosen;
      await render(t, menu(onSelect: (v) => chosen = v));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      final layout = floating(t, find.text('Copy'));
      expect((layout.side, layout.align), (DifySide.bottom, DifyAlign.end));
      final popup = t.getRect(find.byType(DifyMenuPopup));
      final trigger = t.getRect(find.byType(DifyButton));
      expect(popup.top, trigger.bottom + 4);
      expect(popup.right, trigger.right);
      expect(t.getSize(find.ancestor(of: find.text('Copy'), matching: find.byType(Container)).first).height, 32);
      expect(find.text('ACTIONS'), findsOneWidget);
      expect(t.widget<Text>(find.text('ACTIONS')).style!.color, DifyColors.textTertiary);
      final sep = find.descendant(of: find.byType(DifyMenuSeparator), matching: find.byType(ColoredBox));
      expect(t.getSize(sep).height, 1);
      expect(t.widget<ColoredBox>(sep).color, DifyColors.dividerSubtle);
      expect(
        t.widget<Opacity>(find.ancestor(of: find.text('Paste'), matching: find.byType(Opacity)).first).opacity,
        0.3,
      );
      expect(find.byType(RemixIcon), findsNWidgets(2), reason: 'check indicator and submenu arrow');

      final g = await hover(t, find.text('Copy'));
      expect(rowColor(t, 'Copy'), DifyColors.stateBaseHover);
      await g.moveTo(t.getCenter(find.text('Delete')));
      await t.pump();
      expect(rowColor(t, 'Copy'), isNull);
      expect(rowColor(t, 'Delete'), DifyColors.stateDestructiveHover);
      expect(DefaultTextStyle.of(t.element(find.text('Delete'))).style.color, DifyColors.textDestructive);

      // ArrowUp skips the disabled row.
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(rowColor(t, 'Copy'), DifyColors.stateBaseHover);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(chosen, 'copy');
      expect(find.text('Copy'), findsNothing, reason: 'keyboard selection closes instantly');
    });

    testWidgets('submenu opens after 100 ms of hover at left-start', (t) async {
      await render(t, menu(), padding: const EdgeInsets.only(left: 400, top: 40));
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await hover(t, find.text('More'));
      await t.pump(const Duration(milliseconds: 90));
      expect(find.text('Nested'), findsNothing);
      await t.pump(const Duration(milliseconds: 20));
      await t.pumpAndSettle();
      expect(find.text('Nested'), findsOneWidget);
      final sub = floating(t, find.text('Nested'));
      expect((sub.side, sub.align), (DifySide.left, DifyAlign.start));
      final subRect = t.getRect(find.ancestor(of: find.text('Nested'), matching: find.byType(DifyMenuPopup)).first);
      final row = t.getRect(find.ancestor(of: find.text('More'), matching: find.byType(Container)).first);
      expect(subRect.right, row.left - 4);
      expect(subRect.top, row.top);
    });
  });
}
