import 'package:dify_sf_app/src/design/css_metrics.dart';
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

void main() {
  Future<void> fonts(WidgetTester t) async {
    await t.runAsync(() async {
      await useAppFonts();
      await DifyFonts.loadFor('zh-Hans');
    });
  }

  Widget page(Widget child, {double scale = 1}) => MaterialApp(
    theme: difyTheme(fontFamily: 'Noto Sans', fontFamilyFallback: DifyFonts.fallbackFamilies),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Material(child: Center(child: child)),
    ),
  );

  testWidgets('Chinese, Latin and mixed labels share the measured Chromium baseline', (t) async {
    await fonts(t);
    for (final (size, height, baseline) in [(12.0, 16.0, 12.0), (13.0, 16.0, 13.0), (14.0, 20.0, 15.0)]) {
      for (final text in ['Run', '测试运行', '运行 Run']) {
        await t.pumpWidget(
          page(
            DifyTextLine(
              text,
              style: TextStyle(fontSize: size, height: height / size),
            ),
          ),
        );
        final p = t.renderObject<RenderParagraph>(find.byType(RichText).last);
        expect(p.size.height, height, reason: '$text at $size');
        expect(
          p.getDryBaseline(p.constraints, TextBaseline.alphabetic),
          closeTo(baseline, .001),
          reason: '$text at $size',
        );
      }
    }
  });

  testWidgets('fixed lines stay fixed across mixed scripts, and text scaling is retained', (t) async {
    await fonts(t);
    await t.pumpWidget(
      page(const DifyTextLine('运行 Run\n第二行 Latin\n第三行', style: TextStyle(fontSize: 14, height: 20 / 14))),
    );
    expect(t.getSize(find.byType(RichText).last).height, 60);
    await t.pumpWidget(page(const DifyTextLine('运行 Run', style: TextStyle(fontSize: 14, height: 20 / 14)), scale: 2));
    final p = t.renderObject<RenderParagraph>(find.byType(RichText).last);
    expect(p.size.height, 40);
    expect(p.getDryBaseline(p.constraints, TextBaseline.alphabetic), closeTo(31, .001));
  });

  testWidgets('a placeholder and typed Chinese keep the same input baseline and box', (t) async {
    await fonts(t);
    await t.pumpWidget(
      page(
        const SizedBox(
          width: 260,
          child: DifyInput(value: '', placeholder: '测试运行'),
        ),
      ),
    );
    final hint = t.renderObject<RenderParagraph>(
      find.descendant(of: find.text('测试运行'), matching: find.byType(RichText)),
    );
    final hintBaseline =
        hint.localToGlobal(Offset.zero).dy + hint.getDryBaseline(hint.constraints, TextBaseline.alphabetic)!;
    final before = t.getRect(find.byType(DifyInput));
    await t.pumpWidget(
      page(
        const SizedBox(
          width: 260,
          child: DifyInput(value: '测试运行', placeholder: '测试运行'),
        ),
      ),
    );
    final editable = t.state<EditableTextState>(find.byType(EditableText)).renderEditable;
    final valueBaseline =
        editable.localToGlobal(Offset.zero).dy +
        editable.getDryBaseline(editable.constraints, TextBaseline.alphabetic)!;
    expect(valueBaseline, closeTo(hintBaseline, .001));
    expect(t.getRect(find.byType(DifyInput)), before);
  });

  testWidgets('inline widgets retain independent metrics instead of being forced into a label strut', (t) async {
    await fonts(t);
    await t.pumpWidget(
      page(
        const DifyTextLine.rich(
          TextSpan(
            children: [
              TextSpan(text: 'Label '),
              WidgetSpan(child: SizedBox(width: 30, height: 32)),
            ],
          ),
          style: TextStyle(fontSize: 14, height: 20 / 14),
        ),
      ),
    );
    final p = t.renderObject<RenderParagraph>(find.byType(RichText).last);
    expect(p.strutStyle, isNull);
    expect(p.size.height, greaterThanOrEqualTo(32));
  });

  testWidgets('the shared strut reads the actual primary font rather than hardcoded Noto metrics', (t) async {
    await fonts(t);
    const s = TextStyle(fontFamily: 'Noto Sans', fontSize: 14, height: 20 / 14);
    final strut = Css.lineStrut(s)!;
    expect(strut.fontFamily, 'Noto Sans');
    expect(strut.forceStrutHeight, isTrue);
    expect(Css.lineStrut(s.copyWith(fontFamily: 'Dify CJK SC'))!.fontSize, isNot(closeTo(strut.fontSize!, .01)));
  });

  testWidgets('locale fonts are loaded before switching and the loaded face can be reused', (t) async {
    await fonts(t);
    final heldStyle = difyStyle(DifyType.systemSmRegular, DifyColors.textPrimary);
    for (final (locale, region) in [
      ('zh-Hant', 'TC'),
      ('ja-JP', 'JP'),
      ('ko-KR', 'KR'),
      ('zh-HK', 'HK'),
      ('zh-Hans', 'SC'),
    ]) {
      await t.runAsync(() => DifyFonts.loadFor(locale));
      expect(DifyFonts.fallbackFamilies, ['Dify CJK $region']);
      expect(DifyFonts.resolveStyle(heldStyle).fontFamilyFallback, ['Dify CJK $region']);
    }
    expect(DifyFonts.regionFor('zh_TW'), 'TC');
    expect(DifyFonts.regionFor('en-US'), 'SC');
  });
}
