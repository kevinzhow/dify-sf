// dify-sf phone layout (no Dify spec): every 48 px touch target of the phone components responds up to its edge.
// A 44 px button's target is 2 px wider on each side; its parent must hold that strip, or the strip is dead.
import 'phone_harness.dart';

/// Points 2 px inside each edge of [target], and (when the visual box is smaller) 1 px inside, which is outside the
/// visual box and so only reachable through the extra target area.
List<Offset> _edgePoints(Rect target) => [
  for (final inset in const [2.0, 1.0]) ...[
    Offset(target.left + inset, target.center.dy),
    Offset(target.right - inset, target.center.dy),
    Offset(target.center.dx, target.top + inset),
    Offset(target.center.dx, target.bottom - inset),
  ],
];

Future<int> _tapEdges(WidgetTester t, Rect target, int Function() count) async {
  final before = count();
  for (final p in _edgePoints(target)) {
    await t.tapAt(p);
    await t.pump(const Duration(milliseconds: 50));
  }
  return count() - before;
}

/// A 44 px [DifyTouchIconButton]'s 48 px target.
Rect _iconTarget(WidgetTester t, Finder button) {
  final r = t.getRect(button);
  expect(r.size, const Size(44, 44));
  return r.inflate(2);
}

void main() {
  testWidgets('DifySheetHeader: the close button and the actions answer up to their 48 px edges', (t) async {
    var closes = 0, runs = 0;
    await renderControl(
      t,
      DifySheetHeader(
        title: 'Summarize',
        subtitle: 'LLM',
        actions: [
          DifyTouchIconButton(label: 'Run', icon: const RemixIcon('play-line', size: 20), onPressed: () => runs++),
        ],
        onClose: () => closes++,
      ),
    );
    expect(await _tapEdges(t, _iconTarget(t, find.bySemanticsLabel('operation.close')), () => closes), 8);
    expect(await _tapEdges(t, _iconTarget(t, find.bySemanticsLabel('Run')), () => runs), 8);
  });

  testWidgets('DifyTopAppBar: the back button and the last action answer up to their 48 px edges', (t) async {
    phoneView(t);
    var backs = 0, more = 0;
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Column(
          children: [
            DifyTopAppBar(
              title: 'Self-host check',
              leading: DifyAppBarBackButton(onPressed: () => backs++),
              actions: [
                DifyTouchIconButton(
                  label: 'More',
                  icon: const RemixIcon('more-fill', size: 22),
                  onPressed: () => more++,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(await _tapEdges(t, _iconTarget(t, find.byType(DifyAppBarBackButton)), () => backs), 8);
    expect(await _tapEdges(t, _iconTarget(t, find.bySemanticsLabel('More')), () => more), 8);
  });

  testWidgets('DifySelectionBar: the close glyph answers up to the edges of its 48 px square', (t) async {
    phoneView(t);
    var closes = 0;
    await renderControl(
      t,
      DifySelectionBar(
        title: 'Count Android',
        subtitle: 'selected',
        onClose: () => closes++,
        actions: [
          DifyToolbarAction(icon: const RemixIcon('file-copy-line', size: 22), label: 'Duplicate', onTap: () {}),
          DifyToolbarAction(icon: const RemixIcon('delete-bin-line', size: 22), label: 'Delete', onTap: () {}),
        ],
      ),
    );
    final square = t.getRect(find.bySemanticsLabel('operation.close'));
    expect(square.size, const Size(48, 48));
    expect(await _tapEdges(t, square, () => closes), 8);
  });

  testWidgets('DifyNavigationBar: a destination answers up to the edges of its cell', (t) async {
    phoneView(t);
    var taps = 0;
    await renderControl(
      t,
      DifyNavigationBar(
        destinations: const [
          DifyNavigationDestination(icon: RemixIcon('apps-2-line', size: 22), label: 'Studio'),
          DifyNavigationDestination(icon: RemixIcon('puzzle-2-line', size: 22), label: 'Integrations'),
          DifyNavigationDestination(icon: RemixIcon('user-line', size: 22), label: 'Account'),
        ],
        selectedIndex: 0,
        onDestinationSelected: (i) => i == 1 ? taps++ : null,
      ),
    );
    final cell = t.getRect(find.ancestor(of: find.text('Integrations'), matching: find.byType(DifyPressable)).first);
    expect(cell.height, greaterThanOrEqualTo(48));
    expect(cell.width, greaterThanOrEqualTo(48));
    expect(await _tapEdges(t, cell, () => taps), 8);
  });

  testWidgets('DifyBottomToolbar: an action answers up to the edges of its cell', (t) async {
    var taps = 0;
    await renderControl(
      t,
      DifyBottomToolbar(
        actions: [
          DifyToolbarAction(icon: const RemixIcon('arrow-go-back-line', size: 22), label: 'Undo', onTap: () => taps++),
          DifyToolbarAction(icon: const RemixIcon('history-line', size: 22), label: 'Versions', onTap: () {}),
        ],
      ),
    );
    final cell = t.getRect(find.byType(DifyToolbarAction).first);
    expect(cell.height, greaterThanOrEqualTo(48));
    expect(cell.width, greaterThanOrEqualTo(52));
    expect(await _tapEdges(t, cell, () => taps), 8);
  });

  testWidgets('DifySegmentedControl touch size: a segment answers up to the edges of the 48 px box', (t) async {
    var taps = 0;
    await renderControl(
      t,
      DifySegmentedControl<String>(
        value: 'steps',
        size: DifySegmentedControlSize.touch,
        onChanged: (_) => taps++,
        segments: const [
          (value: 'steps', label: 'Steps', child: DifyTextLine('Steps')),
          (value: 'canvas', label: 'Canvas', child: DifyTextLine('Canvas')),
        ],
      ),
    );
    final box = t.getRect(find.byType(DifySegmentedControl<String>));
    expect(box.height, 48);
    final x = t.getCenter(find.text('Canvas')).dx;
    final before = taps;
    for (final y in [box.top + 2, box.top + 1, box.bottom - 2, box.bottom - 1]) {
      await t.tapAt(Offset(x, y));
      await t.pump();
    }
    expect(taps - before, 4);
  });
}
