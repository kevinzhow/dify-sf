// dify-sf phone layout (no Dify spec): the editor's bottom toolbar and selection bar (mockups 2, 3).
import 'phone_harness.dart';

void main() {
  group('DifyBottomToolbar', () {
    testWidgets('a 60 px bar of 52+ px actions with the FAB in the centre slot', (t) async {
      phoneView(t, size: const Size(360, 800));
      final taps = <String>[];
      await renderControl(
        t,
        DifyBottomToolbar(
          actions: [
            DifyToolbarAction(
              icon: const RemixIcon('arrow-go-back-line', size: 22),
              label: 'Undo',
              onTap: () => taps.add('undo'),
            ),
            DifyToolbarAction(
              icon: const RemixIcon('arrow-go-forward-fill', size: 22),
              label: 'Redo',
              enabled: false,
              onTap: () => taps.add('redo'),
            ),
            DifyToolbarAction(
              icon: const RemixIcon('edit-line', size: 22),
              label: 'Note',
              onTap: () => taps.add('note'),
            ),
            DifyToolbarAction(
              icon: const RemixIcon('history-line', size: 22),
              label: 'Versions',
              onTap: () => taps.add('versions'),
            ),
          ],
          center: DifyFab(icon: const RemixIcon('add-line', size: 28), label: 'Add', onPressed: () => taps.add('add')),
        ),
      );
      final bar = t.getRect(find.byType(DifyBottomToolbar));
      expect(bar.height, DifyBottomToolbar.height);
      final actions = [for (final e in find.byType(DifyToolbarAction).evaluate()) t.getRect(find.byWidget(e.widget))];
      for (final a in actions) {
        expect(a.width, greaterThanOrEqualTo(DifyToolbarAction.minWidth));
        expect(a.height, DifyBottomToolbar.height);
      }
      final fab = t.getRect(find.byType(DifyFab));
      expect(fab.center.dx, closeTo(bar.center.dx, 0.5));
      expect(actions[1].right, lessThanOrEqualTo(fab.left));
      expect(actions[2].left, greaterThanOrEqualTo(fab.right));
      // The whole cell is the target, including its edge.
      await t.tapAt(actions[0].topLeft + const Offset(2, 2));
      await t.tap(find.text('Redo'));
      await t.tap(find.text('Versions'));
      await t.tap(find.byType(DifyFab));
      expect(taps, ['undo', 'versions', 'add']);
      RichText label(String s) =>
          t.widget<RichText>(find.descendant(of: find.text(s), matching: find.byType(RichText)).first);
      expect(label('Undo').text.style!.fontSize, 11);
      expect(label('Redo').text.style!.color, DifyColors.textDisabled);
    });

    testWidgets('destructive actions are tinted text-destructive', (t) async {
      await renderControl(
        t,
        DifyBottomToolbar(
          actions: [
            DifyToolbarAction(
              icon: const RemixIcon('delete-bin-line', size: 22),
              label: 'Delete',
              destructive: true,
              onTap: () {},
            ),
          ],
        ),
      );
      final label = t.widget<RichText>(find.descendant(of: find.text('Delete'), matching: find.byType(RichText)).first);
      expect(label.text.style!.color, DifyColors.textDestructive);
    });
  });

  group('DifySelectionBar', () {
    testWidgets('header, close with a 48 px target, and a row of actions', (t) async {
      phoneView(t);
      final taps = <String>[];
      await renderControl(
        t,
        DifySelectionBar(
          leading: const RemixIcon('file-copy-line', size: 22),
          title: 'Count Android',
          subtitle: 'selected',
          onClose: () => taps.add('close'),
          actions: [
            for (final a in ['Settings', 'Run step', 'Add next', 'Connect…', 'Duplicate'])
              DifyToolbarAction(icon: const RemixIcon('settings-3-line', size: 22), label: a, onTap: () => taps.add(a)),
            DifyToolbarAction(
              icon: const RemixIcon('delete-bin-line', size: 22),
              label: 'Delete',
              destructive: true,
              onTap: () => taps.add('Delete'),
            ),
          ],
        ),
      );
      expect(find.text('Count Android'), findsOneWidget);
      expect(find.text('selected'), findsOneWidget);
      // The 20 px glyph sits in a 48 px square of its own.
      final close = t.getRect(find.bySemanticsLabel('operation.close'));
      expect(close.size, const Size(48, 48));
      expect(
        t.getSize(find.descendant(of: find.bySemanticsLabel('operation.close'), matching: find.byType(RemixIcon))),
        const Size(20, 20),
      );
      await t.tapAt(close.centerLeft + const Offset(2, 0));
      await t.tap(find.text('Duplicate'));
      await t.tap(find.text('Delete'));
      expect(taps, ['close', 'Duplicate', 'Delete']);
      for (final e in find.byType(DifyToolbarAction).evaluate()) {
        expect(t.getSize(find.byWidget(e.widget)).height, greaterThanOrEqualTo(48));
      }
      expect(t.takeException(), isNull);
    });
  });
}
