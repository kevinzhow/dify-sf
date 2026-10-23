import 'package:collab_client/collab_client.dart' show AppSortBy;
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/studio/filters.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';
import '../support/app_fonts.dart';

void main() {
  testWidgets('Studio sort uses a 4px gap and 32px box even with large Material button defaults', (t) async {
    await useAppFonts();
    useDifyTestTranslator();
    final theme = difyTheme(fontFamily: 'Noto Sans').copyWith(
      visualDensity: VisualDensity.comfortable,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(200, 80))),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Material(
          child: Center(
            child: AppSortFilter(value: AppSortBy.lastModified, onChange: (_) {}),
          ),
        ),
      ),
    );
    final label = find.text('app.studio.sort.sortBy');
    final active = find.text('app.studio.sort.lastModified');
    expect(t.getTopLeft(active).dx - t.getTopRight(label).dx, 4);
    expect(t.getSize(find.byType(AppSortFilter)).height, 32);
  });

  testWidgets('keyboard focus ring never changes the sort label geometry', (t) async {
    await useAppFonts();
    useDifyTestTranslator();
    final strategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
    await t.pumpWidget(
      MaterialApp(
        theme: difyTheme(fontFamily: 'Noto Sans'),
        home: Material(
          child: Center(
            child: AppSortFilter(value: AppSortBy.lastModified, onChange: (_) {}),
          ),
        ),
      ),
    );
    final label = find.text('app.studio.sort.sortBy');
    final before = t.getRect(label);
    final box = t.getRect(find.byType(AppSortFilter));
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
    expect(t.getRect(label), before, reason: 'CSS ring paints outside instead of insetting the text');
    expect(t.getRect(find.byType(AppSortFilter)), box);
  });

  testWidgets('inspector text baseline does not acquire desktop compact-density offset', (t) async {
    await useAppFonts();
    Rect? standard;
    for (final explicitStandard in [true, false]) {
      final base = difyTheme(fontFamily: 'Noto Sans');
      await t.pumpWidget(
        MaterialApp(
          key: ValueKey(explicitStandard),
          theme: explicitStandard ? base.copyWith(visualDensity: VisualDensity.standard) : base,
          home: const Material(
            child: Center(
              child: SizedBox(
                width: 240,
                height: 100,
                child: InspectTextarea(value: 'baseline', label: 'Value'),
              ),
            ),
          ),
        ),
      );
      final editable = find.byType(EditableText);
      final box = t.state<EditableTextState>(editable).renderEditable;
      // EditableText itself owns RenderEditable, and this comparison concerns the
      // actual painted text origin in the production inspector, not a theme getter.
      final origin = box.localToGlobal(Offset.zero);
      final rect = origin & box.size;
      if (explicitStandard) {
        standard = rect;
      } else {
        expect(rect, standard);
      }
    }
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));
}
