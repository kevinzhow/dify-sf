// dify-spec: packages/dify-ui/src/popover/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/css_metrics.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _trigger(BuildContext context, DifyFloatingController c) =>
    DifyButton(onPressed: c.toggle, child: const Text('Open'));

void main() {
  group('PopoverContent', () {
    group('Popup props', () {
      testWidgets('should move focus to the requested initial target', (t) async {
        final target = FocusNode();
        addTearDown(target.dispose);
        await renderWithSafeViewport(
          t,
          DifyPopover(
            open: true,
            initialFocus: target,
            semanticLabel: 'Popover content',
            builder: _trigger,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Popover content'),
                DifyButton(focusNode: target, onPressed: () {}, child: const Text('Focus target')),
              ],
            ),
          ),
        );
        expect(target.hasFocus, isTrue);
      });
    });

    group('Animation', () {
      testWidgets('should restore focus without waiting for an instant close transition', (t) async {
        final content = FocusNode();
        final triggerNode = FocusNode();
        addTearDown(content.dispose);
        addTearDown(triggerNode.dispose);
        await renderWithSafeViewport(
          t,
          DifyPopover(
            builder: (context, c) => DifyButton(focusNode: triggerNode, onPressed: c.toggle, child: const Text('Open')),
            content: DifyButton(focusNode: content, onPressed: () {}, child: const Text('Focusable content')),
          ),
        );
        await t.tap(find.text('Open'));
        await t.pump();
        content.requestFocus();
        await t.pump();
        expect(content.hasFocus, isTrue);

        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        expect(triggerNode.hasFocus, isTrue);
        expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional, reason: 'focus-visible');
        expect(find.text('Focusable content'), findsNothing, reason: 'Escape closes instantly');
      });
    });

    group('Surface', () {
      testWidgets('should provide the default popover surface', (t) async {
        await renderWithSafeViewport(
          t,
          DifyPopover(
            open: true,
            semanticLabel: 'Default popover',
            builder: _trigger,
            content: const Text('Default content'),
          ),
        );
        expect(find.text('Default content'), findsOneWidget);
        final deco =
            t
                    .widget<Container>(
                      find.descendant(of: find.byType(DifyPopoverSurface), matching: find.byType(Container)),
                    )
                    .decoration!
                as BoxDecoration;
        expect((deco.border! as Border).top.width, Css.border(0.5)); // border-[0.5px], as Chrome snaps it
        expect((deco.border! as Border).top.color, DifyColors.componentsPanelBorder);
        expect(deco.borderRadius, BorderRadius.circular(12));
        expect(deco.color, DifyColors.componentsPanelBg);
        expect(deco.boxShadow, DifyShadows.lg);
      });
    });
  });

  group('Popover anatomy', () {
    testWidgets('should use the default positioner placement', (t) async {
      await renderWithSafeViewport(
        t,
        DifyPopover(open: true, surface: false, builder: _trigger, content: const Text('Default anatomy popover')),
      );
      final p = positioner(t, find.text('Default anatomy popover'));
      expect((p.side, p.align), (DifySide.bottom, DifyAlign.center));
    });

    testWidgets('should compose the portal, positioner, and popup directly', (t) async {
      final semantics = t.ensureSemantics();
      await renderWithSafeViewport(
        t,
        DifyPopover(
          open: true,
          surface: false,
          placement: DifyPlacement.topEnd,
          semanticLabel: 'Anatomy popover',
          builder: _trigger,
          content: const Text('Anatomy content'),
        ),
      );
      final p = positioner(t, find.text('Anatomy content'));
      expect((p.side, p.align), (DifySide.top, DifyAlign.end));
      expect(byRole(SemanticsRole.dialog, 'Anatomy popover'), isNotNull);
      // A bare popup: no border, radius, background, shadow or padding.
      expect(find.byType(DifyPopoverSurface), findsNothing);
      final popup = find.ancestor(of: find.text('Anatomy content'), matching: find.byType(DifyFloatingLayout));
      expect(find.descendant(of: popup, matching: find.byType(DecoratedBox)), findsNothing);
      expect(find.descendant(of: popup, matching: find.byType(Padding)), findsNothing);
      semantics.dispose();
    });
  });
}
