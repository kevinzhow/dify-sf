// dify-spec: packages/dify-ui/src/segmented-control/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('SegmentedControl', () {
    testWidgets('exposes a required single choice through radio semantics', (t) async {
      await renderControl(
        t,
        const DifySegmentedControl(
          value: 'one',
          semanticLabel: 'View',
          segments: [
            (value: 'one', label: 'One', child: Text('One')),
            (value: 'two', label: 'Two', child: Text('Two')),
            (value: 'three', label: 'Three', child: Text('Three')),
          ],
        ),
      );
      expect(
        t.getSemantics(find.bySemanticsLabel('One')).getSemanticsData().flagsCollection.isChecked,
        CheckedState.isTrue,
      );
      expect(
        t.getSemantics(find.bySemanticsLabel('Two')).getSemanticsData().flagsCollection.isChecked,
        CheckedState.isFalse,
      );
    });
    testWidgets('updates an uncontrolled selection without allowing the selected item to be cleared', (t) async {
      var value = 'one';
      final changes = <String>[];
      await renderControl(
        t,
        StatefulBuilder(
          builder: (context, set) => DifySegmentedControl(
            value: value,
            segments: const [
              (value: 'one', label: 'One', child: Text('One')),
              (value: 'two', label: 'Two', child: Text('Two')),
              (value: 'three', label: 'Three', child: Text('Three')),
            ],
            onChanged: (v) {
              changes.add(v);
              set(() => value = v);
            },
          ),
        ),
      );
      await t.tap(find.text('One'));
      await t.pump();
      expect(changes, isEmpty);
      await t.tap(find.text('Two'));
      await t.pump();
      expect(value, 'two');
      expect(changes, ['two']);
    });
    testWidgets('leaves a controlled selection to its caller', (t) async {
      final changes = <String>[];
      await renderControl(
        t,
        DifySegmentedControl(
          value: 'one',
          segments: const [
            (value: 'one', label: 'One', child: Text('One')),
            (value: 'two', label: 'Two', child: Text('Two')),
            (value: 'three', label: 'Three', child: Text('Three')),
          ],
          onChanged: changes.add,
        ),
      );
      await t.tap(find.text('Two'));
      await t.pump();
      expect(changes, ['two']);
      expect(
        t.getSemantics(find.bySemanticsLabel('One')).getSemanticsData().flagsCollection.isChecked,
        CheckedState.isTrue,
      );
    });
    testWidgets('selects the next enabled item with an arrow key', (t) async {
      var value = 'one';
      await renderControl(
        t,
        StatefulBuilder(
          builder: (context, set) => DifySegmentedControl(
            value: value,
            segments: const [
              (value: 'one', label: 'One', child: Text('One')),
              (value: 'two', label: 'Two', child: Text('Two')),
              (value: 'three', label: 'Three', child: Text('Three')),
            ],
            disabledValues: const {'two'},
            onChanged: (v) => set(() => value = v),
          ),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(value, 'three');
      expect(FocusManager.instance.primaryFocus!.debugLabel, 'segment Three');
    });
    testWidgets('keeps disabled item semantics and a decorative divider', (t) async {
      var calls = 0;
      await renderControl(
        t,
        DifySegmentedControl(
          value: 'one',
          segments: const [
            (value: 'one', label: 'One', child: Text('One')),
            (value: 'two', label: 'Two', child: Text('Two')),
            (value: 'three', label: 'Three', child: Text('Three')),
          ],
          disabledValues: const {'two'},
          onChanged: (_) => calls++,
        ),
      );
      await t.tap(find.text('Two'));
      expect(calls, 0);
      expect(
        t.getSemantics(find.bySemanticsLabel('Two')).getSemanticsData().flagsCollection.isEnabled,
        Tristate.isFalse,
      );
    });
  });
}
