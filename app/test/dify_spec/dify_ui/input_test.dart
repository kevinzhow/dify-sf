// dify-spec: packages/dify-ui/src/input/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Input', () {
    testWidgets('should show keyboard focus when read-only', (t) async {
      await renderControl(t, const DifyInput(value: 'sk-test', readOnly: true));
      final resting = inputDecoration(t).boxShadow;
      await focusInput(t);
      expect(inputDecoration(t).boxShadow, isNot(resting));
      expect(t.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    });
    testWidgets('should use Field invalid state', (t) async {
      await renderControl(
        t,
        const DifyInput(value: 'github.com/langgenius', semanticLabel: 'Repository URL', invalid: true),
      );
      expect(inputDecoration(t).border!.top.color, DifyColors.componentsInputBorderDestructive);
      expect(
        t.getSemantics(find.byType(DifyInput)).getSemanticsData().validationResult,
        SemanticsValidationResult.invalid,
      );
    });
  });
}
