// dify-spec: packages/dify-ui/src/checkbox/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Checkbox', () {
    testWidgets('should render an unchecked checkbox with Base UI semantics', (t) async {
      await renderControl(t, const DifyCheckbox(checked: false, indeterminate: false, label: 'Accept terms'));
      final data = t.getSemantics(find.byType(DifyCheckbox)).getSemanticsData();
      expect(data.label, contains('Accept terms'));
      expect(data.flagsCollection.isChecked == CheckedState.isTrue, false);
      expect(data.flagsCollection.isChecked == CheckedState.mixed, false);
    });
    testWidgets('should expose checked data attributes', (t) async {
      await renderControl(t, const DifyCheckbox(checked: true, indeterminate: false, label: 'Accept terms'));
      final data = t.getSemantics(find.byType(DifyCheckbox)).getSemanticsData();
      expect(data.label, contains('Accept terms'));
      expect(data.flagsCollection.isChecked == CheckedState.isTrue, true);
      expect(data.flagsCollection.isChecked == CheckedState.mixed, false);
    });
    testWidgets('should expose mixed state when indeterminate', (t) async {
      await renderControl(t, const DifyCheckbox(checked: false, indeterminate: true, label: 'Accept terms'));
      final data = t.getSemantics(find.byType(DifyCheckbox)).getSemanticsData();
      expect(data.label, contains('Accept terms'));
      expect(data.flagsCollection.isChecked == CheckedState.isTrue, false);
      expect(data.flagsCollection.isChecked == CheckedState.mixed, true);
    });
    testWidgets('should call onCheckedChange with the next checked value', (t) async {
      final changes = <bool>[];
      await renderControl(t, DifyCheckbox(checked: false, onChanged: changes.add));
      await t.tap(find.byType(DifyCheckbox));
      expect(changes, [true]);
    });
    testWidgets('should stay controlled until the checked prop changes', (t) async {
      final changes = <bool>[];
      await renderControl(t, DifyCheckbox(checked: false, onChanged: changes.add));
      await t.tap(find.byType(DifyCheckbox));
      await t.pump();
      expect(changes, [true]);
      expect(t.widget<DifyCheckboxBox>(find.byType(DifyCheckboxBox)).checked, isFalse);
      await renderControl(t, DifyCheckbox(checked: true, onChanged: changes.add));
      expect(t.widget<DifyCheckboxBox>(find.byType(DifyCheckboxBox)).checked, isTrue);
    });
    testWidgets('should ignore interaction when disabled', (t) async {
      var calls = 0;
      await renderControl(t, DifyCheckbox(checked: false, disabled: true, onChanged: (_) => calls++));
      await t.tap(find.byType(DifyCheckbox));
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(calls, 0);
      expect(
        t.getSemantics(find.byType(DifyCheckbox)).getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue,
        isFalse,
      );
    });
  });
}
