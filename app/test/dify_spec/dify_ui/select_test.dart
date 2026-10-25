// dify-spec: packages/dify-ui/src/select/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Select wrappers', () {
    testWidgets('trigger announces and tracks its expanded state', (t) async {
      await renderControl(
        t,
        const DifySelect(
          value: 'one',
          semanticLabel: 'Model',
          options: [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
        ),
      );
      var data = t.getSemantics(find.bySemanticsLabel('Model')).getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isExpanded, Tristate.isFalse);
      await t.tap(find.bySemanticsLabel('Model'));
      await t.pumpAndSettle();
      data = t.getSemantics(find.bySemanticsLabel('Model')).getSemanticsData();
      expect(data.flagsCollection.isExpanded, Tristate.isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(
        t.getSemantics(find.bySemanticsLabel('Model')).getSemanticsData().flagsCollection.isExpanded,
        Tristate.isFalse,
      );
    });

    group('SelectTrigger', () {
      testWidgets('should use SelectLabel as the trigger accessible name', (t) async {
        await renderControl(
          t,
          const DifySelect(
            value: 'one',
            options: [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
            semanticLabel: 'Model',
          ),
        );
        expect(find.bySemanticsLabel('Model'), findsOneWidget);
        expect(t.getSemantics(find.bySemanticsLabel('Model')).value, 'Option one');
      });
      testWidgets('should expose disabled state via data attributes when disabled', (t) async {
        var calls = 0;
        await renderControl(
          t,
          DifySelect(
            value: 'one',
            options: const [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
            disabled: true,
            onChanged: (_) => calls++,
          ),
        );
        await t.tap(find.text('Option one'));
        await t.pump();
        expect(find.text('Option two'), findsNothing);
        expect(calls, 0);
        expect(
          t.getSemantics(find.bySemanticsLabel('Option one')).getSemanticsData().flagsCollection.isEnabled,
          Tristate.isFalse,
        );
      });
      testWidgets('should expose readonly state via data attributes when Root is readOnly', (t) async {
        var calls = 0;
        await renderControl(
          t,
          DifySelect(
            value: 'one',
            options: const [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
            readonly: true,
            onChanged: (_) => calls++,
          ),
        );
        await t.tap(find.text('Option one'));
        await t.pump();
        expect(find.text('Option two'), findsNothing);
        expect(calls, 0);
        expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'arrow-down-s-line'), findsNothing);
      });
    });
    group('SelectContent', () {
      testWidgets('should render a group label without replacing the trigger name', (t) async {
        await renderControl(
          t,
          const DifySelect(
            value: 'one',
            semanticLabel: 'Model',
            groups: [
              (label: 'Available models', options: [(value: 'one', label: 'Option one')]),
            ],
          ),
        );
        await t.tap(find.text('Option one'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        expect(find.text('AVAILABLE MODELS'), findsOneWidget);
        expect(find.bySemanticsLabel('Model'), findsOneWidget);
      });
      testWidgets('should preserve selection behavior when composed through explicit anatomy', (t) async {
        final changes = <String>[];
        await renderControl(
          t,
          DifySelect(
            value: 'one',
            options: const [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
            onChanged: changes.add,
          ),
        );
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        await t.tap(find.text('Option two'));
        await t.pump();
        expect(changes, ['two']);
      });
    });
    group('SelectItem', () {
      testWidgets('should expose disabled item semantics', (t) async {
        final changes = <String>[];
        await renderControl(
          t,
          DifySelect(
            value: 'one',
            options: const [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
            disabledValues: const {'two'},
            onChanged: changes.add,
          ),
        );
        await t.tap(find.text('Option one'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        await t.tap(find.text('Option two'));
        await t.pump();
        expect(changes, isEmpty);
        expect(t.getSemantics(find.text('Option two')).getSemanticsData().flagsCollection.isEnabled, Tristate.isFalse);
      });
    });
  });
}
