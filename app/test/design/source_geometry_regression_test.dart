// Dify 1.17.1 source geometry, independent of screenshot backgrounds/scores.
import 'package:dify_sf_app/src/design/css_metrics.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

Future<void> render(WidgetTester t, Widget child, {double scale = 1}) async {
  await useAppFonts();
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 300, child: child),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('TagInput wraps the native size=20 field rather than shrinking to its placeholder', (t) async {
    await render(t, DifyTagInput(items: const ['Alpha', 'Beta'], placeholder: 'Create', onChange: (_) {}));
    final input = find.byType(EditableText);
    expect(t.getSize(input).width, 174);
    expect(t.getTopLeft(input).dy, greaterThan(t.getBottomLeft(find.text('Alpha')).dy));
    expect(t.getSize(find.byType(DifyTagInput)).height, 60);
    await render(t, DifyTagInput(items: const [], placeholder: 'Create', onChange: (_) {}));
    expect(t.getSize(input).width, 174);
    expect(t.getSize(find.byType(DifyTagInput)).height, 30);
  });

  testWidgets('TagInput preserves a long text mirror and the workflow width cap at text scale', (t) async {
    await render(
      t,
      DifyTagInput(
        items: const [],
        placeholder: 'A long placeholder that exceeds the native input width',
        onChange: (_) {},
      ),
    );
    expect(t.getSize(find.byType(EditableText)).width, greaterThan(174));
    await render(
      t,
      DifyTagInput(items: const [], isInWorkflow: true, placeholder: 'Create', onChange: (_) {}),
      scale: 1.5,
    );
    expect(t.getSize(find.byType(EditableText)).width, 146);
  });

  test('intrinsic input widths derive from the selected font and scale', () {
    const style = TextStyle(fontFamily: 'Noto Sans', fontSize: 12);
    // OpenType OS/2.xAvgCharWidth=577, head xMax-xMin=3421, unitsPerEm=1000.
    expect(Css.nativeInputWidth(style, TextScaler.noScaling), 174);
    expect(Css.nativeInputWidth(style, const TextScaler.linear(2)), 348);
  });

  testWidgets('calendar days size from system-sm line box plus py-2, not a fixed 36px', (t) async {
    await render(t, DifyCalendar(selected: DateTime(2026, 10, 15), onSelect: (_) {}));
    final day = find.bySemanticsLabel('2026-10-15');
    expect(t.getSize(day).height, closeTo(32, .001));
    final first = t.getTopLeft(find.bySemanticsLabel('2026-09-27'));
    final nextWeek = t.getTopLeft(find.bySemanticsLabel('2026-10-04'));
    expect(nextWeek.dy - first.dy, closeTo(34, .001));
    await render(t, DifyCalendar(selected: DateTime(2026, 10, 15), onSelect: (_) {}), scale: 2);
    expect(t.getSize(day).height, closeTo(48, .001), reason: 'text scaling grows each day without clipping');
    expect(t.takeException(), isNull);
  });
}
