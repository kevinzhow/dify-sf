// dify-spec: packages/dify-ui/src/slider/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Slider', () {
    testWidgets('should render with correct default ARIA limits and current value', (t) async {
      await renderControl(t, const DifySlider(value: 50, semanticLabel: 'Value'));
      final slider = t.widget<DifySlider>(find.byType(DifySlider));
      expect((slider.min, slider.max, slider.value), (0, 100, 50));
      expect(t.getSemantics(find.byType(DifySlider)).value, '50');
    });
    testWidgets('should apply custom min, max, and step values', (t) async {
      final changes = <int>[];
      await renderControl(t, DifySlider(value: 10, min: 5, max: 20, step: 5, onChanged: changes.add));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(changes, [15]);
    });
    testWidgets('should call onValueChange when arrow keys are pressed', (t) async {
      final changes = <int>[];
      await renderControl(t, DifySlider(value: 20, onChanged: changes.add));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(changes, [21]);
    });
    testWidgets('should round floating point keyboard updates to the configured step', (t) async {
      final changes = <double>[];
      await renderControl(t, DifySlider.decimal(value: 0.2, min: 0, max: 1, step: 0.1, onChanged: changes.add));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(changes, [0.3]);
    });
    testWidgets('should not trigger onValueChange when disabled', (t) async {
      final changes = <int>[];
      await renderControl(t, DifySlider(value: 20, disabled: true, onChanged: changes.add));
      await t.tap(find.byType(DifySlider));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(changes, isEmpty);
      expect(
        t.getSemantics(find.byType(DifySlider)).getSemanticsData().flagsCollection.isEnabled,
        Tristate.isFalse,
      );
    });
    testWidgets('should forward thumb value text to the range input', (t) async {
      await renderControl(t, DifySlider(value: 50, semanticLabel: 'Temperature', valueText: (int v) => '$v degrees'));
      expect(t.getSemantics(find.byType(DifySlider)).value, '50 degrees');
    });
  });
}
