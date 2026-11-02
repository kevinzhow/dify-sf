// dify-sf phone layout (no Dify spec): the tabs' touch size (DifyTabSize.touch), at least 44 px tall on phones; the
// regular size keeps Dify's geometry.
import 'phone_harness.dart';

Widget _row(DifyTabSize size, ValueChanged<String> onTap, {String active = 'Result'}) => Align(
  alignment: Alignment.topLeft,
  child: DifyTabsList(
    size: size,
    children: [
      for (final label in const ['Result', 'Detail'])
        DifyTab(key: ValueKey('tab-$label'), label: label, active: label == active, onPressed: () => onTap(label)),
      // A tab drawn by its builder (the run panels' tabs: 12 px above and below an 18 px line).
      DifyTab(
        key: const ValueKey('tab-built'),
        active: false,
        semanticLabel: 'Tracing',
        onPressed: () => onTap('Tracing'),
        builder: (context, hovered, focused) => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: SizedBox(height: 18, child: DifyTextLine('TRACING')),
        ),
      ),
    ],
  ),
);

void main() {
  testWidgets('touch: every tab, built or styled, is at least 44 px tall and takes a tap anywhere on it', (t) async {
    final taps = <String>[];
    await renderControl(t, _row(DifyTabSize.touch, taps.add));
    for (final key in const ['tab-Result', 'tab-Detail', 'tab-built']) {
      expect(t.getSize(find.byKey(ValueKey(key))).height, greaterThanOrEqualTo(DifyTab.touchHeight), reason: key);
    }
    final built = t.getRect(find.byKey(const ValueKey('tab-built')));
    expect(built.height, DifyTab.touchHeight);
    await t.tapAt(built.bottomCenter - const Offset(0, 1));
    await t.tapAt(t.getRect(find.byKey(const ValueKey('tab-Detail'))).topCenter + const Offset(0, 1));
    expect(taps, ['Tracing', 'Detail']);
  });

  testWidgets('regular: Dify geometry, a tab may set its own size inside a list', (t) async {
    await renderControl(t, _row(DifyTabSize.regular, (_) {}));
    expect(t.getSize(find.byKey(const ValueKey('tab-built'))).height, 42);
    await renderControl(
      t,
      DifyTabsList(
        children: [
          DifyTab(key: const ValueKey('one'), label: 'One', active: true, size: DifyTabSize.touch, onPressed: () {}),
        ],
      ),
    );
    expect(t.getSize(find.byKey(const ValueKey('one'))).height, greaterThanOrEqualTo(DifyTab.touchHeight));
  });
}
