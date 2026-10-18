// dify-spec: packages/dify-ui/src/textarea/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Textarea', () {
    testWidgets('should show keyboard focus when read-only', (t) async {
      await renderControl(t, const DifyTextarea(value: 'Saved notes', readOnly: true));
      final resting = inputDecoration(t).boxShadow;
      await focusInput(t);
      expect(inputDecoration(t).boxShadow, isNot(resting));
      expect(t.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    });
    testWidgets('should render a labelled textarea through Base UI Field.Control', (t) async {
      await renderControl(
        t,
        const DifyTextarea(value: 'A workspace for support automation.', semanticLabel: 'Description'),
      );
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'A workspace for support automation.');
      expect(t.getSemantics(find.byType(DifyTextarea)).label, contains('Description'));
      expect(t.widget<TextField>(find.byType(TextField)).maxLines, isNull);
    });
    testWidgets('should call onValueChange and stay controlled until value changes', (t) async {
      final changes = <String>[];
      await renderControl(t, DifyTextarea(value: '', onChanged: changes.add));
      await t.enterText(find.byType(TextField), 'a');
      await t.pump();
      expect(changes, ['a']);
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '');
      await renderControl(t, DifyTextarea(value: 'a', onChanged: changes.add));
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'a');
    });
    testWidgets('should pass maxLength to the textarea without rendering a counter', (t) async {
      var value = 'Draft';
      await renderControl(
        t,
        StatefulBuilder(
          builder: (context, set) => DifyTextarea(value: value, maxLength: 20, onChanged: (v) => set(() => value = v)),
        ),
      );
      await t.enterText(find.byType(TextField), '1234567890123456789012345');
      await t.pump();
      expect(value.length, 20);
      expect(find.text('5/20'), findsNothing);
      expect(find.text('20/20'), findsNothing);
    });
  });
}
