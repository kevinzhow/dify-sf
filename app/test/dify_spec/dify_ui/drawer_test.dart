// dify-spec: packages/dify-ui/src/drawer/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/design/css_metrics.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  testWidgets('default right drawer leaves the reference 32px viewport gutter as the viewport changes', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 640);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: DifyButton(
              onPressed: () => showDifyDrawer<void>(
                context,
                builder: (_, close) => DifyDrawerPopup(
                  child: DifyDrawerCloseButton(onPressed: close),
                ),
              ),
              child: const DifyTextLine('Open drawer'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Open drawer'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(t.getRect(find.byType(DifyDrawerPopup)), const Rect.fromLTWH(32, 0, 288, 640));
    t.view.physicalSize = const Size(800, 640);
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(DifyDrawerPopup)), const Rect.fromLTWH(320, 0, 480, 640));
    t.view.physicalSize = const Size(320, 640);
    await t.pumpAndSettle();
    await t.tapAt(const Offset(16, 320));
    await t.pumpAndSettle();
    expect(find.byType(DifyDrawerPopup), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('default right drawer has no border on its attached edge', (t) async {
    await t.pumpWidget(const MaterialApp(home: DifyDrawerPopup(child: SizedBox.expand())));
    final box = t.widget<Container>(
      find.descendant(of: find.byType(DifyDrawerPopup), matching: find.byType(Container)).first,
    );
    final border = (box.decoration! as BoxDecoration).border! as Border;
    expect(border.left.width, Css.hairline);
    expect(border.top.width, Css.hairline);
    expect(border.bottom.width, Css.hairline);
    expect(border.right, BorderSide.none);
    expect(t.takeException(), isNull);
  });

  testWidgets('inset drawer keeps its explicit gutter and border when the keyboard opens', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 640);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    final border = Border.all(color: DifyColors.dividerSubtle, width: Css.hairline);
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => DifyButton(
            onPressed: () => showDifyDrawer<void>(
              context,
              insets: const EdgeInsets.fromLTRB(8, 64, 8, 12),
              maxWidth: 640,
              viewportGutter: 16,
              builder: (_, close) => DifyDrawerPopup(
                border: border,
                borderRadius: BorderRadius.circular(DifyRadius.xl),
                child: DifyDrawerCloseButton(onPressed: close),
              ),
            ),
            child: const DifyTextLine('Open inset drawer'),
          ),
        ),
      ),
    );
    await t.tap(find.text('Open inset drawer'));
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(DifyDrawerPopup)), const Rect.fromLTWH(8, 64, 304, 564));
    final box = t.widget<Container>(
      find.descendant(of: find.byType(DifyDrawerPopup), matching: find.byType(Container)).first,
    );
    expect((box.decoration! as BoxDecoration).border, border);
    t.view.viewInsets = const FakeViewPadding(bottom: 100);
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(DifyDrawerPopup)), const Rect.fromLTWH(8, 64, 304, 464));
    await t.tap(find.bySemanticsLabel('Close drawer'));
    await t.pumpAndSettle();
    expect(find.byType(DifyDrawerPopup), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('a portalled drawer supplies Dify typography without a Material page ancestor', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: DifyButton(
              onPressed: () => showDifyDrawer<void>(
                context,
                builder: (_, close) => DifyDrawerPopup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const DifyTextLine('Plain output'),
                      DifyDrawerCloseButton(onPressed: close),
                    ],
                  ),
                ),
              ),
              child: const DifyTextLine('Open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    final context = t.element(find.widgetWithText(DifyTextLine, 'Plain output'));
    final style = DefaultTextStyle.of(context).style;
    expect(style.fontSize, DifyType.systemSmRegular.style.fontSize);
    expect(style.color, DifyColors.textPrimary);
    expect(style.decoration, TextDecoration.none);
    await t.tap(find.bySemanticsLabel('Close drawer'));
    await t.pumpAndSettle();
  });
  group('Drawer wrapper', () {
    group('User Interactions', () {
      testWidgets('should open a portalled drawer and close it with the default close button', (t) async {
        final semantics = t.ensureSemantics();
        await render(
          t,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDifyDrawer<void>(
                context,
                builder: (context, close) => DifyDrawerPopup(
                  label: 'Settings',
                  scopesRoute: true,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Settings'),
                        const Text('Configure the current workspace.'),
                        const Text('Workspace controls'),
                        DifyDrawerCloseButton(onPressed: close),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        );
        expect(allByRole(SemanticsRole.dialog), isEmpty);

        await t.tap(find.text('Open settings'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));

        // In the overlay (the portal), not below the trigger.
        expect(allByRole(SemanticsRole.dialog), hasLength(1));
        expect(find.ancestor(of: find.text('Workspace controls'), matching: find.byType(TextButton)), findsNothing);
        expect(find.text('Workspace controls'), findsOneWidget);
        expect(find.text('Configure the current workspace.'), findsOneWidget);
        // The backdrop: the route's modal barrier.
        expect(find.byType(ModalBarrier), findsWidgets);

        await t.tap(find.bySemanticsLabel('Close drawer'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(allByRole(SemanticsRole.dialog), isEmpty);
        expect(find.text('Workspace controls'), findsNothing);
        semantics.dispose();
      });
    });
  });
}
