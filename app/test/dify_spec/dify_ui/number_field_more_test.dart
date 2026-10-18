// dify-spec: packages/dify-ui/src/number-field/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Invalid focus colors', () {
    testWidgets('preserves error colors through keyboard and pointer focus in %s', (t) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await renderControl(
          t,
          const DifyNumberField(value: 8, invalid: true),
          theme: ThemeData(brightness: brightness),
        );
        final resting = inputDecoration(t);
        await focusInput(t);
        expect(inputDecoration(t).color, resting.color);
        expect(inputDecoration(t).border, resting.border);
        await t.tap(find.byType(TextField));
        await t.pump();
        expect(inputDecoration(t).color, resting.color);
        expect(inputDecoration(t).border, resting.border);
        await t.pumpWidget(const SizedBox());
        await t.pump();
      }
    });
  });
}
