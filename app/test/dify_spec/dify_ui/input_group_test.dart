// dify-spec: packages/dify-ui/src/input-group/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('InputGroup', () {
    testWidgets('should project Field state onto the grouped surface', (t) async {
      await renderControl(t, const DifyInput(value: 'github.com/langgenius', invalid: true, leading: Text('https://')));
      expect(inputDecoration(t).border!.top.color, DifyColors.componentsInputBorderDestructive);
      await focusInput(t);
      expect(inputDecoration(t).border!.top.color, DifyColors.componentsInputBorderDestructive);
      await t.tap(find.byType(TextField));
      await t.pump();
      expect(inputDecoration(t).color, DifyColors.componentsInputBgDestructive);
    });
    testWidgets('should extend the input pointer surface through a static add-on', (t) async {
      await renderControl(t, const DifyInput(value: '', leading: Text('https://')));
      await t.tap(find.text('https://'));
      await t.pump();
      expect(t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
    });
    testWidgets('should show keyboard focus on a read-only input', (t) async {
      await renderControl(t, const DifyInput(value: 'sk-test', readOnly: true, leading: Text('key')));
      final resting = inputDecoration(t).boxShadow;
      await focusInput(t);
      expect(inputDecoration(t).boxShadow, isNot(resting));
    });
  });
  group('Invalid focus colors', () {
    testWidgets('preserves error colors through keyboard and pointer focus in %s', (t) async {
      await renderControl(t, const DifyInput(value: 'invalid', invalid: true, leading: Text('https://')));
      expect(inputDecoration(t).border!.top.color, DifyColors.componentsInputBorderDestructive);
      await focusInput(t);
      expect(inputDecoration(t).border!.top.color, DifyColors.componentsInputBorderDestructive);
      await t.tap(find.byType(TextField));
      await t.pump();
      expect(inputDecoration(t).color, DifyColors.componentsInputBgDestructive);
    });
  });
}
