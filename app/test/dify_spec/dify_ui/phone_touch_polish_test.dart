// dify-sf phone layout (no Dify spec), polish after batch 4: the design's shared touch rules. In a sheet on a phone an
// icon button sits in a 44 px box that is also its accessible bounds (as a button there is touch-high); a hover or drag
// handle opts out; a phone's switch has such a box too, all of it hittable; a touch target can be the control's
// accessible bounds inside a box of its own (the touch segmented control's items); a button leaves hidden keycaps out
// of its row (the label stays centred); a field in a picker sheet does not take the focus at once; a sheet of choices
// marks the current one with DifyChoiceMark.
import 'dart:async';

import 'phone_harness.dart';

/// The semantics node control [f] forms (or is merged into) for the platform.
SemanticsNode _node(WidgetTester t, Finder f) {
  final queue = <RenderObject>[t.renderObject(f)];
  while (queue.isNotEmpty) {
    final r = queue.removeAt(0);
    if (r.debugSemantics case final n?) {
      var m = n;
      while (m.isMergedIntoParent && m.parent != null) {
        m = m.parent!;
      }
      return m;
    }
    r.visitChildren(queue.add);
  }
  return t.getSemantics(f);
}

/// [child] in a bottom sheet over a page, in a [size] window.
Future<void> _inSheet(WidgetTester t, Widget child, {Size size = const Size(411, 914)}) async {
  phoneView(t, size: size);
  final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox.expand()));
  unawaited(showDifyBottomSheet<void>(nav.currentContext!, (_) => Center(child: child)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('an icon button in a phone\'s sheet sits in a 44 px box that is its accessible bounds; on the page, in '
      'a wide window\'s sheet and with touchBox false it keeps Dify\'s size', (t) async {
    final semantics = t.ensureSemantics();
    Widget buttons() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DifyIconButton(label: 'Add', onPressed: () {}, icon: const RemixIcon('add-line', size: 16)),
        DifyIconButton(
          label: 'Drag',
          touchBox: false,
          onPressed: () {},
          icon: const RemixIcon('draggable', size: 12),
        ),
      ],
    );
    await _inSheet(t, buttons());
    expect(
      _node(t, find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'Add')).rect.size,
      const Size(44, 44),
    );
    expect(
      _node(t, find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'Drag')).rect.size,
      const Size(24, 24),
    );
    // The icon keeps Dify's 24 px button.
    expect(t.getSize(find.byType(DifyButtonSurface).first), const Size(24, 24));
    await _inSheet(t, buttons(), size: const Size(1280, 800));
    expect(
      _node(t, find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'Add')).rect.size,
      const Size(24, 24),
    );
    phoneView(t);
    await pumpPhoneApp(t, DifyPage(body: Center(child: buttons())));
    expect(
      _node(t, find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'Add')).rect.size,
      const Size(24, 24),
    );
    semantics.dispose();
  });

  testWidgets('a phone\'s switch sits in a 44 px box that is its accessible bounds and all of its hit area (a tap 2 dp '
      'inside each edge toggles it); its track stays 28 x 16', (t) async {
    final semantics = t.ensureSemantics();
    phoneView(t);
    var on = false;
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Center(
          // At the end of a row that ends at the switch (as a header's operations do).
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DifyTextLine('Retry'),
              StatefulBuilder(
                builder: (context, set) =>
                    DifySwitch(checked: on, semanticLabel: 'Retry', onCheckedChange: (v) => set(() => on = v)),
              ),
            ],
          ),
        ),
      ),
    );
    final node = _node(t, find.byType(DifySwitch));
    expect(node.rect.size, const Size(44, 44));
    expect(node.getSemanticsData().label, 'Retry');
    expect(t.getSize(find.byType(AnimatedContainer)), const Size(28, 16));
    final r = t.getRect(find.byType(DifySwitch));
    expect(r.size, const Size(44, 44));
    var taps = 0;
    for (final p in [
      r.center,
      Offset(r.center.dx, r.top + 2),
      Offset(r.center.dx, r.bottom - 2),
      Offset(r.left + 2, r.center.dy),
      Offset(r.right - 2, r.center.dy),
    ]) {
      await t.tapAt(p);
      await t.pumpAndSettle();
      taps++;
      expect(on, taps.isOdd, reason: 'a tap at $p in $r');
    }
    semantics.dispose();
  });

  testWidgets('the touch segmented control\'s items are 44 px tall nodes inside its 48 px box, all of them hittable', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    phoneView(t);
    var value = 0;
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Center(
          child: StatefulBuilder(
            builder: (context, set) => DifySegmentedControl<int>(
              value: value,
              size: DifySegmentedControlSize.touch,
              onChanged: (v) => set(() => value = v),
              segments: const [
                (value: 0, label: 'Steps', child: DifyTextLine('Steps')),
                (value: 1, label: 'Canvas', child: DifyTextLine('Canvas')),
              ],
            ),
          ),
        ),
      ),
    );
    for (final (i, label) in ['Steps', 'Canvas'].indexed) {
      final node = t.getSemantics(find.bySemanticsLabel(label));
      expect(node.rect.height, 44, reason: label);
      expect(node.rect.width, greaterThanOrEqualTo(44), reason: label);
      var r = node.rect;
      for (SemanticsNode? x = node; x != null; x = x.parent) {
        if (x.transform case final m?) r = MatrixUtils.transformRect(m, r);
      }
      for (final p in [
        Offset(r.center.dx, r.top + 2),
        Offset(r.center.dx, r.bottom - 2),
        Offset(r.left + 2, r.center.dy),
        Offset(r.right - 2, r.center.dy),
      ]) {
        // The other item chosen first, so the tap must choose this one.
        await t.tap(find.text(['Steps', 'Canvas'][1 - i]));
        await t.pumpAndSettle();
        expect(value, 1 - i);
        await t.tapAt(p);
        await t.pumpAndSettle();
        expect(value, i, reason: '$label: a tap at $p in $r');
      }
    }
    semantics.dispose();
  });

  testWidgets('a button leaves keycaps a phone does not show out of its row, with their gap: the label stays '
      'centred; a wide window shows them', (t) async {
    Widget publish() => DifyButton(
      variant: DifyButtonVariant.primary,
      onPressed: () {},
      trailing: const DifyKbdGroup(children: [DifyKbd('Ctrl'), DifyKbd('P')]),
      child: const DifyTextLine('Publish'),
    );
    phoneView(t);
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Center(child: SizedBox(width: 300, child: publish())),
      ),
    );
    expect(find.text('Ctrl'), findsNothing);
    expect(t.getCenter(find.text('Publish')).dx, closeTo(t.getCenter(find.byType(DifyButton)).dx, 0.01));
    phoneView(t, size: const Size(1280, 800));
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Center(child: SizedBox(width: 300, child: publish())),
      ),
    );
    expect(find.text('Ctrl'), findsOneWidget);
  });

  testWidgets('a field in a picker sheet does not take the focus at once (no keyboard over the list); in an anchored '
      'popup it does', (t) async {
    Widget picker() => DifyPopover(
      builder: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('Open')),
      content: const SizedBox(width: 200, child: DifyInput(value: '', autofocus: true)),
    );
    phoneView(t);
    await pumpPhoneApp(t, DifyPage(body: Center(child: picker())));
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    expect(find.byType(DifySheetGrabHandle), findsOneWidget);
    expect(t.testTextInput.isVisible, isFalse);
    phoneView(t, size: const Size(1280, 800));
    await pumpPhoneApp(t, DifyPage(body: Center(child: picker())));
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    expect(find.byType(DifySheetGrabHandle), findsNothing);
    expect(t.testTextInput.isVisible, isTrue);
  });

  test('DifyChoiceMark: the current choice\'s row and the accent check', () {
    expect(DifyChoiceMark.row, DifyColors.stateBaseHover);
    expect(DifyChoiceMark.check.name, 'check-line');
    expect(DifyChoiceMark.check.color, DifyColors.textAccent);
  });
}
