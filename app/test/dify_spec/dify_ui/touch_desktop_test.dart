// dify-sf's touch desktop (batch 5, no Dify spec): the layout mode from the window's width class and the input mode,
// the touch sizes it switches on in wider windows, the side form of a sheet (DifySidePanel, DifySideDock), the bars'
// rail form, the dense app bar and the width cap of a sheet in a wide window.
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/foundation.dart';

import 'phone_harness.dart';

Future<T> _read<T>(WidgetTester t, T Function(BuildContext context) read, {Widget Function(Widget)? wrap}) async {
  late T value;
  final probe = Builder(
    builder: (context) {
      value = read(context);
      return const SizedBox();
    },
  );
  await t.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(t.view),
      child: Directionality(textDirection: TextDirection.ltr, child: wrap?.call(probe) ?? probe),
    ),
  );
  return value;
}

void main() {
  setUpAll(() => DifyI18n.load('en-US'));

  group('DifyLayoutMode', () {
    testWidgets('compact is the phone whatever the input; wider windows follow the input', (t) async {
      for (final (size, mode, expected) in const [
        (Size(411, 914), DifyInteractionMode.touch, DifyLayoutMode.phone),
        (Size(411, 914), DifyInteractionMode.pointer, DifyLayoutMode.phone),
        (Size(914, 411), DifyInteractionMode.touch, DifyLayoutMode.touch),
        (Size(800, 1280), DifyInteractionMode.touch, DifyLayoutMode.touch),
        (Size(1280, 800), DifyInteractionMode.touch, DifyLayoutMode.touch),
        (Size(914, 411), DifyInteractionMode.pointer, DifyLayoutMode.desktop),
        (Size(800, 1280), DifyInteractionMode.pointer, DifyLayoutMode.desktop),
        (Size(1280, 800), DifyInteractionMode.pointer, DifyLayoutMode.desktop),
      ]) {
        phoneView(t, size: size);
        DifyInteraction.debugDefault = mode;
        expect(await _read(t, DifyLayoutMode.of), expected, reason: '$size $mode');
        expect(await _read(t, DifyTouch.compactOf), expected != DifyLayoutMode.desktop, reason: '$size $mode');
      }
    });

    testWidgets('short: below 480 dp tall (a landscape phone), not a landscape tablet', (t) async {
      phoneView(t, size: const Size(914, 411));
      expect(await _read(t, DifyWindowClass.shortOf), isTrue);
      phoneView(t, size: const Size(780, 360));
      expect(await _read(t, DifyWindowClass.shortOf), isTrue);
      phoneView(t, size: const Size(1280, 800));
      expect(await _read(t, DifyWindowClass.shortOf), isFalse);
    });

    testWidgets('a DifyInteractionScope overrides the default', (t) async {
      phoneView(t, size: const Size(1280, 800));
      DifyInteraction.debugDefault = DifyInteractionMode.pointer;
      expect(
        await _read(
          t,
          DifyLayoutMode.of,
          wrap: (c) => DifyInteractionScope(mode: DifyInteractionMode.touch, child: c),
        ),
        DifyLayoutMode.touch,
      );
    });

    testWidgets('without an override the platform decides: Android, iOS and Fuchsia are touch', (t) async {
      DifyInteraction.debugDefault = null;
      phoneView(t, size: const Size(1280, 800));
      late DifyInteractionMode mode;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              mode = DifyInteraction.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      final touch = switch (defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
        _ => false,
      };
      expect(mode, touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer);
    }, variant: TargetPlatformVariant.all());
  });

  group('touch sizes in a wider window', () {
    Widget form() => Builder(
      builder: (context) => DifyButton(
        onPressed: () => showDifyDialog<void>(
          context,
          builder: (_) => DifyDialogSurface(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DifyButton(key: const ValueKey('in-dialog'), onPressed: () {}, child: const DifyTextLine('Save')),
                const DifyKbd('K'),
              ],
            ),
          ),
        ),
        child: const DifyTextLine('Open'),
      ),
    );

    for (final touch in [true, false]) {
      testWidgets(
        '800x1280 ${touch ? 'touch' : 'mouse'}: a dialog stays a dialog; ${touch ? 'its buttons are touch '
                  'high, no keycaps' : 'Dify\'s sizes and keycaps'}',
        (t) async {
          phoneView(t, size: const Size(800, 1280));
          DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
          await pumpPhoneApp(t, Center(child: form()));
          await t.tap(find.text('Open'));
          await t.pumpAndSettle();
          expect(find.byType(DraggableScrollableSheet), findsNothing, reason: 'width decides the form, not input');
          expect(find.byType(DifyDialogSurface), findsOneWidget);
          expect(t.getSize(find.byKey(const ValueKey('in-dialog'))).height, touch ? 44 : 32);
          expect(find.text('K'), touch ? findsNothing : findsOneWidget);
        },
      );
    }

    testWidgets('a row with actions: the "…" and the action sheet on a touch tablet, Dify\'s row with a mouse', (
      t,
    ) async {
      for (final touch in [true, false]) {
        phoneView(t, size: const Size(1280, 800));
        DifyInteraction.debugDefault = touch ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
        await pumpPhoneApp(
          t,
          Center(
            child: SizedBox(
              width: 400,
              child: DifyActionRow(
                label: 'Row',
                actions: [DifyActionRow.edit(() {})],
                child: const DifyTextLine('Row'),
              ),
            ),
          ),
        );
        final more = find.byWidgetPredicate((w) => w is DifyTouchIconButton);
        expect(more, touch ? findsOneWidget : findsNothing);
        await t.pumpWidget(const SizedBox());
      }
    });
  });

  group('DifySidePanel and DifySideDock', () {
    Widget dock({required bool open, VoidCallback? onDismiss}) => DifySideDock(
      open: open,
      body: Builder(
        builder: (context) => Align(
          alignment: Alignment.topRight,
          child: SizedBox.square(
            key: const ValueKey('body-corner'),
            dimension: 10,
            child: DifyText('${MediaQuery.paddingOf(context).right}', DifyType.systemXsRegular),
          ),
        ),
      ),
      panels: [
        if (open)
          DifySidePanel(
            key: const ValueKey('panel'),
            onDismiss: onDismiss,
            child: Builder(
              builder: (context) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DifySheetHeader(title: 'Settings', actions: const []),
                  DifyText(
                    'in sheet: ${DifySheetRecipe.contains(context)}',
                    DifyType.systemXsRegular,
                    key: const ValueKey('contains'),
                  ),
                  const Spacer(),
                  const SizedBox(key: ValueKey('panel-bottom'), height: 1),
                ],
              ),
            ),
          ),
      ],
    );

    testWidgets('914x411: the panel docks at the end, 360 wide, clear of the end and bottom insets', (t) async {
      phoneView(t, size: const Size(914, 411), padding: const EdgeInsets.only(top: 24, right: 48, bottom: 16));
      var dismissed = 0;
      await pumpPhoneApp(t, dock(open: true, onDismiss: () => dismissed++), edgeToEdge: true);
      final panel = t.getRect(find.byKey(const ValueKey('panel')));
      expect(panel.width, 360);
      expect(panel.right, 914);
      expect(panel.top, 0);
      expect(panel.bottom, 411);
      // The body keeps the rest and no longer reserves the end inset (the panel has it).
      expect(t.getRect(find.byKey(const ValueKey('body-corner'))).right, 914 - 360);
      expect(find.text('0.0'), findsOneWidget);
      // Content: laid out as a sheet's, above the bottom inset, its close the header's 44 px touch button.
      expect(find.text('in sheet: true'), findsOneWidget);
      expect(t.getRect(find.byKey(const ValueKey('panel-bottom'))).bottom, 411 - 16);
      final close = find.byType(DifyTouchIconButton);
      expect(close, findsOneWidget);
      expect(t.getRect(close).right, lessThanOrEqualTo(914 - 48));
      await t.tap(close);
      expect(dismissed, 1);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
    });

    testWidgets('closed: the body takes the whole width with its insets; no close without onDismiss', (t) async {
      phoneView(t, size: const Size(1280, 800), padding: const EdgeInsets.only(right: 48));
      await pumpPhoneApp(t, dock(open: false), edgeToEdge: true);
      expect(t.getRect(find.byKey(const ValueKey('body-corner'))).right, 1280);
      expect(find.text('48.0'), findsOneWidget);
      await pumpPhoneApp(t, dock(open: true), edgeToEdge: true);
      expect(t.getRect(find.byKey(const ValueKey('panel'))).width, 420, reason: 'a tablet: 40 % up to 420');
      expect(find.byType(DifyTouchIconButton), findsNothing);
    });

    test('width: 360 when short, else 40 % between 360 and 420', () {
      expect(DifySidePanel.widthFor(const Size(914, 411)), 360);
      expect(DifySidePanel.widthFor(const Size(780, 360)), 360);
      expect(DifySidePanel.widthFor(const Size(800, 1280)), 360);
      expect(DifySidePanel.widthFor(const Size(1000, 800)), 400);
      expect(DifySidePanel.widthFor(const Size(1280, 800)), 420);
    });
  });

  group('rail and dense bar', () {
    testWidgets('a toolbar as a rail: the start edge, clear of the start and bottom insets, scrolling', (t) async {
      phoneView(t, size: const Size(780, 360), padding: const EdgeInsets.only(left: 32, top: 24, bottom: 16));
      var undone = 0;
      await pumpPhoneApp(
        t,
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DifyBottomToolbar(
              key: const ValueKey('rail'),
              vertical: true,
              actions: [
                for (final l in ['Undo', 'Redo', 'Note', 'Versions'])
                  DifyToolbarAction(
                    icon: const RemixIcon('add-line', size: 22),
                    label: l,
                    onTap: l == 'Undo' ? () => undone++ : null,
                  ),
              ],
              center: DifyFab(icon: const RemixIcon('add-line', size: 28), label: 'Add', onPressed: () {}),
            ),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
        edgeToEdge: true,
      );
      final rail = t.getRect(find.byKey(const ValueKey('rail')));
      expect(rail.left, 0);
      expect(rail.width, DifyBottomToolbar.railWidth + 32);
      expect(rail.height, 360);
      final undo = t.getRect(find.text('Undo'));
      expect(undo.left, greaterThanOrEqualTo(32));
      // Each cell is a whole touch target at least 56 px tall.
      final cell = find.ancestor(of: find.text('Undo'), matching: find.byType(DifyToolbarAction));
      expect(t.getSize(cell).height, greaterThanOrEqualTo(56));
      expect(t.getSize(cell).width, DifyBottomToolbar.railWidth);
      await t.tap(find.text('Undo'));
      expect(undone, 1);
      // 4 cells and the Add button do not fit 360 - 16 dp: the rail scrolls to the last one, above the bottom inset.
      await t.ensureVisible(find.text('Versions'));
      await t.pumpAndSettle();
      expect(t.getRect(find.text('Versions')).bottom, lessThanOrEqualTo(360 - 16));
      expect(t.takeException(), isNull);
    });

    testWidgets('a selection bar as a rail: close on top, the title, the actions', (t) async {
      phoneView(t, size: const Size(914, 411));
      var closed = 0;
      await pumpPhoneApp(
        t,
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DifySelectionBar(
              vertical: true,
              title: 'Post-process',
              subtitle: 'Selected',
              onClose: () => closed++,
              actions: [
                DifyToolbarAction(icon: const RemixIcon('settings-3-line', size: 22), label: 'Settings', onTap: () {}),
              ],
            ),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      );
      expect(find.text('Post-process'), findsOneWidget);
      final close = find.bySemanticsLabel(DifyI18n.tr('common', 'operation.close'));
      expect(t.getSize(close).height, greaterThanOrEqualTo(48));
      await t.tap(close);
      expect(closed, 1);
      expect(t.getRect(find.text('Settings')).top, greaterThan(t.getRect(find.text('Post-process')).bottom));
      expect(t.takeException(), isNull);
    });

    testWidgets('a dense app bar is 48 dp under the status bar; its buttons keep 48 dp targets', (t) async {
      phoneView(t, size: const Size(914, 411), padding: const EdgeInsets.only(top: 24));
      var tapped = 0;
      await pumpPhoneApp(
        t,
        Column(
          children: [
            DifyTopAppBar(
              key: const ValueKey('bar'),
              title: 'App',
              dense: true,
              actions: [
                DifyTouchIconButton(
                  label: 'More',
                  icon: const RemixIcon('more-fill', size: 22),
                  onPressed: () => tapped++,
                ),
              ],
            ),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
        edgeToEdge: true,
      );
      expect(t.getRect(find.byKey(const ValueKey('bar'))).height, DifyTopAppBar.denseHeight + 24);
      final more = t.getRect(find.byType(DifyTouchIconButton));
      // A tap 2 px above the 44 px button (inside its 48 px target, inside the bar) reaches it.
      await t.tapAt(Offset(more.center.dx, more.top - 1.5));
      expect(tapped, 1);
    });
  });

  group('sheet width', () {
    for (final (size, width) in const [(Size(411, 914), 411.0), (Size(1280, 800), DifySheetRecipe.maxWidth)]) {
      testWidgets('${size.width.toInt()} wide: a modal sheet is $width wide, centred', (t) async {
        phoneView(t, size: size);
        await pumpPhoneApp(
          t,
          Builder(
            builder: (context) => Center(
              child: DifyButton(
                onPressed: () => showDifyBottomSheet<void>(
                  context,
                  (_) => const SizedBox(height: 200, child: DifyTextLine('Sheet')),
                ),
                child: const DifyTextLine('Open'),
              ),
            ),
          ),
        );
        await t.tap(find.text('Open'));
        await t.pumpAndSettle();
        final sheet = t.getRect(find.byType(DraggableScrollableSheet));
        expect(sheet.width, width);
        expect(sheet.center.dx, size.width / 2);
      });
    }
  });
}
