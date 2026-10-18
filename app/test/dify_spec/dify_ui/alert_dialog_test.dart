// dify-spec: packages/dify-ui/src/alert-dialog/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('AlertDialog wrapper', () {
    group('Props', () {
      testWidgets('should move focus to the requested initial target', (t) async {
        await openControlDialog(t, dismissible: false, initialFocus: true);
        expect(Focus.of(t.element(find.text('Focus target'))).hasFocus, isTrue);
      });
      testWidgets('should not render a close button by default', (t) async {
        await openControlDialog(t, dismissible: false);
        expect(find.text('Close dialog'), findsNothing);
        expect(find.text('Cancel'), findsOneWidget);
      });
    });
    group('Dismissal', () {
      testWidgets('should remain open when the user clicks outside the alert dialog', (t) async {
        await openControlDialog(t, dismissible: false);
        await t.tapAt(const Offset(4, 4));
        await t.pump(const Duration(milliseconds: 250));
        expect(find.byType(DifyDialogSurface), findsOneWidget);
      });
      testWidgets('should close when the user activates the cancel action', (t) async {
        await openControlDialog(t, dismissible: false);
        await t.tap(find.text('Cancel'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(find.byType(DifyDialogSurface), findsNothing);
      });
      testWidgets('should close with Escape and restore focus to the trigger', (t) async {
        await openControlDialog(t, dismissible: false);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(find.byType(DifyDialogSurface), findsNothing);
        expect(Focus.of(t.element(find.text('Open'))).hasFocus, isTrue);
      });
    });
  });
}
