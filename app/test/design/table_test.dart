import 'package:dify_sf_app/src/design/widgets/table.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('autoTableColumnWidths', () {
    test('automatic columns share the room beyond their maximums in proportion to them', () {
      expect(autoTableColumnWidths(470, [20, null, null], [10, 30, 30], [10, 100, 50]), [20, 300, 150]);
    });
    test('narrower than the maximums: minimums first, fixed columns, then automatic ones grow', () {
      expect(autoTableColumnWidths(130, [40, null, null], [10, 30, 30], [10, 120, 60]), [40, 52.5, 37.5]);
    });
    test('narrower than the minimums: the minimums', () {
      expect(autoTableColumnWidths(10, [null, null], [30, 30], [60, 60]), [30, 30]);
    });
  });

  group('fixedTableColumnWidths', () {
    test('fixed columns stretch in proportion when there is no automatic one', () {
      expect(fixedTableColumnWidths(1472, [256, 192, 192, 96]), [512, 384, 384, 192]);
    });
    test('automatic columns share what the fixed ones leave', () {
      expect(fixedTableColumnWidths(300, [100, null, null]), [100, 100, 100]);
    });
  });

  testWidgets('DifyTable gives the header and every row the same column widths', (t) async {
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 600,
            child: DifyTable(
              columns: const [
                DifyTableColumn(header: Text('A'), width: 40),
                DifyTableColumn(header: Text('B')),
              ],
              rows: [
                for (final s in ['short', 'a much longer cell'])
                  DifyTableRow(
                    cells: [
                      const SizedBox(width: 10, height: 10),
                      Text(s, key: ValueKey(s)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final a = t.getTopLeft(find.byKey(const ValueKey('short')));
    final b = t.getTopLeft(find.byKey(const ValueKey('a much longer cell')));
    expect(a.dx, b.dx);
    expect(t.getTopLeft(find.text('B')).dx, a.dx + 12); // the header's `pl-3`
  });
}
