// dify-spec: packages/dify-ui/src/input/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Input', () {
    testWidgets('initial autofocus accepts typing without stealing a later field on rebuild', (t) async {
      var first = '', second = '';
      await renderControl(
        t,
        StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DifyInput(value: first, autofocus: true, onChanged: (v) => setState(() => first = v)),
              DifyInput(value: second, onChanged: (v) => setState(() => second = v)),
            ],
          ),
        ),
      );
      final fields = find.byType(TextField);
      expect(t.widget<TextField>(fields.first).focusNode!.hasFocus, isTrue);
      t.testTextInput.enterText('First 中文 🚀');
      await t.pump();
      expect(first, 'First 中文 🚀');
      await t.tap(fields.last);
      t.testTextInput.enterText('Second e\u0301');
      await t.pump();
      expect(second, 'Second e\u0301');
      expect(t.widget<TextField>(fields.last).focusNode!.hasFocus, isTrue);
      expect(t.widget<TextField>(fields.first).focusNode!.hasFocus, isFalse);
      expect(t.takeException(), isNull);
    });

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
