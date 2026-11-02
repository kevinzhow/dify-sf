// dify-sf phone layout (no Dify spec): the sheets on the framework's modal bottom sheet route and
// DraggableScrollableSheet (raft-flutter's pattern): detents, flicks, scroll hand-over and asking the route to close.
import 'package:flutter/gestures.dart' show PointerDeviceKind;

import 'phone_harness.dart';

const _h = 915.0;
const _list = ValueKey('list');

Widget _scrolling(BuildContext context) => Column(
  children: [
    const DifySheetHeader(title: 'Insert variable'),
    Expanded(
      child: ListView(
        key: _list,
        children: [for (var i = 0; i < 40; i++) SizedBox(height: 48, child: DifyTextLine('Row $i'))],
      ),
    ),
  ],
);

double _top(WidgetTester t) => t.getRect(find.byType(DifySheetGrabHandle)).top;

ScrollPosition _listPosition(WidgetTester t) =>
    t.state<ScrollableState>(find.descendant(of: find.byKey(_list), matching: find.byType(Scrollable))).position;

/// A finger (or [kind]) moving [dy] in small steps, as a real drag does: `WidgetTester.drag` sends one or two large
/// moves, and a scroll view hands a drag over to the sheet between events, not within one.
Future<void> _drag(WidgetTester t, Finder finder, double dy, {PointerDeviceKind kind = PointerDeviceKind.touch}) async {
  final gesture = await t.startGesture(t.getCenter(finder), kind: kind);
  const steps = 20;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, dy / steps));
    await t.pump(const Duration(milliseconds: 16));
  }
  // Held still before letting go: a drag, not a flick.
  await t.pump(const Duration(milliseconds: 200));
  await gesture.up();
  await t.pumpAndSettle();
}

Future<GlobalKey<NavigatorState>> _app(WidgetTester t, {Widget? home}) async {
  phoneView(t);
  return pumpPhoneApp(t, home ?? const DifyPage(body: SizedBox()));
}

/// Content that loads: no scroll view at first, then a list; counts how often its State is created.
class _Loading extends StatefulWidget {
  const _Loading(this.created);
  final List<int> created;
  @override
  State<_Loading> createState() => _LoadingState();
}

class _LoadingState extends State<_Loading> {
  bool loaded = false;
  @override
  void initState() {
    super.initState();
    widget.created.add(1);
    Future<void>.delayed(const Duration(milliseconds: 50), () {
      if (mounted) setState(() => loaded = true);
    });
  }

  @override
  Widget build(BuildContext context) => loaded
      ? ListView(
          primary: true,
          shrinkWrap: true,
          children: [for (var i = 0; i < 30; i++) SizedBox(height: 40, child: Text('row $i'))],
        )
      : const SizedBox(height: 80, child: Center(child: Text('loading')));
}

