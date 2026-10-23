// dify-spec: packages/dify-ui/src/input-group/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('InputGroup', () {
    testWidgets('should preserve an interactive add-on as the focus owner', (t) async {
      var copies = 0;
      await renderControl(
        t,
        DifyInput(
          value: 'key',
          trailing: DifyButton(onPressed: () => copies++, child: const Text('Copy')),
        ),
      );
      await t.tap(find.byType(TextField));
      await t.pump();
      expect(t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
      await t.tap(find.text('Copy'));
      await t.pump();
      expect(copies, 1);
      expect(Focus.of(t.element(find.text('Copy'))).hasFocus, isTrue);
      expect(t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isFalse);
      expect(inputDecoration(t).boxShadow, isNull);
    });
    testWidgets('should not handle pointer events from portalled add-on content', (t) async {
      await renderControl(
        t,
        DifyInput(
          value: 'File',
          trailing: DifyPopover(
            semanticLabel: 'File actions',
            builder: (_, c) => DifyButton(onPressed: c.toggle, child: const Text('More')),
            content: const Padding(padding: EdgeInsets.all(20), child: Text('File details')),
          ),
        ),
      );
      await t.tap(find.text('More'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      expect(find.text('File details'), findsOneWidget);
      await t.tap(find.text('File details'));
      await t.pump();
      expect(t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isFalse);
      expect(find.text('File details'), findsOneWidget);
    });
    testWidgets('should keep a visually leading interactive add-on after the input in focus order', (t) async {
      await renderControl(
        t,
        DifyInput(
          value: 'Amount',
          leading: DifyButton(onPressed: () {}, child: const Text('Currency')),
        ),
      );
      await t.tap(find.byType(TextField));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(Focus.of(t.element(find.text('Currency'))).hasFocus, isTrue);
    });
  });
}
