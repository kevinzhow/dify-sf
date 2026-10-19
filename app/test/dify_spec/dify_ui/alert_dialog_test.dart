// dify-spec: packages/dify-ui/src/alert-dialog/__tests__/index.spec.tsx
import 'control_harness.dart';

/// Opens a [DifyAlertDialog] through [showDifyAlertDialog] (dify-ui's AlertDialog: no outside-click dismissal).
Future<void> _openAlertDialog(WidgetTester t, {bool initialFocus = false}) async {
  await renderControl(
    t,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showDifyAlertDialog<void>(
          context,
          builder: (ctx) => DifyAlertDialog(
            title: 'Alert Title',
            description: 'Alert Description',
            extra: initialFocus
                ? TextButton(autofocus: true, onPressed: () {}, child: const Text('Focus target'))
                : null,
            cancelLabel: 'Cancel',
            confirmLabel: 'Confirm',
            onCancel: () => Navigator.pop(ctx),
            onConfirm: () => Navigator.pop(ctx),
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  );
  // Focus the trigger (keyboard user), as the Dify spec's trigger holds the focus.
  await t.sendKeyEvent(LogicalKeyboardKey.tab);
  await t.tap(find.text('Open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 250));
}

void main() {
  group('AlertDialog wrapper', () {
    group('Props', () {
      testWidgets('should move focus to the requested initial target', (t) async {
        await _openAlertDialog(t, initialFocus: true);
        expect(Focus.of(t.element(find.text('Focus target'))).hasFocus, isTrue);
      });
      testWidgets('should not render a close button by default', (t) async {
        await _openAlertDialog(t);
        expect(find.text('Close dialog'), findsNothing);
        expect(find.byType(DifyIconButton), findsNothing);
        expect(find.text('Cancel'), findsOneWidget);
      });
    });
    group('Dismissal', () {
      testWidgets('should remain open when the user clicks outside the alert dialog', (t) async {
        await _openAlertDialog(t);
        await t.tapAt(const Offset(4, 4));
        await t.pump(const Duration(milliseconds: 250));
        expect(find.byType(DifyAlertDialogContent), findsOneWidget);
      });
      testWidgets('should close when the user activates the cancel action', (t) async {
        await _openAlertDialog(t);
        await t.tap(find.text('Cancel'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(find.byType(DifyAlertDialogContent), findsNothing);
      });
      testWidgets('should close with Escape and restore focus to the trigger', (t) async {
        await _openAlertDialog(t);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(find.byType(DifyAlertDialogContent), findsNothing);
        expect(Focus.of(t.element(find.text('Open'))).hasFocus, isTrue);
      });
    });
  });
}
