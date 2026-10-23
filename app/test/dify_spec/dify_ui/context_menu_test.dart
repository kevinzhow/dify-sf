// dify-spec: packages/dify-ui/src/context-menu/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _area = SizedBox(width: 120, height: 60, child: Text('Trigger area'));

void main() {
  group('context-menu wrapper', () {
    group('ContextMenuContent', () {
      // dart format off
      testWidgets('should position content at bottom-start with default placement when props are omitted', (t) async {
        final semantics = t.ensureSemantics();
        await renderWithSafeViewport(
          t,
          const DifyContextMenu(
            open: true,
            children: [DifyMenuItem(child: Text('Content action'))],
            child: _area,
          ),
        );
        final p = positioner(t, find.text('Content action'));
        expect((p.side, p.align), (DifySide.bottom, DifyAlign.start));
        expect(allByRole(SemanticsRole.menu), hasLength(1));
        expect(byRole(SemanticsRole.menuItem, 'Content action'), isNotNull);
        semantics.dispose();
      });
      // dart format on

      // dart format off
      testWidgets('should apply custom top placement and keep point-anchor alignment stable when custom positioning props are provided', (t) async {
        await renderWithSafeViewport(
          t,
          const DifyContextMenu(
            open: true,
            placement: DifyPlacement.topEnd,
            sideOffset: 12,
            alignOffset: -3,
            children: [DifyMenuItem(child: Text('Custom content'))],
            child: _area,
          ),
        );
        final p = positioner(t, find.text('Custom content'));
        expect((p.side, p.align), (DifySide.top, DifyAlign.start));
        expect(find.text('Custom content'), findsOneWidget);
      });
      // dart format on
    });

    group('ContextMenuSubContent', () {
      // dart format off
      testWidgets('should position sub-content at right-start with default placement when props are omitted', (t) async {
        final semantics = t.ensureSemantics();
        await renderWithSafeViewport(
          t,
          const DifyContextMenu(
            open: true,
            children: [
              DifyMenuSubmenu(
                open: true,
                label: Text('More actions'),
                children: [DifyMenuItem(child: Text('Sub action'))],
              ),
            ],
            child: _area,
          ),
        );
        await t.pump(const Duration(milliseconds: 200));
        final p = positioner(t, find.text('Sub action'));
        expect((p.side, p.align), (DifySide.right, DifyAlign.start));
        expect(byRole(SemanticsRole.menu, 'More actions'), isNotNull);
        expect(byRole(SemanticsRole.menuItem, 'Sub action'), isNotNull);
        final row = t.getRect(find.ancestor(of: find.text('More actions'), matching: find.byType(Container)).first);
        final sub = t.getRect(find.ancestor(of: find.text('Sub action'), matching: find.byType(DifyMenuPopup)).first);
        expect(sub.left, row.right + 4);
        expect(sub.top, row.top);
        semantics.dispose();
      });
      // dart format on
    });

    group('variant prop behavior', () {
      testWidgets('should remain interactive and set data-variant on item when variant is %s', (t) async {
        for (final variant in DifyMenuItemVariant.values) {
          var clicks = 0;
          await renderWithSafeViewport(
            t,
            DifyContextMenu(
              open: true,
              children: [
                DifyMenuItem(
                  variant: variant,
                  semanticLabel: 'menu action',
                  onSelect: () => clicks++,
                  child: const Text('Item label'),
                ),
              ],
              child: _area,
            ),
          );
          await t.tap(find.text('Item label'));
          expect(clicks, 1);
          final destructive = variant == DifyMenuItemVariant.destructive;
          expect(
            DefaultTextStyle.of(t.element(find.text('Item label'))).style.color,
            destructive ? DifyColors.textDestructive : DifyColors.textSecondary,
          );
          await t.pumpWidget(const SizedBox());
          await t.pump();
        }
      });

      testWidgets('should remain interactive and set data-variant on submenu trigger when variant is %s', (t) async {
        for (final variant in DifyMenuItemVariant.values) {
          var opened = 0;
          await renderWithSafeViewport(
            t,
            DifyContextMenu(
              open: true,
              children: [
                DifyMenuSubmenu(
                  variant: variant,
                  semanticLabel: 'submenu action',
                  onOpenChange: (open) => opened += open ? 1 : 0,
                  label: const Text('Trigger item'),
                  children: const [DifyMenuItem(child: Text('Sub action'))],
                ),
              ],
              child: _area,
            ),
          );
          await t.tap(find.text('Trigger item'));
          expect(opened, 1);
          expect(
            DefaultTextStyle.of(t.element(find.text('Trigger item'))).style.color,
            variant == DifyMenuItemVariant.destructive ? DifyColors.textDestructive : DifyColors.textSecondary,
          );
          await t.pumpWidget(const SizedBox());
          await t.pump();
        }
      });
    });

    group('ContextMenuTrigger interaction', () {
      testWidgets('should open menu when right-clicking trigger area', (t) async {
        await renderWithSafeViewport(
          t,
          const DifyContextMenu(
            children: [DifyMenuItem(child: Text('Open on right click'))],
            child: _area,
          ),
        );
        expect(find.text('Open on right click'), findsNothing);
        final at = t.getCenter(find.text('Trigger area'));
        await t.tapAt(at, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        expect(find.text('Open on right click'), findsOneWidget);
        final popup = t.getRect(find.byType(DifyMenuPopup));
        expect(popup.topLeft, at, reason: 'anchored at the pointer, bottom-start, no offset');
      });
    });

    group('ContextMenuSeparator', () {
      testWidgets('should render separator and keep surrounding rows when separator is between items', (t) async {
        await renderWithSafeViewport(
          t,
          const DifyContextMenu(
            open: true,
            children: [
              DifyMenuItem(child: Text('First action')),
              DifyMenuSeparator(),
              DifyMenuItem(child: Text('Second action')),
            ],
            child: _area,
          ),
        );
        expect(find.text('First action'), findsOneWidget);
        expect(find.text('Second action'), findsOneWidget);
        expect(find.byType(DifyMenuSeparator), findsOneWidget);
      });
    });
  });
}
