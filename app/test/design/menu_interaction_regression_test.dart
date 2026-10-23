import 'dart:ui' as ui;

import 'package:dify_sf_app/src/auth/account_dropdown.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const account = Account(id: 'menu-test', name: 'Menu test', email: 'menu@example.test', role: AccountRole.owner);

Widget trigger(String text, DifyFloatingController controller) =>
    DifyButton(onPressed: controller.toggle, child: Text(text));

Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  await t.pump(const Duration(milliseconds: 200));
}

void main() {
  for (final semanticsTap in [false, true]) {
    testWidgets('third popup stays inside every ancestor (${semanticsTap ? 'semantics' : 'pointer'})', (t) async {
      final semantics = t.ensureSemantics();
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var checked = false;
      await t.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(100),
              child: DifyPopover(
                placement: DifyPlacement.rightStart,
                builder: (_, c) => trigger('Root popup', c),
                content: SizedBox(
                  width: 180,
                  height: 80,
                  child: Center(
                    child: DifyPopover(
                      placement: DifyPlacement.rightStart,
                      builder: (_, c) => trigger('Second popup', c),
                      content: SizedBox(
                        width: 180,
                        height: 80,
                        child: Center(
                          child: DifyDropdownMenu(
                            width: 180,
                            placement: DifyPlacement.rightStart,
                            builder: (_, c) => trigger('Third popup', c),
                            children: [
                              DifyMenuCheckboxItem(
                                checked: false,
                                onCheckedChange: (v) => checked = v,
                                child: const Text('Keep open'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final label in ['Root popup', 'Second popup', 'Third popup']) {
        await t.tap(find.text(label));
        await settle(t);
      }
      if (semanticsTap) {
        final node = t.semantics.find(find.bySemanticsLabel('Keep open'));
        t.binding.platformDispatcher.onSemanticsActionEvent!(
          ui.SemanticsActionEvent(
            type: ui.SemanticsAction.tap,
            nodeId: node.id,
            viewId: t.view.viewId,
          ),
        );
      } else {
        await t.tap(find.text('Keep open'));
      }
      await settle(t);
      expect(checked, isTrue);
      expect(
        t.getSemantics(find.bySemanticsLabel('Keep open')).getSemanticsData().flagsCollection.isFocused,
        ui.Tristate.isTrue,
      );
      expect(find.text('Second popup'), findsOneWidget, reason: 'grandchild interactions must not dismiss the root');
      expect(find.text('Third popup'), findsOneWidget);
      expect(find.text('Keep open'), findsOneWidget);
      await t.tapAt(const Offset(1300, 800));
      await settle(t);
      expect(find.text('Second popup'), findsNothing, reason: 'outside taps still dismiss the whole tree');
      semantics.dispose();
    });
  }

  testWidgets('menu labels do not inherit centered text alignment from the host', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: DefaultTextStyle(
          style: const TextStyle(fontSize: 14),
          textAlign: TextAlign.center,
          child: Center(
            child: DifyDropdownMenu(
              width: 240,
              open: true,
              builder: (_, c) => trigger('Open menu', c),
              children: const [DifyMenuItem(child: DifyTextLine('Menu label'))],
            ),
          ),
        ),
      ),
    );
    await settle(t);
    final paragraph = t.renderObject<RenderParagraph>(
      find.descendant(of: find.text('Menu label'), matching: find.byType(RichText)),
    );
    expect(paragraph.textAlign, TextAlign.start);
  });

  testWidgets('account appearance icon and label align with its sibling rows', (t) async {
    final theme = AppTheme(DifyThemeMode.system, remember: false);
    addTearDown(theme.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: theme,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: AccountSection(account: account),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('account-trigger')));
    await settle(t);
    Finder icon(String name) => find.byWidgetPredicate((w) => w is RemixIcon && w.name == name);
    final accountX = t.getTopLeft(icon('account-circle-line')).dx;
    expect(t.getTopLeft(icon('equalizer-2-line')).dx, accountX);
    expect(t.getTopLeft(icon('sun-line')).dx, accountX);
    expect(t.getTopLeft(icon('shut-down-line')).dx, accountX);
    Finder label(Finder row) => find.descendant(of: row, matching: find.byType(DifyTextLine)).last;
    final accountLabelX = t.getTopLeft(label(find.byKey(const ValueKey('account-open-account')))).dx;
    for (final row in [
      find.byKey(const ValueKey('account-open-preferences')),
      find.byType(AppearanceSubmenu),
      find.byKey(const ValueKey('account-logout')),
    ]) {
      expect(t.getTopLeft(label(row)).dx, accountLabelX);
    }
  });
  testWidgets('explicit menu width includes its border', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            open: true,
            width: 240,
            builder: (_, c) => trigger('Open', c),
            children: const [DifyMenuItem(child: Text('Action'))],
          ),
        ),
      ),
    );
    await settle(t);
    expect(t.getSize(find.byType(DifyMenuPopup)).width, 240);
  });

  testWidgets('an oversized menu fits inside viewport collision padding', (t) async {
    t.view.physicalSize = const Size(320, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            open: true,
            width: 800,
            builder: (_, c) => trigger('Open', c),
            children: const [DifyMenuItem(child: Text('A long action label in a small viewport'))],
          ),
        ),
      ),
    );
    await settle(t);
    final rect = t.getRect(find.byType(DifyMenuPopup));
    expect(rect.left, greaterThanOrEqualTo(5));
    expect(rect.right, lessThanOrEqualTo(315));
  });

  testWidgets('a pen hovering does not open a mouse-hover submenu', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            open: true,
            width: 200,
            builder: (_, c) => trigger('Open', c),
            children: const [
              DifyMenuSubmenu(
                label: Text('More'),
                children: [DifyMenuItem(child: Text('Child action'))],
              ),
            ],
          ),
        ),
      ),
    );
    await settle(t);
    final pen = await t.createGesture(kind: PointerDeviceKind.stylus);
    await pen.addPointer(location: Offset.zero);
    await pen.moveTo(t.getCenter(find.text('More')));
    await settle(t);
    expect(find.text('Child action'), findsNothing);
    await pen.removePointer();
  });
  testWidgets('keyboard enters and leaves a submenu then restores the root trigger', (t) async {
    final rootFocus = FocusNode();
    addTearDown(rootFocus.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            width: 200,
            builder: (_, c) => DifyButton(focusNode: rootFocus, onPressed: c.toggle, child: const Text('Open')),
            children: const [
              DifyMenuSubmenu(
                label: Text('More'),
                children: [DifyMenuItem(child: Text('Child action'))],
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('Open'));
    await settle(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(t);
    expect(Focus.of(t.element(find.text('Child action'))).hasPrimaryFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(t);
    expect(find.text('Child action'), findsNothing);
    expect(Focus.of(t.element(find.text('More'))).hasPrimaryFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(find.text('More'), findsNothing);
    expect(rootFocus.hasFocus, isTrue);
  });

  testWidgets('a cancelled touch does not activate a submenu', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            width: 200,
            builder: (_, c) => trigger('Open', c),
            children: const [
              DifyMenuSubmenu(
                label: Text('More'),
                children: [DifyMenuItem(child: Text('Child action'))],
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('Open'));
    await settle(t);
    final touch = await t.startGesture(t.getCenter(find.text('More')), kind: PointerDeviceKind.touch);
    await touch.cancel();
    await settle(t);
    expect(find.text('Child action'), findsNothing);
    await t.tap(find.text('More'));
    await settle(t);
    expect(find.text('Child action'), findsOneWidget);
    final pen = await t.createGesture(kind: PointerDeviceKind.stylus);
    await pen.addPointer(location: Offset.zero);
    await pen.moveTo(const Offset(5, 5));
    await settle(t);
    expect(find.text('Child action'), findsOneWidget, reason: 'pen hover cannot dismiss a touch-opened submenu');
    await pen.removePointer();
    await t.tapAt(const Offset(5, 5));
    await settle(t);
    expect(find.text('More'), findsNothing);
  });
  test('menus remain reachable when neither horizontal side fits', () {
    for (final side in [DifyPlacement.rightStart, DifyPlacement.leftStart]) {
      final p = computeFloatingPosition(
        anchor: const Rect.fromLTWH(115, 100, 156, 32),
        popup: const Size(180, 80),
        bounds: const Size(320, 600),
        placement: side,
      );
      expect(p.offset.dx, greaterThanOrEqualTo(difyFloatingCollisionPadding));
      expect(p.offset.dx + 180, lessThanOrEqualTo(320 - difyFloatingCollisionPadding));
    }
  });

  testWidgets('animated popup paint, hit testing and semantics share one transform', (t) async {
    final animation = AnimationController(vsync: t, value: .5);
    addTearDown(animation.dispose);
    var taps = 0;
    const childKey = ValueKey('animated-popup');
    await t.pumpWidget(
      MaterialApp(
        home: DifyFloatingLayout(
          anchor: const Rect.fromLTWH(100, 300, 40, 30),
          placement: DifyPlacement.topStart,
          animation: animation,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(key: childKey, width: 240, height: 120),
          ),
        ),
      ),
    );
    await t.pump();
    // CSS scale .95 -> 1, anchored at the lower-left corner above the trigger.
    final painted = t.getRect(find.byKey(childKey));
    expect(painted.width, closeTo(234, .001));
    expect(painted.height, closeTo(117, .001));
    await t.tapAt(const Offset(337, 240));
    expect(taps, 0, reason: 'the unpainted strip must not intercept taps');
    animation.value = 0;
    await t.pump();
    await t.tapAt(const Offset(150, 240));
    expect(taps, 0, reason: 'an invisible popup must not intercept taps');
    animation.value = 1;
    await t.pump();
    await t.tapAt(const Offset(150, 240));
    expect(taps, 1);
  });
  testWidgets('a touch-opened submenu ignores unrelated hover until an outside press', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            width: 200,
            builder: (_, c) => trigger('Open', c),
            children: const [
              DifyMenuSubmenu(
                label: Text('More'),
                children: [DifyMenuItem(child: Text('Child action'))],
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('Open'));
    await settle(t);
    await t.tap(find.text('More'));
    await settle(t);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(const Offset(5, 5));
    await settle(t);
    expect(find.text('Child action'), findsOneWidget, reason: 'hover timers only own hover-opened menus');
    await mouse.removePointer();
    await t.tapAt(const Offset(5, 5));
    await settle(t);
    expect(find.text('More'), findsNothing);
  });
  testWidgets('select popup and trigger use the same border-box width', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            child: DifySelect<String>(
              value: 'a',
              semanticLabel: 'Width select',
              options: [(value: 'a', label: 'Choice A')],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byType(DifySelect<String>));
    await settle(t);
    expect(t.getSize(find.byType(DifyMenuPopup)).width, 240);
  });

  testWidgets('submenu accessible name follows the design-system label', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: DifyDropdownMenu(
            width: 200,
            open: true,
            builder: (_, c) => trigger('Open', c),
            children: const [
              DifyMenuSubmenu(
                open: true,
                label: DifyTextLine('Export formats'),
                children: [DifyMenuItem(child: DifyTextLine('CSV'))],
              ),
            ],
          ),
        ),
      ),
    );
    await settle(t);
    expect(
      find.semantics.byPredicate(
        (node) => node.getSemanticsData().role == SemanticsRole.menu && node.label == 'Export formats',
        describeMatch: (_) => 'menu named by its shared text label',
      ),
      findsOne,
    );
    semantics.dispose();
  });
}
