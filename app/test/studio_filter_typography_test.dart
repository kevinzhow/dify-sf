import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/studio/filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

void main() {
  for (final name in ['type', 'sort', 'creators']) {
    testWidgets('Studio $name trigger uses the same font edge before and after opening', (t) async {
      await t.runAsync(() async {
        await useAppFonts();
        await DifyFonts.loadFor('zh-Hans');
      });
      final Widget filter = switch (name) {
        'type' => AppTypeFilter(value: 'all', onChange: (_) {}),
        'sort' => AppSortFilter(value: 'last_modify', onChange: (_) {}),
        _ => CreatorsFilter(value: const [], members: const [], onChange: (_) {}),
      };
      const key = ValueKey('filter-frame');
      await t.pumpWidget(
        MaterialApp(
          theme: difyTheme(fontFamily: 'Noto Sans', fontFamilyFallback: DifyFonts.fallbackFamilies),
          home: Material(
            child: Center(
              child: KeyedSubtree(key: key, child: filter),
            ),
          ),
        ),
      );
      await t.pump();
      final label = find.descendant(of: find.byKey(key), matching: find.byType(DifyTextLine)).first;
      RenderParagraph paragraph() =>
          t.renderObject<RenderParagraph>(find.descendant(of: label, matching: find.byType(RichText)).first);
      final before = t.getRect(find.byKey(key));
      final p = paragraph();
      expect(p.getDryBaseline(p.constraints, TextBaseline.alphabetic), closeTo(12.641, .001));
      await t.tap(find.byKey(key));
      await t.pumpAndSettle();
      expect(t.getRect(find.byKey(key)), before);
      final after = paragraph();
      expect(after.getDryBaseline(after.constraints, TextBaseline.alphabetic), closeTo(12.641, .001));
      expect(t.takeException(), isNull);
    });
  }
}
