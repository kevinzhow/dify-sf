import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/control_gallery.dart';
import 'support/app_fonts.dart';

void main() {
  for (final family in ['Noto Sans', 'DejaVu Sans Mono', 'Dify CJK SC']) {
    for (final dark in [false, true]) {
      testWidgets('actual control gallery: $family dark=$dark labels, editing, focus, popup and selection', (t) async {
        await t.runAsync(() async {
          await useAppFonts();
          await DifyFonts.loadFor('zh-Hans');
          await DifyI18n.load('zh-Hans');
          final mono = FontLoader('DejaVu Sans Mono')..addFont(rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
          await mono.load();
        });
        await t.binding.setSurfaceSize(const Size(1440, 1800));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final oldFamily = cardFontFamily;
        cardFontFamily = family;
        DifyColors.useDark(dark);
        addTearDown(() {
          cardFontFamily = oldFamily;
          DifyColors.useDark(false);
        });
        Map<String, GlobalKey> keys = {};
        Map<String, Object?> state = {};
        await t.pumpWidget(
          MaterialApp(
            theme: difyTheme(
              fontFamily: family,
              fontFamilyFallback: DifyFonts.fallbackFamilies,
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: Material(
              child: DifyControlGallery(
                onLayout: (k, s) {
                  keys = k;
                  state = s;
                },
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(
          keys.keys.toSet(),
          containsAll([
            'input',
            'text-field',
            'input-disabled',
            'input-invalid',
            'search',
            'number',
            'select',
            'select-disabled',
            'chip',
            'textarea',
            'checkbox-list',
            'tags',
            'checkbox',
            'radio',
            'switch',
            'segmented',
            'tabs',
            'tab-slider',
            'labeled-switch',
            'collapse',
            'badge/kbd',
            'slider',
            'pagination',
            'menu',
            'calendar',
            'tooltip',
          ]),
        );
        void checkLabels() {
          var checked = 0;
          for (final e in find.byType(DifyTextLine).evaluate()) {
            final label = e.widget as DifyTextLine;
            if (!label.centerCap && !DifyControlLabelScope.of(e)) continue;
            final rich = find.descendant(of: find.byWidget(label), matching: find.byType(RichText)).first;
            final p = t.renderObject<RenderParagraph>(rich);
            final style = (p.text as TextSpan).style!;
            // Independently specified font-file values, not the production metric lookup.
            final cap = switch (style.fontFamily) {
              'DejaVu Sans Mono' => 1493 / 2048,
              'Dify CJK SC' => 733 / 1000,
              _ => 714 / 1000,
            };
            expect(
              p.getDryBaseline(p.constraints, TextBaseline.alphabetic),
              closeTo((p.size.height + style.fontSize! * cap) / 2, .002),
              reason: '${label.data} / ${style.fontFamily}',
            );
            checked++;
          }
          expect(checked, greaterThan(35));
          expect(t.takeException(), isNull, reason: 'no layout overflow or framework errors');
        }

        checkLabels();
        final field = find.descendant(of: find.byKey(keys['input']!), matching: find.byType(EditableText));
        final before = t.getRect(find.byKey(keys['input']!));
        await t.tap(field);
        await t.enterText(field, '创建 Create gyp');
        await t.pump();
        expect(state['input'], '创建 Create gyp');
        expect(t.getRect(find.byKey(keys['input']!)), before);
        final select = find.byKey(keys['select']!);
        final trigger = t.getRect(select);
        await t.tap(select);
        await t.pumpAndSettle();
        checkLabels();
        expect(t.getRect(select), trigger);
        await t.tap(find.byType(DifyMenuRadioItem<String>).last);
        await t.pumpAndSettle();
        expect(state['select'], 'b');
        expect(t.getRect(select), trigger);
        checkLabels();
      });
    }
  }
  testWidgets('chip clear action stays inside its painted trigger under tight or minimum widths', (t) async {
    for (final width in [null, 200.0]) {
      var cleared = false;
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: Center(
              child: SizedBox(
                width: 300,
                child: DifyChip(
                  value: 'a',
                  minWidth: width,
                  items: const [(value: 'a', name: '创建 Create')],
                  onSelect: (_) {},
                  onClear: () => cleared = true,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      final actions = find.descendant(of: find.byType(DifyChip), matching: find.byType(DifyPressable));
      final trigger = t.getRect(actions.first);
      final clear = t.getRect(actions.last);
      expect(trigger.contains(clear.center), isTrue);
      expect(clear.right, lessThanOrEqualTo(trigger.right));
      await t.tap(actions.last);
      expect(cleared, isTrue);
      expect(t.takeException(), isNull);
    }
  });
}
