// dify-spec: packages/dify-ui/src/dropdown-menu/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _trigger(BuildContext context, DifyFloatingController c) =>
    DifyButton(semanticLabel: 'menu trigger', onPressed: c.toggle, child: const Text('Open'));

void main() {
  group('dropdown-menu wrapper', () {
    group('DropdownMenuContent', () {
      testWidgets('should position content at bottom-end with default placement when props are omitted', (t) async {
        final semantics = t.ensureSemantics();
        await renderWithSafeViewport(
          t,
          const DifyDropdownMenu(
            open: true,
            builder: _trigger,
            children: [DifyMenuItem(child: Text('Content action'))],
          ),
        );
        final p = positioner(t, find.text('Content action'));
        expect((p.side, p.align), (DifySide.bottom, DifyAlign.end));
        expect(allByRole(SemanticsRole.menu), hasLength(1));
        expect(byRole(SemanticsRole.menuItem, 'Content action'), isNotNull);
        final popup = t.getRect(find.byType(DifyMenuPopup));
        final trigger = t.getRect(find.byType(DifyButton));
        expect(popup.top, trigger.bottom + 4);
        expect(popup.right, trigger.right);
        semantics.dispose();
      });

      testWidgets('should apply custom placement when custom positioning props are provided', (t) async {
        await renderWithSafeViewport(
          t,
          const DifyDropdownMenu(
            open: true,
            placement: DifyPlacement.topStart,
            sideOffset: 12,
            alignOffset: -3,
            builder: _trigger,
            children: [DifyMenuItem(child: Text('Custom content'))],
          ),
        );
        final p = positioner(t, find.text('Custom content'));
        expect((p.side, p.align), (DifySide.top, DifyAlign.start));
        final popup = t.getRect(find.byType(DifyMenuPopup));
        final trigger = t.getRect(find.byType(DifyButton));
        expect(popup.bottom, trigger.top - 12);
        expect(popup.left, trigger.left - 3);
      });

      testWidgets('should support explicit anatomy when the positioner needs custom props', (t) async {
        // The positioner's props are DifyDropdownMenu's; the popup surface is DifyMenuPopup.
        await renderWithSafeViewport(
          t,
          const DifyDropdownMenu(
            open: true,
            placement: DifyPlacement.topStart,
            builder: _trigger,
            children: [DifyMenuItem(child: Text('Anatomy action'))],
          ),
        );
        expect(positioner(t, find.text('Anatomy action')).side, DifySide.top);
        expect(find.text('Anatomy action'), findsOneWidget);
      });
    });

    group('DropdownMenuSubContent', () {
      testWidgets('should position sub-content at left-start with default placement when props are omitted', (t) async {
        final semantics = t.ensureSemantics();
        // The test font draws every glyph a full em wide, so the safe viewport needs more room on the left.
        await renderWithSafeViewport(
          t,
          padding: const EdgeInsets.fromLTRB(480, 240, 240, 240),
          const DifyDropdownMenu(
            open: true,
            builder: _trigger,
            children: [
              DifyMenuSubmenu(
                open: true,
                label: Text('More actions'),
                children: [DifyMenuItem(child: Text('Sub action'))],
              ),
            ],
          ),
        );
        await t.pump(const Duration(milliseconds: 200));
        final p = positioner(t, find.text('Sub action'));
        expect((p.side, p.align), (DifySide.left, DifyAlign.start));
        expect(byRole(SemanticsRole.menu, 'More actions'), isNotNull);
        expect(byRole(SemanticsRole.menuItem, 'Sub action'), isNotNull);
        semantics.dispose();
      });

      testWidgets('should apply custom placement and forward popup props for sub-content', (t) async {
        await render(
          t,
          const DifyDropdownMenu(
            open: true,
            builder: _trigger,
            children: [
              DifyMenuSubmenu(
                open: true,
                placement: DifyPlacement.rightEnd,
                sideOffset: 6,
                alignOffset: 2,
                label: Text('More actions'),
                children: [DifyMenuItem(child: Text('Custom sub action'))],
              ),
            ],
          ),
        );
        await t.pump(const Duration(milliseconds: 200));
        final p = positioner(t, find.text('Custom sub action'));
        expect((p.side, p.align), (DifySide.right, DifyAlign.end));
        final row = t.getRect(find.ancestor(of: find.text('More actions'), matching: find.byType(Container)).first);
        final sub = t.getRect(
          find.ancestor(of: find.text('Custom sub action'), matching: find.byType(DifyMenuPopup)).first,
        );
        expect(sub.left, row.right + 6);
        expect(sub.bottom, row.bottom - 2);
      });
    });

    group('DropdownMenuSubTrigger', () {
      testWidgets('should render submenu trigger content when trigger children are provided', (t) async {
        final semantics = t.ensureSemantics();
        await render(
          t,
          const DifyDropdownMenu(
            open: true,
            builder: _trigger,
            children: [DifyMenuSubmenu(open: true, label: Text('Trigger item'), children: [])],
          ),
        );
        expect(byRole(SemanticsRole.menuItem, 'Trigger item'), isNotNull);
        semantics.dispose();
      });

      testWidgets('should remain interactive and set data-variant on submenu trigger when variant is %s', (t) async {
        for (final variant in DifyMenuItemVariant.values) {
          var opened = 0;
          await render(
            t,
            DifyDropdownMenu(
              open: true,
              builder: _trigger,
              children: [
                DifyMenuSubmenu(
                  variant: variant,
                  onOpenChange: (open) => opened += open ? 1 : 0,
                  label: const Text('Trigger item'),
                  children: const [DifyMenuItem(child: Text('Sub action'))],
                ),
              ],
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

    group('DropdownMenuItem', () {
      testWidgets('should remain interactive and set data-variant when variant is %s', (t) async {
        for (final variant in DifyMenuItemVariant.values) {
          final semantics = t.ensureSemantics();
          var clicks = 0;
          await render(
            t,
            DifyDropdownMenu(
              open: true,
              builder: _trigger,
              children: [
                DifyMenuItem(
                  variant: variant,
                  semanticLabel: 'menu action',
                  onSelect: () => clicks++,
                  child: const Text('Item label'),
                ),
              ],
            ),
          );
          expect(byRole(SemanticsRole.menuItem, 'menu action'), isNotNull);
          await t.tap(find.text('Item label'));
          expect(clicks, 1);
          expect(
            DefaultTextStyle.of(t.element(find.text('Item label'))).style.color,
            variant == DifyMenuItemVariant.destructive ? DifyColors.textDestructive : DifyColors.textSecondary,
          );
          semantics.dispose();
          await t.pumpWidget(const SizedBox());
          await t.pump();
        }
      });
    });

    group('DropdownMenuSeparator', () {
      testWidgets('should keep surrounding menu rows rendered when separator is placed between items', (t) async {
        await render(
          t,
          const DifyDropdownMenu(
            open: true,
            builder: _trigger,
            children: [
              DifyMenuItem(child: Text('First action')),
              DifyMenuSeparator(),
              DifyMenuItem(child: Text('Second action')),
            ],
          ),
        );
        expect(find.text('First action'), findsOneWidget);
        expect(find.text('Second action'), findsOneWidget);
        expect(find.byType(DifyMenuSeparator), findsOneWidget);
      });
    });
  });
}
