// dify-spec: packages/dify-ui/src/switch/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Switch', () {
    testWidgets('should expose disabled state and stay out of the tab order', (t) async {
      var calls = 0;
      await renderControl(t, DifySwitch(checked: false, disabled: true, onCheckedChange: (_) => calls++));
      await t.tap(find.byType(DifySwitch));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(calls, 0);
      expect(
        t.getSemantics(find.byType(DifySwitch)).getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue,
        isFalse,
      );
    });
    testWidgets('should reflect checked state on the root and thumb', (t) async {
      await renderControl(t, const DifySwitch(checked: false));
      expect(t.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset, Offset.zero);
      await renderControl(t, const DifySwitch(checked: true));
      expect(t.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset.dx, greaterThan(0));
      expect(
        t.getSemantics(find.byType(DifySwitch)).getSemanticsData().flagsCollection.isToggled == Tristate.isTrue,
        isTrue,
      );
    });
    group('loading state', () {
      testWidgets('should render as disabled when loading', (t) async {
        var calls = 0;
        await renderControl(t, DifySwitch(checked: false, loading: true, onCheckedChange: (_) => calls++));
        await t.tap(find.byType(DifySwitch));
        expect(calls, 0);
        expect(
          t.getSemantics(find.byType(DifySwitch)).getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue,
          isFalse,
        );
      });
      testWidgets('should show spinner icon for md and lg sizes', (t) async {
        await renderControl(t, const DifySwitch(checked: false, loading: true, size: DifySwitchSize.md));
        expect(find.byType(DifySpinner), findsOneWidget);
        await renderControl(t, const DifySwitch(checked: false, loading: true, size: DifySwitchSize.lg));
        expect(find.byType(DifySpinner), findsOneWidget);
      });
      testWidgets('should not show spinner for xs and sm sizes', (t) async {
        await renderControl(t, const DifySwitch(checked: false, loading: true, size: DifySwitchSize.xs));
        expect(find.byType(DifySpinner), findsNothing);
        await renderControl(t, const DifySwitch(checked: false, loading: true, size: DifySwitchSize.sm));
        expect(find.byType(DifySpinner), findsNothing);
      });
    });
  });
}
