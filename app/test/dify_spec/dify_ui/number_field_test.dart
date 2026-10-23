// dify-spec: packages/dify-ui/src/number-field/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('NumberField wrapper', () {
    group('Group and input', () {
      testWidgets('should show the compound focus surface when keyboard users enter without Field', (t) async {
        await renderControl(t, const DifyNumberField(value: 8, semanticLabel: 'Amount'));
        final resting = inputDecoration(t).boxShadow;
        await focusInput(t);
        expect(inputDecoration(t).boxShadow, isNot(resting));
      });
      testWidgets('should surface field invalid state on the visual group', (t) async {
        await renderControl(t, const DifyNumberField(value: 8, invalid: true, semanticLabel: 'Amount'));
        expect(inputDecoration(t).border!.top.color, DifyColors.componentsInputBorderDestructive);
        expect(
          t.getSemantics(find.byType(DifyNumberField)).getSemanticsData().validationResult,
          SemanticsValidationResult.invalid,
        );
      });
    });
    group('Control buttons', () {
      testWidgets('should provide english fallback aria labels and default icons when labels are not provided', (
        t,
      ) async {
        var value = 8;
        await renderControl(
          t,
          StatefulBuilder(
            builder: (context, set) =>
                DifyNumberField(value: value, showControls: true, onChanged: (v) => set(() => value = v!.toInt())),
          ),
        );
        await t.tap(find.bySemanticsLabel('Increment value'));
        await t.pump();
        expect(value, 9);
        await t.tap(find.bySemanticsLabel('Decrement value'));
        await t.pump();
        expect(value, 8);
        expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'arrow-up-s-line'), findsOneWidget);
      });
      testWidgets('should keep the fallback aria labels when aria-label is omitted in props', (t) async {
        var value = 8;
        await renderControl(
          t,
          StatefulBuilder(
            builder: (context, set) =>
                DifyNumberField(value: value, showControls: true, onChanged: (v) => set(() => value = v!.toInt())),
          ),
        );
        await t.tap(find.bySemanticsLabel('Increment value'));
        await t.pump();
        expect(value, 9);
        await t.tap(find.bySemanticsLabel('Decrement value'));
        await t.pump();
        expect(value, 8);
        expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'arrow-up-s-line'), findsOneWidget);
      });
      testWidgets('should preserve explicit aria labels and custom children', (t) async {
        final changes = <num?>[];
        await renderControl(
          t,
          DifyNumberField(
            value: 8,
            showControls: true,
            onChanged: changes.add,
            incrementLabel: 'Increase amount',
            decrementLabel: 'Decrease amount',
            incrementIcon: const Text('+'),
            decrementIcon: const Text('-'),
          ),
        );
        await t.tap(find.bySemanticsLabel('Increase amount'));
        await t.pump();
        expect(changes, [9]);
        expect(find.text('+'), findsOneWidget);
        expect(find.text('-'), findsOneWidget);
        expect(find.bySemanticsLabel('Decrement value'), findsNothing);
      });
    });
  });
}
