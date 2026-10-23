// dify-spec: packages/dify-ui/src/dialog/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Dialog wrapper', () {
    group('Rendering', () {
      testWidgets('should move focus to the requested initial target', (t) async {
        await openControlDialog(t, initialFocus: true);
        expect(Focus.of(t.element(find.text('Focus target'))).hasFocus, isTrue);
      });
      testWidgets('should render dialog content when dialog is open', (t) async {
        await openControlDialog(t);
        expect(find.text('Dialog Title'), findsOneWidget);
        expect(find.text('Dialog Description'), findsOneWidget);
        expect(find.byType(DifyDialogSurface), findsOneWidget);
      });
      testWidgets('should connect a detached trigger to the dialog', (t) async {
        await openControlDialog(t);
        expect(find.text('Dialog Title'), findsOneWidget);
      });
    });
    group('Composition', () {
      testWidgets('should compose an explicitly named IconButton as the close control', (t) async {
        await renderControl(
          t,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDifyDialog<void>(
                context,
                builder: (ctx) => DifyDialogSurface(
                  label: 'Dialog Title',
                  child: DifyIconButton(
                    label: 'Dismiss dialog',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        );
        await t.tap(find.text('Open'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        expect(find.bySemanticsLabel('Dismiss dialog'), findsOneWidget);
        await t.tap(find.bySemanticsLabel('Dismiss dialog'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        expect(find.byType(DifyDialogSurface), findsNothing);
      });
      testWidgets('should close the dialog when the composed close control is activated', (t) async {
        await openControlDialog(t, close: true);
        await t.tap(find.text('Close dialog'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 200));
        expect(find.byType(DifyDialogSurface), findsNothing);
      });
      testWidgets('should preserve the disabled state of a composed close control', (t) async {
        await openControlDialog(t, close: true, disabled: true);
        await t.tap(find.text('Close dialog'));
        await t.pump();
        expect(find.byType(DifyDialogSurface), findsOneWidget);
      });
    });
  });
}
