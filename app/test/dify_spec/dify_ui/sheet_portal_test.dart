// dify-sf phone layout (no Dify spec), batch 4a: sheets and pages a widget shows from its own tree (they keep its
// inherited state), pickers as sheets in a compact window (the one switch: DifyFloating.sheetOnCompact), the touch
// box of a small control, and the sheet header's title widget.

import 'dart:async';

import 'package:dify_sf_app/src/design/dify_theme.dart';

import 'phone_harness.dart';

/// Something only the page provides: content shown from the page's tree must still see it.
class _PageScope extends InheritedWidget {
  const _PageScope({required this.value, required super.child});
  final String value;

  static String? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PageScope>()?.value;

  @override
  bool updateShouldNotify(_PageScope oldWidget) => value != oldWidget.value;
}

/// A page whose state owns a [DifySheetPortal]: [onDismiss] decides whether a request closes it.
class _PortalHost extends StatefulWidget {
  const _PortalHost({this.veto = false});
  final bool veto;

  @override
  State<_PortalHost> createState() => _PortalHostState();
}

class _PortalHostState extends State<_PortalHost> {
  bool open = false;
  int dismissals = 0;

  @override
  Widget build(BuildContext context) => _PageScope(
    value: 'editor scope',
    child: DifyPage(
      edgeToEdge: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: DifyButton(onPressed: () => setState(() => open = true), child: const DifyTextLine('Open')),
          ),
          DifySheetPortal(
            open: open,
            onDismiss: () {
              dismissals++;
              if (!widget.veto) setState(() => open = false);
            },
            builder: (context) => Column(
              children: [
                DifySheetHeader(title: 'Summarize', subtitle: 'LLM'),
                Expanded(
                  child: ListView(
                    children: [
                      DifyTextLine('scope: ${_PageScope.of(context)}'),
                      const DifyInput(key: ValueKey('field'), value: ''),
                      for (var i = 0; i < 30; i++) SizedBox(height: 48, child: DifyTextLine('Row $i')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The labels of the semantics tree as the platform gets it (traversal order: an overlay child counts under its
/// OverlayPortal's place, and is dropped when that place is), what TalkBack and uiautomator read.
List<String> _platformLabels(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder).forEach(walk);
  }

  for (final view in t.binding.renderViews) {
    if (view.owner?.semanticsOwner?.rootSemanticsNode case final root?) walk(root);
  }
  return out;
}

double _top(WidgetTester t) => t.getRect(find.byType(DifySheetGrabHandle)).top;

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  group('DifySheetPortal', () {
    testWidgets('opens over the whole window at half with the page\'s scopes; the scrim, back, Escape, the close '
        'button and a drag down ask the owner to close it', (t) async {
      phoneView(t, size: const Size(411, 914), padding: gestureInsets);
      await pumpPhoneApp(t, const _PortalHost(), edgeToEdge: true);
      final host = t.state<_PortalHostState>(find.byType(_PortalHost));
      Future<void> open() async {
        await t.tap(find.text('Open'));
        await _settle(t);
        expect(find.text('Summarize'), findsOneWidget);
      }

      await open();
      // Half the window above the gesture bar, the scrim over everything, the content inside the page's scopes.
      expect(_top(t), closeTo(914 / 2 - gestureInsets.bottom, 0.5));
      expect(t.getRect(find.byKey(const ValueKey('dify-sheet-scrim'))), Offset.zero & const Size(411, 914));
      expect(find.text('scope: editor scope'), findsOneWidget);

      await t.tapAt(const Offset(200, 100));
      await _settle(t);
      expect(find.text('Summarize'), findsNothing, reason: 'the scrim');
      await open();
      expect(await t.binding.handlePopRoute(), isTrue);
      await _settle(t);
      expect(find.text('Summarize'), findsNothing, reason: 'Android back');
      await open();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      expect(find.text('Summarize'), findsNothing, reason: 'Escape');
      await open();
      await t.tap(find.descendant(of: find.byType(DifySheetHeader), matching: find.byType(DifyTouchIconButton)));
      await _settle(t);
      expect(find.text('Summarize'), findsNothing, reason: 'the header\'s close');
      await open();
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 400));
      await t.pumpAndSettle();
      expect(find.text('Summarize'), findsNothing, reason: 'a drag down');
      expect(host.dismissals, 5);
    });

    testWidgets('is modal for accessibility, like a route: the sheet is in the semantics tree the platform gets, '
        'the page behind is not; the page comes back after closing', (t) async {
      final semantics = t.ensureSemantics();
      phoneView(t, size: const Size(411, 914), padding: gestureInsets);
      await pumpPhoneApp(t, const _PortalHost(), edgeToEdge: true);
      expect(_platformLabels(t), contains('Open'));
      await t.tap(find.text('Open'));
      await _settle(t);
      final open = _platformLabels(t);
      expect(open, contains(startsWith('Summarize')), reason: 'the sheet\'s header: $open');
      expect(open, contains('Row 0'), reason: 'the sheet\'s content: $open');
      expect(open, isNot(contains('Open')), reason: 'the page behind is blocked: $open');
      await t.binding.handlePopRoute();
      await _settle(t);
      final closed = _platformLabels(t);
      expect(closed, isNot(contains(startsWith('Summarize'))));
      expect(closed, contains('Open'), reason: 'the page is back: $closed');
      semantics.dispose();
    });

    testWidgets('pulled up it stops at the status bar; a vetoed close slides it back; the keyboard lifts it', (
      t,
    ) async {
      phoneView(t, size: const Size(411, 914), padding: gestureInsets);
      await pumpPhoneApp(t, const _PortalHost(veto: true), edgeToEdge: true);
      await t.tap(find.text('Open'));
      await _settle(t);
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, -500));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(gestureInsets.top, 0.5));
      // The owner keeps it open: back and a drag down leave it where it rests.
      expect(await t.binding.handlePopRoute(), isTrue);
      await _settle(t);
      expect(_top(t), closeTo(gestureInsets.top, 0.5));
      await t.drag(find.byType(DifySheetGrabHandle), const Offset(0, 120));
      await t.pumpAndSettle();
      expect(_top(t), closeTo(gestureInsets.top, 0.5));
      // The keyboard (Android: no bottom padding under it): the sheet ends on the keyboard, the field above it.
      await t.tap(find.byKey(const ValueKey('field')));
      phoneView(
        t,
        size: const Size(411, 914),
        padding: EdgeInsets.only(top: gestureInsets.top),
        viewPadding: gestureInsets,
        viewInsets: const EdgeInsets.only(bottom: 300),
      );
      await t.pumpAndSettle();
      final sheet = t.getRect(
        find.ancestor(of: find.byType(DifySheetGrabHandle), matching: find.byType(ClipRRect)).first,
      );
      expect(sheet.top, closeTo(gestureInsets.top, 0.5));
      expect(t.getRect(find.byKey(const ValueKey('field'))).bottom, lessThanOrEqualTo(914 - 300));
      expect(t.takeException(), isNull);
    });
  });

  group('DifyFloating.sheetOnCompact', () {
    Widget select() => _PageScope(
      value: 'page',
      child: DifyPage(
        body: Center(
          child: SizedBox(
            width: 200,
            child: DifySelect<String>(
              value: 'a',
              semanticLabel: 'Type',
              options: const [(value: 'a', label: 'Alpha'), (value: 'b', label: 'Beta'), (value: 'c', label: 'Gamma')],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    testWidgets('a compact window: a select opens as a titled sheet of 48 px rows; the trigger is touch-high', (
      t,
    ) async {
      phoneView(t, size: const Size(411, 914), padding: gestureInsets);
      await pumpPhoneApp(t, select());
      expect(t.getSize(find.byType(DifySelect<String>)).height, 44);
      await t.tap(find.text('Alpha'));
      await _settle(t);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsOneWidget);
      expect(find.text('Type'), findsOneWidget, reason: 'the sheet title');
      final row = find.ancestor(of: find.text('Beta'), matching: find.byType(Container)).first;
      expect(t.getSize(row).height, 48);
      expect(t.getSize(row).width, greaterThan(411 - 2 * 16), reason: 'the sheet\'s width, not the trigger\'s 200');
      expect(t.getRect(find.byType(DifySheetGrabHandle)).bottom, lessThan(914), reason: 'a sheet at the bottom');
      await t.tap(find.text('Beta'));
      await _settle(t);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing);
    });

    testWidgets('a wide window: the same select is the anchored popup it was', (t) async {
      phoneView(t, size: const Size(1280, 800));
      await pumpPhoneApp(t, select());
      expect(t.getSize(find.byType(DifySelect<String>)).height, 32);
      await t.tap(find.text('Alpha'));
      await _settle(t);
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing);
      final row = find.ancestor(of: find.text('Beta'), matching: find.byType(Container)).first;
      expect(t.getSize(row).height, 32);
    });

    testWidgets('a picker with a search field: the sheet takes the focus, not the field (no keyboard); the content '
        'knows it is in a sheet and keeps the trigger\'s scopes', (t) async {
      phoneView(t, size: const Size(411, 914), padding: gestureInsets);
      final search = FocusNode();
      addTearDown(search.dispose);
      bool? inSheet;
      await pumpPhoneApp(
        t,
        _PageScope(
          value: 'trigger scope',
          child: DifyPage(
            body: Center(
              child: DifyFloating(
                sheetOnCompact: true,
                sheetTitle: 'Insert variable',
                initialFocus: search,
                builder: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('Pick')),
                popupBuilder: (context) {
                  inSheet = DifyFloating.inSheet(context);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DifyInput(value: '', focusNode: search, placeholder: 'Search'),
                      DifyTextLine('scope: ${_PageScope.of(context)}'),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      final semantics = t.ensureSemantics();
      expect(_platformLabels(t), contains('Pick'));
      await t.tap(find.text('Pick'));
      await _settle(t);
      expect(inSheet, isTrue);
      // Modal for accessibility: the sheet in the platform's tree, the page (its trigger) not.
      expect(_platformLabels(t), contains('scope: trigger scope'));
      expect(_platformLabels(t), isNot(contains('Pick')));
      expect(find.text('Insert variable'), findsOneWidget);
      expect(find.text('scope: trigger scope'), findsOneWidget);
      expect(search.hasFocus, isFalse);
      expect(t.testTextInput.isVisible, isFalse);
      expect(await t.binding.handlePopRoute(), isTrue);
      await _settle(t);
      expect(find.text('Insert variable'), findsNothing, reason: 'back closed the sheet');
      expect(_platformLabels(t), contains('Pick'));
      semantics.dispose();
    });
  });

  testWidgets('a compact window: an action menu stays anchored (raft keeps menus); a menu of choices is a sheet', (
    t,
  ) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    String? picked;
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DifyDropdownMenu(
                builder: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('More')),
                children: [DifyMenuItem(onSelect: () {}, child: const DifyTextLine('Duplicate'))],
              ),
              DifyDropdownMenu(
                builder: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('Operator')),
                children: [
                  DifyMenuRadioGroup<String>(
                    value: 'is',
                    onValueChange: (v) => picked = v,
                    children: const [
                      DifyMenuRadioItem(value: 'is', closeOnClick: true, child: DifyTextLine('is')),
                      DifyMenuRadioItem(value: 'contains', closeOnClick: true, child: DifyTextLine('contains')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('More'));
    await _settle(t);
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing, reason: 'an action menu is anchored');
    expect(find.byType(DifyFloatingLayout), findsOneWidget);
    await t.binding.handlePopRoute();
    await _settle(t);
    await t.tap(find.text('Operator'));
    await _settle(t);
    expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsOneWidget, reason: 'a menu of choices is a picker');
    expect(t.getSize(find.ancestor(of: find.text('contains'), matching: find.byType(Container)).first).height, 48);
    await t.tap(find.text('contains'));
    await _settle(t);
    expect(picked, 'contains');
  });

  testWidgets('DifyTouchArea: a 24 px button in a 24 px row gets a 48 px box and the taps in it', (t) async {
    phoneView(t);
    var taps = 0;
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Align(
          alignment: Alignment.topLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DifyTouchArea(
                child: DifyIconButton(
                  key: const ValueKey('b'),
                  label: 'Add',
                  onPressed: () => taps++,
                  icon: const RemixIcon('add-line', size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final button = t.getRect(find.byKey(const ValueKey('b')));
    expect(button.size, const Size(24, 24));
    expect(t.getSize(find.byType(DifyTouchArea)), const Size(48, 48));
    await t.tapAt(button.center + const Offset(0, -23));
    await t.tapAt(button.center + const Offset(23, 0));
    await t.tapAt(button.center);
    expect(taps, 3);
  });

  testWidgets('DifySheetHeader: a title widget in the title\'s place (an editable title)', (t) async {
    phoneView(t);
    await pumpPhoneApp(
      t,
      const DifyPage(
        body: DifySheetHeader(
          title: 'Summarize',
          titleWidget: DifyInput(key: ValueKey('title'), value: 'Summarize'),
          subtitle: 'LLM',
          showClose: false,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('title')), findsOneWidget);
    expect(find.text('LLM'), findsOneWidget);
    expect(t.getRect(find.byKey(const ValueKey('title'))).bottom, lessThanOrEqualTo(t.getRect(find.text('LLM')).top));
  });

  testWidgets('DifyPortalPage: a full-screen page over the window with a back button; its content moves in and out '
      'with its state and keeps the page\'s scopes; back closes it', (t) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    final key = GlobalKey();
    final text = TextEditingController(text: 'def main(): pass');
    addTearDown(text.dispose);
    var open = false;
    late StateSetter set;
    Widget editor() => KeyedSubtree(
      key: key,
      child: Builder(
        builder: (context) => Column(
          children: [
            DifyTextLine('scope: ${_PageScope.of(context)}'),
            DifyTextField(controller: text),
          ],
        ),
      ),
    );
    await pumpPhoneApp(
      t,
      _PageScope(
        value: 'panel',
        child: DifyPage(
          edgeToEdge: true,
          body: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return DifyPortalPage(
                open: open,
                onClose: () => setState(() => open = false),
                title: 'Code',
                builder: (_) => editor(),
                child: open ? const SizedBox.shrink() : editor(),
              );
            },
          ),
        ),
      ),
      edgeToEdge: true,
    );
    final state = t.state(find.byType(EditableText));
    final semantics = t.ensureSemantics();
    set(() => open = true);
    await _settle(t);
    final page = find.byKey(const ValueKey('dify-portal-page'));
    expect(_platformLabels(t), contains(startsWith('Code')), reason: 'the page\'s app bar in the platform\'s tree');
    expect(_platformLabels(t), contains(contains('scope: panel')), reason: 'the page\'s content');
    semantics.dispose();
    expect(t.getRect(page), Offset.zero & const Size(411, 914));
    expect(find.descendant(of: page, matching: find.byType(DifyTopAppBar)), findsOneWidget);
    expect(find.descendant(of: page, matching: find.text('scope: panel')), findsOneWidget);
    expect(t.state(find.byType(EditableText)), same(state), reason: 'the same editor moved, with its state');
    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    expect(open, isFalse);
    expect(page, findsNothing);
    expect(t.state(find.byType(EditableText)), same(state));
    expect(t.takeException(), isNull);
  });

  testWidgets('buttons in a sheet are touch-high (44 px) in a compact window; outside a sheet, and in a sheet on a '
      'wide window, Dify\'s sizes', (t) async {
    Future<Map<String, double>> heights(Size size) async {
      phoneView(t, size: size);
      final nav = await pumpPhoneApp(
        t,
        DifyPage(
          body: Center(
            child: DifyButton(size: DifyButtonSize.small, onPressed: () {}, child: const DifyTextLine('Page')),
          ),
        ),
      );
      unawaited(
        showDifyBottomSheet<void>(
          nav.currentContext!,
          (_) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DifyButton(size: DifyButtonSize.small, onPressed: () {}, child: const DifyTextLine('Small')),
                DifyButton(onPressed: () {}, child: const DifyTextLine('Medium')),
                DifyButton(size: DifyButtonSize.large, onPressed: () {}, child: const DifyTextLine('Large')),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      double h(String text) => t.getSize(find.ancestor(of: find.text(text), matching: find.byType(DifyButton))).height;
      return {
        for (final b in ['Page', 'Small', 'Medium', 'Large']) b: h(b),
      };
    }

    expect(await heights(const Size(411, 914)), {'Page': 24, 'Small': 44, 'Medium': 44, 'Large': 44});
    expect(await heights(const Size(1280, 800)), {'Page': 24, 'Small': 24, 'Medium': 32, 'Large': 36});
  });

  testWidgets('text selection handles and the caret use Dify\'s accent, not the seed\'s indigo', (t) async {
    final theme = difyTheme();
    expect(theme.textSelectionTheme.selectionHandleColor, const Color(0xFF155EEF));
    expect(theme.textSelectionTheme.cursorColor, const Color(0xFF155EEF));
    phoneView(t);
    await pumpPhoneApp(
      t,
      const DifyPage(
        body: Center(
          child: DifyInput(key: ValueKey('f'), value: 'hello world'),
        ),
      ),
    );
    final context = t.element(find.byKey(const ValueKey('f')));
    expect(TextSelectionTheme.of(context).selectionHandleColor, const Color(0xFF155EEF));
    expect(difyTheme(brightness: Brightness.dark).textSelectionTheme.selectionHandleColor, const Color(0xFF155EEF));
  });
}
