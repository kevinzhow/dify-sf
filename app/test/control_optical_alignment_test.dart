import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

void main() {
  for (final (size, expectedBaseline) in [
    (DifyButtonSize.small, 12.284),
    (DifyButtonSize.medium, 12.641),
    (DifyButtonSize.large, 14.998),
  ]) {
    testWidgets('${size.name} control labels optically center without moving their hit/focus box', (t) async {
      await t.runAsync(() async {
        await useAppFonts();
        await DifyFonts.loadFor('zh-Hans');
      });
      final focus = FocusNode();
      addTearDown(focus.dispose);
      for (final variant in DifyButtonVariant.values.where((v) => v != DifyButtonVariant.plain)) {
        for (final label in ['创建', 'Create', '创建 App']) {
          for (final disabled in [false, true]) {
            await t.pumpWidget(
              MaterialApp(
                theme: difyTheme(fontFamily: 'Noto Sans', fontFamilyFallback: DifyFonts.fallbackFamilies),
                home: Material(
                  child: Center(
                    child: DifyButton(
                      size: size,
                      variant: variant,
                      disabled: disabled,
                      focusNode: focus,
                      onPressed: () {},
                      leading: const SizedBox(key: ValueKey('icon'), width: 16, height: 16),
                      child: DifyTextLine(label),
                    ),
                  ),
                ),
              ),
            );
            await t.pump();
            final p = t.renderObject<RenderParagraph>(find.byType(RichText).last);
            final reason = '${size.name}/${variant.name}/$label/disabled=$disabled';
            expect(
              p.getDryBaseline(p.constraints, TextBaseline.alphabetic),
              closeTo(expectedBaseline, .001),
              reason: reason,
            );
            final box = t.getRect(find.byType(DifyButton));
            expect(box.height, size.height, reason: reason);
            expect(
              t.getRect(find.byKey(const ValueKey('icon'))).center.dy,
              t.getRect(find.byType(DifyTextLine)).center.dy,
              reason: reason,
            );
            if (!disabled) {
              focus.requestFocus();
              await t.pump();
              expect(t.getRect(find.byType(DifyButton)), box, reason: reason);
            }
          }
        }
      }
    });
  }
  testWidgets('each actual typeface uses its own OpenType cap edge at every size and text scale', (t) async {
    await t.runAsync(() async {
      await useAppFonts();
      await DifyFonts.loadFor('zh-Hans');
      final mono = FontLoader('DejaVu Sans Mono')..addFont(rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
      await mono.load();
    });
    for (final (family, capRatio) in [
      ('Noto Sans', 714 / 1000),
      ('DejaVu Sans Mono', 1493 / 2048),
      ('Dify CJK SC', 733 / 1000),
    ]) {
      for (final size in [12.0, 13.0, 14.0, 18.0]) {
        for (final scale in [1.0, 2.0]) {
          final label = DifyControlLabelScope(
            child: DifyTextLine(
              'H 创建',
              style: TextStyle(fontFamily: family, fontSize: size, height: 24 / size),
            ),
          );
          await t.pumpWidget(
            MaterialApp(
              theme: difyTheme(fontFamily: family, fontFamilyFallback: DifyFonts.fallbackFamilies),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Material(child: Center(child: label)),
              ),
            ),
          );
          final p = t.renderObject<RenderParagraph>(find.byType(RichText).last);
          final baseline = p.getDryBaseline(p.constraints, TextBaseline.alphabetic)!;
          expect(
            baseline - size * scale * capRatio / 2,
            closeTo(p.size.height / 2, .002),
            reason: '$family $size scale $scale',
          );
        }
      }
    }
    expect(DifyFonts.capHeightRatio('Unknown OS font', FontWeight.w400), isNull);
  });
}
