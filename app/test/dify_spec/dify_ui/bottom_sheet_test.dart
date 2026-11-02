// dify-sf phone layout (no Dify spec): bottom sheets on smooth_sheets (mockups 4-7).
import 'dart:async';

import 'phone_harness.dart';

const _h = 915.0;

Widget _list(BuildContext context, {Widget? field}) => Column(
  children: [
    const DifySheetHeader(title: 'Summarize', subtitle: 'LLM'),
    Expanded(
      child: ListView(
        children: [
          ?field,
          for (var i = 0; i < 40; i++) SizedBox(height: 48, child: DifyTextLine('Row $i')),
        ],
      ),
    ),
  ],
);

double _top(WidgetTester t) => t.getRect(find.byType(DifySheetGrabHandle)).top;

void main() {
  group('showDifyBottomSheet', () {
    testWidgets('opens at half, snaps to full, and a drag down below it dismisses', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      final result = showDifyBottomSheet<String>(
        nav.currentContext!,
        _list,
        detents: const [DifySheetDetent.half, DifySheetDetent.full],
      );
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h / 2, 0.5));
      final sheet = t.getRect(
        find.ancestor(of: find.byType(DifySheetGrabHandle), matching: find.byType(ClipRRect)).first,
      );
      expect(sheet.bottom, greaterThanOrEqualTo(_h), reason: 'the surface reaches the bottom edge (its rest is below)');
      expect(find.text('Summarize'), findsOneWidget);

      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, -300));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(0, 0.5), reason: 'released nearer full than half');

      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 300));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h / 2, 0.5), reason: 'released nearer half');

      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 250));
      await t.pumpAndSettle();
      expect(find.byType(DifySheetGrabHandle), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('a peek sheet stays open for a small drag below it', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      showDifyBottomSheet<void>(
        nav.currentContext!,
        _list,
        detents: const [DifySheetDetent.peek(160), DifySheetDetent.full],
      );
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h - 160, 0.5));
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 30));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h - 160, 0.5));
    });

    testWidgets('the scrim uses the sheet token; a scrim tap and the system back close the sheet', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      var result = showDifyBottomSheet<String>(nav.currentContext!, _list, detents: const [DifySheetDetent.half]);
      await t.pumpAndSettle();
      final barrier = t.widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier).last);
      expect(barrier.color.value, DifySheetRecipe.scrim);
      expect(DifySheetRecipe.scrim, DifyColors.backgroundOverlay.withValues(alpha: 0.28));
      await t.tapAt(const Offset(200, 100));
      await t.pumpAndSettle();
      expect(find.byType(DifySheetGrabHandle), findsNothing);
      expect(await result, isNull);

      result = showDifyBottomSheet<String>(nav.currentContext!, _list, detents: const [DifySheetDetent.half]);
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(DifySheetGrabHandle), findsNothing);
      expect(await result, isNull);
    });

    testWidgets('the header close pops the sheet; Escape too', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      showDifyBottomSheet<void>(nav.currentContext!, _list, detents: const [DifySheetDetent.half]);
      await t.pumpAndSettle();
      final close = find.bySemanticsLabel('operation.close');
      expect(t.getSize(close), const Size(44, 44));
      await t.tap(close);
      await t.pumpAndSettle();
      expect(find.byType(DifySheetGrabHandle), findsNothing);

      showDifyBottomSheet<void>(nav.currentContext!, _list, detents: const [DifySheetDetent.half]);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(DifySheetGrabHandle), findsNothing);
    });

    testWidgets('not dismissible: the scrim, a drag and back keep it; the content closes it', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      final result = showDifyBottomSheet<String>(
        nav.currentContext!,
        (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DifyButton(onPressed: () => Navigator.pop(context, 'saved'), child: const DifyTextLine('Save')),
            const SizedBox(height: 200),
          ],
        ),
        dismissible: false,
      );
      await t.pumpAndSettle();
      await t.tapAt(const Offset(200, 100));
      await t.binding.handlePopRoute();
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 400));
      await t.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(await result, 'saved');
    });

    testWidgets('not modal: no scrim, the page behind stays interactive', (t) async {
      phoneView(t);
      var taps = 0;
      final nav = await pumpPhoneApp(
        t,
        DifyPage(
          body: Align(
            alignment: Alignment.topLeft,
            child: DifyButton(onPressed: () => taps++, child: const DifyTextLine('Behind')),
          ),
        ),
      );
      showDifyBottomSheet<void>(
        nav.currentContext!,
        _list,
        detents: const [DifySheetDetent.peek(200)],
        modal: false,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Behind'));
      await t.pump();
      expect(taps, 1);
      expect(find.byType(DifySheetGrabHandle), findsOneWidget);
    });

    testWidgets('the keyboard lifts the sheet by its height and the focused field stays above it', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      showDifyBottomSheet<void>(
        nav.currentContext!,
        (context) => _list(context, field: const TextField(key: ValueKey('field'))),
        detents: const [DifySheetDetent.half, DifySheetDetent.full],
      );
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h / 2, 0.5));
      await t.tap(find.byKey(const ValueKey('field')));
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h / 2 - 300, 0.5));
      final field = t.getRect(find.byKey(const ValueKey('field')));
      expect(field.bottom, lessThanOrEqualTo(_h - 300));
      expect(field.top, greaterThanOrEqualTo(_top(t)));
      // Dragging the sheet down hides the keyboard.
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 40));
      await t.pump();
      expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isA<EditableText>()));
    });

    testWidgets('a toast shows over an open sheet', (t) async {
      phoneView(t);
      final toasts = DifyToastManager();
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()), toasts: toasts);
      showDifyBottomSheet<void>(nav.currentContext!, _list, detents: const [DifySheetDetent.full]);
      await t.pumpAndSettle();
      toasts.add(const DifyToastData(id: 'saved', title: 'Saved'));
      await t.pumpAndSettle();
      expect(find.text('Saved').hitTestable(), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('DifyPersistentSheet', () {
    testWidgets('rests at peek over an interactive page, moves with its controller, never closes', (t) async {
      phoneView(t);
      final controller = DifySheetController();
      addTearDown(controller.dispose);
      var taps = 0;
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: DifyButton(onPressed: () => taps++, child: const DifyTextLine('Behind')),
              ),
              DifyPersistentSheet(
                controller: controller,
                child: const Builder(builder: _list),
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h - 120, 0.5));
      expect(find.bySemanticsLabel('operation.close'), findsNothing, reason: 'no route to close');
      await t.tap(find.text('Behind'));
      expect(taps, 1);

      controller.animateTo(DifySheetDetent.full);
      await t.pumpAndSettle();
      expect(_top(t), closeTo(0, 0.5));
      expect(controller.offset, closeTo(_h, 0.5));

      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 900));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h - 120, 0.5));
    });
    testWidgets('dismissible: slides in over an interactive page, a drag down or dismiss() slides it away and calls '
        'onDismiss; an owner that keeps it sees it slide back', (t) async {
      phoneView(t);
      final controller = DifySheetController();
      addTearDown(controller.dispose);
      final shown = ValueNotifier(true);
      addTearDown(shown.dispose);
      var dismissed = 0, taps = 0;
      var keep = false;
      await pumpPhoneApp(
        t,
        DifyPage(
          body: ValueListenableBuilder(
            valueListenable: shown,
            builder: (context, on, _) => Stack(
              fit: StackFit.expand,
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: DifyButton(onPressed: () => taps++, child: const DifyTextLine('Behind')),
                ),
                if (on)
                  DifyPersistentSheet(
                    controller: controller,
                    slideIn: true,
                    detents: const [DifySheetDetent.half, DifySheetDetent.full],
                    onDismiss: () {
                      dismissed++;
                      if (!keep) shown.value = false;
                    },
                    child: const Builder(builder: _list),
                  ),
              ],
            ),
          ),
        ),
      );
      // It rises from the bottom edge to its first detent; the page behind stays interactive (no scrim).
      await t.pump();
      expect(_top(t), greaterThan(_h / 2 + 100));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h / 2, 0.5));
      expect(controller.detent, DifySheetDetent.half);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing);
      await t.tap(find.text('Behind'));
      expect(taps, 1);

      // A drag down below its lowest detent slides it away and calls onDismiss.
      final g = await t.startGesture(t.getCenter(find.byType(DifySheetGrabHandle)));
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(0, 20));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();
      expect(dismissed, 1);
      expect(find.byType(DifySheetGrabHandle), findsNothing);

      // dismiss() (what Back does); an owner that keeps the sheet sees it slide back to its detent.
      shown.value = true;
      await t.pumpAndSettle();
      keep = true;
      unawaited(controller.dismiss());
      await t.pumpAndSettle();
      expect(dismissed, 2);
      expect(_top(t), closeTo(_h / 2, 0.5));
      keep = false;
      unawaited(controller.dismiss());
      await t.pumpAndSettle();
      expect(dismissed, 3);
      expect(find.byType(DifySheetGrabHandle), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('content that gains its scroll view later keeps its state, and the sheet still moves', (t) async {
      phoneView(t);
      final controller = DifySheetController();
      addTearDown(controller.dispose);
      final loaded = ValueNotifier(false);
      addTearDown(loaded.dispose);
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Stack(
            fit: StackFit.expand,
            children: [
              DifyPersistentSheet(
                controller: controller,
                detents: const [DifySheetDetent.peek(120), DifySheetDetent.full],
                child: Column(
                  children: [
                    const _Counter(),
                    Expanded(
                      child: ValueListenableBuilder(
                        valueListenable: loaded,
                        builder: (context, on, _) => on
                            ? ListView(
                                children: [
                                  for (var i = 0; i < 40; i++) SizedBox(height: 48, child: DifyTextLine('Row $i')),
                                ],
                              )
                            : const Center(child: DifyTextLine('Loading')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('count 0'));
      await t.pump();
      expect(find.text('count 1'), findsOneWidget);
      loaded.value = true;
      await t.pump();
      // The frame the list appears in: moving the sheet waits for the anchor to go, it does not assert.
      unawaited(controller.animateTo(DifySheetDetent.full));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(0, 0.5));
      expect(find.text('count 1'), findsOneWidget, reason: 'the content kept its state');
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 900));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(_h - 120, 0.5));
      expect(t.takeException(), isNull);
    });
  });

  group('DifySheetHeader', () {
    testWidgets('leading, title, subtitle, actions and a tabs row over a divider', (t) async {
      await renderControl(
        t,
        DifySheetHeader(
          leading: const RemixIcon('sparkling-fill', size: 30),
          title: 'Summarize',
          subtitle: 'LLM',
          onClose: () {},
          actions: [DifyTouchIconButton(label: 'Run', icon: const RemixIcon('play-line', size: 20), onPressed: () {})],
          tabs: const SizedBox(height: 40, child: DifyTextLine('Settings')),
        ),
      );
      expect(find.text('Summarize'), findsOneWidget);
      expect(find.text('LLM'), findsOneWidget);
      expect(find.bySemanticsLabel('Run'), findsOneWidget);
      expect(find.bySemanticsLabel('operation.close'), findsOneWidget);
      final title = t.widget<RichText>(
        find.descendant(of: find.text('Summarize'), matching: find.byType(RichText)).first,
      );
      expect(title.text.style!.fontSize, 17);
      expect(find.text('Settings'), findsOneWidget);
    });
  });

  group('DifySheetDetent', () {
    test('compares by kind and height', () {
      expect(const DifySheetDetent.peek(120), const DifySheetDetent.peek(120));
      expect(const DifySheetDetent.peek(120), isNot(const DifySheetDetent.peek(160)));
      expect(DifySheetDetent.half, isNot(DifySheetDetent.full));
    });
  });
}

/// A tap counter: content state that must survive the sheet's anchor coming and going.
class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;
  @override
  Widget build(BuildContext context) =>
      DifyButton(onPressed: () => setState(() => _count++), child: DifyTextLine('count $_count'));
}
