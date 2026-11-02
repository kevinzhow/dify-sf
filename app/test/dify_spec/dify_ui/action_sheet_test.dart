// dify-sf phone layout (no Dify spec): the action sheet that replaces right-click and "…" menus on phones.
import 'phone_harness.dart';

void main() {
  group('showDifyActionSheet', () {
    testWidgets('52 px rows; a row closes the sheet and then runs its action', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      final events = <String>[];
      final done = showDifyActionSheet(
        nav.currentContext!,
        title: 'Count Android',
        actions: [
          DifyActionSheetAction(
            icon: const RemixIcon('file-copy-line', size: 20),
            label: 'Duplicate',
            onTap: () => events.add('duplicate, sheet open: ${nav.currentState!.canPop()}'),
          ),
          DifyActionSheetAction(label: 'Rename', enabled: false, onTap: () => events.add('rename')),
          DifyActionSheetAction(
            icon: const RemixIcon('delete-bin-line', size: 20),
            label: 'Delete',
            destructive: true,
            onTap: () => events.add('delete'),
          ),
        ],
      );
      await t.pumpAndSettle();
      expect(find.text('Count Android'), findsOneWidget);
      for (final label in ['Duplicate', 'Rename', 'Delete', 'operation.cancel']) {
        final row = find.ancestor(of: find.text(label), matching: find.byType(DifyPressable)).first;
        expect(t.getSize(row).height, 52, reason: label);
      }
      RichText text(String s) =>
          t.widget<RichText>(find.descendant(of: find.text(s), matching: find.byType(RichText)).first);
      expect(text('Delete').text.style!.color, DifyColors.textDestructive);
      expect(text('Rename').text.style!.color, DifyColors.textDisabled);
      expect(text('Duplicate').text.style!.fontSize, 15);
      // The sheet hugs its rows.
      expect(t.getRect(find.byType(DifySheetGrabHandle)).top, greaterThan(915 / 2));

      await t.tap(find.text('Rename'));
      await t.pumpAndSettle();
      expect(events, isEmpty);
      await t.tap(find.text('Duplicate'));
      await t.pumpAndSettle();
      await done;
      expect(events, ['duplicate, sheet open: false']);
      expect(find.text('Duplicate'), findsNothing);
    });

    testWidgets('Cancel, the scrim and back close it without an action', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      final events = <String>[];
      final actions = [DifyActionSheetAction(label: 'Delete', destructive: true, onTap: () => events.add('delete'))];
      showDifyActionSheet(nav.currentContext!, actions: actions, cancelLabel: 'Keep');
      await t.pumpAndSettle();
      await t.tap(find.text('Keep'));
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);

      showDifyActionSheet(nav.currentContext!, actions: actions);
      await t.pumpAndSettle();
      await t.tapAt(const Offset(200, 100));
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);

      showDifyActionSheet(nav.currentContext!, actions: actions);
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      expect(events, isEmpty);
    });

    testWidgets('many rows scroll inside the sheet', (t) async {
      phoneView(t, size: const Size(360, 640));
      final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      showDifyActionSheet(
        nav.currentContext!,
        actions: [for (var i = 0; i < 30; i++) DifyActionSheetAction(label: 'Action $i', onTap: () {})],
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('operation.cancel').hitTestable(), findsOneWidget);
      expect(find.text('Action 29').hitTestable(), findsNothing);
    });
  });
}