void main() {
  testWidgets('a modal sheet is the framework modal bottom sheet route with draggable detents', (t) async {
    final nav = await _app(t);
    showDifyBottomSheet<void>(nav.currentContext!, _scrolling);
    await t.pumpAndSettle();
    expect(ModalRoute.of(t.element(find.byType(DifySheetGrabHandle))), isA<ModalBottomSheetRoute<void>>());
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
  });

  testWidgets('content that gains a scroll view after loading keeps its State (no rebuild loop)', (t) async {
    final nav = await _app(t);
    final created = <int>[];
    showDifyBottomSheet<void>(nav.currentContext!, (_) => _Loading(created));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpAndSettle();
    expect(find.text('row 0'), findsOneWidget);
    expect(created.length, 1, reason: 'the scroll anchor coming and going must not recreate the content');
  });

  testWidgets('a persistent sheet is a draggable sheet without a route of its own', (t) async {
    await _app(
      t,
      home: const DifyPage(
        body: Stack(
          fit: StackFit.expand,
          children: [DifyPersistentSheet(child: Builder(builder: _scrolling))],
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(ModalRoute.of(t.element(find.byType(DifySheetGrabHandle))), isNot(isA<ModalBottomSheetRoute<void>>()));
  });

  testWidgets('released, the sheet settles on the nearest detent; flicked, on the next one', (t) async {
    final nav = await _app(t);
    final result = showDifyBottomSheet<void>(
      nav.currentContext!,
      _scrolling,
      detents: const [DifySheetDetent.peek(200), DifySheetDetent.half, DifySheetDetent.full],
    );
    await t.pumpAndSettle();
    expect(_top(t), closeTo(_h - 200, 0.5));
    final handle = find.byType(DifySheetGrabHandle);

    await t.drag(handle, const Offset(0, -150)); // 350 px: nearer half (457.5) than peek (200)
    await t.pumpAndSettle();
    expect(_top(t), closeTo(_h / 2, 0.5));

    await t.fling(handle, const Offset(0, -120), 1500); // up: still nearer half, flicked to the next detent above
    await t.pumpAndSettle();
    expect(_top(t), closeTo(0, 0.5));

    await t.fling(handle, const Offset(0, 120), 1500); // down: still nearer full, flicked to the next detent below
    await t.pumpAndSettle();
    expect(_top(t), closeTo(_h / 2, 0.5));

    await t.fling(handle, const Offset(0, 120), 1500);
    await t.pumpAndSettle();
    expect(_top(t), closeTo(_h - 200, 0.5));

    // From below the lowest detent, a flick down closes it.
    await t.fling(handle, const Offset(0, 100), 1500);
    await t.pumpAndSettle();
    expect(find.byType(DifySheetGrabHandle), findsNothing);
    await result;
  });

  testWidgets('a scroll view hands over to the sheet at its top, in both directions', (t) async {
    final nav = await _app(t);
    showDifyBottomSheet<void>(
      nav.currentContext!,
      _scrolling,
      detents: const [DifySheetDetent.half, DifySheetDetent.full],
    );
    await t.pumpAndSettle();
    expect(_top(t), closeTo(_h / 2, 0.5));

    // Up from half: the sheet grows first, the list does not scroll.
    await _drag(t, find.byKey(_list), -300);
    expect(_top(t), closeTo(0, 0.5));
    expect(_listPosition(t).pixels, 0);

    // At full the list scrolls; the sheet stays.
    await _drag(t, find.byKey(_list), -200);
    expect(_listPosition(t).pixels, greaterThan(150)); // 200 less the touch slop
    expect(_top(t), closeTo(0, 0.5));

    // Down: the list scrolls back to its top, then the sheet moves.
    await _drag(t, find.byKey(_list), 500);
    expect(_listPosition(t).pixels, 0);
    expect(_top(t), closeTo(_h / 2, 0.5));

    // Scrolled content never closes the sheet; pulled down from the top it does.
    await _drag(t, find.byKey(_list), 400);
    expect(find.byType(DifySheetGrabHandle), findsNothing);
  });

  testWidgets('a drag to the bottom asks the route: a PopScope veto slides the sheet back', (t) async {
    final nav = await _app(t);
    var vetoes = 0;
    showDifyBottomSheet<void>(
      nav.currentContext!,
      (context) => PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) => vetoes++,
        child: _scrolling(context),
      ),
      detents: const [DifySheetDetent.half, DifySheetDetent.full],
    );
    await t.pumpAndSettle();
    await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 400));
    await t.pumpAndSettle();
    expect(vetoes, 1);
    expect(_top(t), closeTo(_h / 2, 0.5));
  });

  testWidgets('content that does not scroll keeps its own height', (t) async {
    final nav = await _app(t);
    showDifyBottomSheet<void>(
      nav.currentContext!,
      (context) => const SizedBox(height: 200, child: DifyTextLine('Short')),
    );
    await t.pumpAndSettle();
    expect(_top(t), closeTo(_h - 20 - 200, 0.5));
  });

  testWidgets('a mouse drags the sheet by its handle and header, not by its body', (t) async {
    final nav = await _app(t);
    showDifyBottomSheet<void>(
      nav.currentContext!,
      (context) => const Column(
        children: [
          DifySheetHeader(title: 'Logs'),
          Expanded(child: SizedBox.expand(key: ValueKey('body'))),
        ],
      ),
      detents: const [DifySheetDetent.half, DifySheetDetent.full],
    );
    await t.pumpAndSettle();
    await _drag(t, find.byKey(const ValueKey('body')), -300, kind: PointerDeviceKind.mouse);
    expect(_top(t), closeTo(_h / 2, 0.5));
    await _drag(t, find.byType(DifySheetGrabHandle), -300, kind: PointerDeviceKind.mouse);
    expect(_top(t), closeTo(0, 0.5));
    await _drag(t, find.text('Logs'), 300, kind: PointerDeviceKind.mouse);
    expect(_top(t), closeTo(_h / 2, 0.5));
  });

  testWidgets(
    'on desktop the body scroll view keeps its own controller; the handle and the controller still move the sheet',
    (t) async {
      final nav = await _app(t);
      final controller = DifySheetController();
      addTearDown(controller.dispose);
      showDifyBottomSheet<void>(
        nav.currentContext!,
        _scrolling,
        detents: const [DifySheetDetent.half, DifySheetDetent.full],
        controller: controller,
      );
      await t.pumpAndSettle();
      expect(controller.isAttached, isTrue);
      await _drag(t, find.byKey(_list), -200);
      expect(_top(t), closeTo(_h / 2, 0.5), reason: 'the list scrolled itself');
      expect(_listPosition(t).pixels, greaterThan(150));
      await _drag(t, find.byType(DifySheetGrabHandle), -300);
      expect(_top(t), closeTo(0, 0.5));
      final moved = controller.animateTo(DifySheetDetent.half);
      await t.pumpAndSettle();
      await moved;
      expect(_top(t), closeTo(_h / 2, 0.5));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
