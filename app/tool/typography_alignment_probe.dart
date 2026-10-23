// Independent browser CSS/Flutter comparison. Not an alternate production renderer.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

var samples = ['Run', '测试运行', '运行 Run', 'Hgyp'];
final keys = <GlobalKey>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final language = Uri.base.queryParameters['lang'] ?? 'zh-Hans';
  final dark = Uri.base.queryParameters['theme'] == 'dark';
  await DifyFonts.loadFor(language);
  cardFontFamily = 'Noto Sans';
  DifyColors.useDark(dark);
  final region = DifyFonts.regionFor(language);
  samples = switch (region) {
    'JP' => ['Run', '実行テスト', '実行 Run', 'Hgyp'],
    'KR' => ['Run', '실행 테스트', '실행 Run', 'Hgyp'],
    'TC' || 'HK' => ['Run', '測試執行', '執行 Run', 'Hgyp'],
    _ => ['Run', '测试运行', '运行 Run', 'Hgyp'],
  };
  final css = web.document.createElement('style') as web.HTMLStyleElement;
  css.textContent =
      '''
@font-face{font-family:ProbeLatin;src:url(assets/assets/fonts/NotoSans-Regular.ttf);font-weight:400}
@font-face{font-family:ProbeLatin;src:url(assets/assets/fonts/NotoSans-Bold.ttf);font-weight:700}
@font-face{font-family:ProbeCJK;src:url(assets/assets/fonts/cjk/NotoSansCJK$region-Regular.woff2);font-weight:400}
@font-face{font-family:ProbeCJK;src:url(assets/assets/fonts/cjk/NotoSansCJK$region-Bold.woff2);font-weight:700}
''';
  web.document.head!.append(css);
  runApp(
    DifyApplication(
      theme: difyTheme(
        fontFamily: 'Noto Sans',
        fontFamilyFallback: DifyFonts.fallbackFamilies,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      home: DifyPage(body: _Probe()),
    ),
  );
}

class _Probe extends StatefulWidget {
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  String _input = "";
  RenderParagraph? paragraph(RenderObject r) {
    if (r is RenderParagraph) return r;
    RenderParagraph? found;
    r.visitChildren((child) {
      found ??= paragraph(child);
    });
    return found;
  }

  void report() {
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < keys.length; i++) {
      final p = paragraph(keys[i].currentContext!.findRenderObject()!);
      if (p == null) continue;
      final at = p.localToGlobal(Offset.zero);
      result.add({
        'index': i,
        'text': p.text.toPlainText(),
        'x': at.dx,
        'y': at.dy,
        'width': p.size.width,
        'height': p.size.height,
        'baseline': p.getDryBaseline(p.constraints, TextBaseline.alphabetic),
      });
    }
    web.document.documentElement!.setAttribute('data-flutter-typography', jsonEncode(result));
    web.document.documentElement!.setAttribute('data-flutter-input', _input);
  }

  @override
  Widget build(BuildContext context) {
    keys.clear();
    final color = '#${(DifyColors.textPrimary.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    final background = '#${(DifyColors.backgroundBody.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    WidgetsBinding.instance.addPostFrameCallback((_) => report());
    return Column(
      children: [
        const SizedBox(height: 20),
        const DifyTextLine(
          'Same font files: browser CSS (left) / Dify typography (right)',
          style: TextStyle(fontSize: 16, height: 24 / 16),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: HtmlElementView.fromTagName(
                  tagName: 'section',
                  onElementCreated: (element) {
                    final root = element as web.HTMLElement;
                    root.style.cssText =
                        'padding:0 24px;color:$color;background:$background;font-family:ProbeLatin,ProbeCJK;box-sizing:border-box';
                    var i = 0;
                    for (final size in [12, 13, 14]) {
                      final h = size == 14 ? 20 : 16;
                      for (final sample in samples) {
                        final row = web.document.createElement('div') as web.HTMLElement;
                        row.style.cssText = 'height:36px;display:flex;align-items:center;gap:8px';
                        final icon = web.document.createElement('div') as web.HTMLElement;
                        icon.style.cssText = 'width:16px;height:16px;background:#3b82f6;flex-shrink:0';
                        final label = web.document.createElement('div') as web.HTMLElement;
                        label.className = 'probe-label';
                        label.setAttribute('data-index', '${i++}');
                        label.style.cssText = 'font-size:${size}px;line-height:${h}px;font-weight:400;white-space:pre';
                        label.textContent = sample;
                        final marker = web.document.createElement('i') as web.HTMLElement;
                        marker.style.cssText = 'display:inline-block;vertical-align:baseline;height:0;width:0';
                        label.append(marker);
                        row.append(icon);
                        row.append(label);
                        root.append(row);
                      }
                    }
                    final input = web.document.createElement('input') as web.HTMLInputElement;
                    input.id = 'css-probe-input';
                    input.placeholder = samples[1];
                    input.style.cssText =
                        'margin-top:16px;width:260px;height:32px;box-sizing:border-box;padding:7px 12px;border:1px solid transparent;border-radius:8px;outline:none;font-family:inherit;font-size:13px;line-height:16px;color:$color;background:$background';
                    root.append(input);
                  },
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final size in [12.0, 13.0, 14.0])
                        for (final sample in samples)
                          SizedBox(
                            height: 36,
                            child: Row(
                              spacing: 8,
                              children: [
                                const SizedBox(width: 16, height: 16, child: ColoredBox(color: Color(0xff3b82f6))),
                                DifyTextLine(
                                  sample,
                                  key: (() {
                                    final key = GlobalKey();
                                    keys.add(key);
                                    return key;
                                  })(),
                                  style: TextStyle(
                                    fontSize: size,
                                    height: (size == 14 ? 20 : 16) / size,
                                    color: DifyColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 260,
                        child: DifyInput(
                          value: _input,
                          placeholder: samples[1],
                          semanticLabel: 'Probe input',
                          onChanged: (value) => setState(() => _input = value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
