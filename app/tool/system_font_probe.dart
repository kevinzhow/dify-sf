// Standalone research probe. It does not select this path for production text.
// Build: tool/build_web.sh --target tool/system_font_probe.dart --output <dir>
import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const _stack =
    '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", "Noto Sans", Arial, sans-serif';
const _samples = [
  '全部　过去 7 天　最近修改',
  '创建者 alice　排序方式',
  '繁體中文　日本語　한국어',
  'English Hg 0123456789',
  '中文 English 混排　用户名称',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  cardFontFamily = 'Noto Sans';
  runApp(
    DifyApplication(
      theme: difyTheme(fontFamily: 'Noto Sans'),
      home: const _Probe(),
      title: 'Dify system font research probe',
    ),
  );
}

class _Probe extends StatelessWidget {
  const _Probe();
  @override
  Widget build(BuildContext context) {
    final lang = Uri.base.queryParameters['lang'] ?? 'zh-Hans';
    final locale = Locale.fromSubtags(
      languageCode: lang.split('-').first,
      scriptCode: lang.contains('Hans')
          ? 'Hans'
          : lang.contains('Hant')
          ? 'Hant'
          : null,
    );
    return DifyPage(
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('系统字体研究原型：左边浏览器原生文字，右边当前 Flutter 文字。不会读取或上传字体文件。', style: TextStyle(fontSize: 16, height: 1.5)),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: HtmlElementView.fromTagName(
                    tagName: 'section',
                    onElementCreated: (element) {
                      final el = element as web.HTMLElement;
                      el.lang = lang;
                      el.style.cssText =
                          'padding:24px;box-sizing:border-box;color:#344054;background:#fff;font-family:$_stack';
                      final title = web.document.createElement('h2') as web.HTMLElement;
                      title.textContent = '浏览器原生 CSS 字体栈 ($lang)';
                      title.style.cssText = 'font-size:18px;line-height:28px;margin:0 0 16px;font-weight:400';
                      el.append(title);
                      for (final size in [13, 14, 16]) {
                        final height = size == 13
                            ? 16
                            : size == 14
                            ? 20
                            : 24;
                        for (final text in _samples) {
                          final row = web.document.createElement('div') as web.HTMLElement;
                          row.style.cssText = 'height:40px;display:flex;align-items:center';
                          final label = web.document.createElement('span') as web.HTMLElement;
                          label.textContent = text;
                          label.style.cssText =
                              'font-size:${size}px;line-height:${height}px;font-weight:400;background:#f2f4f7';
                          row.append(label);
                          el.append(row);
                        }
                      }
                      final input = web.document.createElement('input') as web.HTMLInputElement;
                      input.placeholder = '浏览器原生输入：中文 English';
                      input.style.cssText =
                          'font-family:$_stack;font-size:14px;line-height:20px;height:36px;padding:8px;border:1px solid #d0d5dd;border-radius:8px;box-sizing:border-box;width:100%';
                      el.append(input);
                    },
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: const Color(0xfffafafa),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('当前 Flutter / Noto Sans ($lang)', style: const TextStyle(fontSize: 18, height: 28 / 18)),
                          const SizedBox(height: 16),
                          for (final size in [13.0, 14.0, 16.0])
                            for (final text in _samples)
                              SizedBox(
                                height: 40,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: ColoredBox(
                                    color: const Color(0xfff2f4f7),
                                    child: Text(
                                      text,
                                      locale: locale,
                                      style: TextStyle(
                                        fontSize: size,
                                        fontWeight: FontWeight.w400,
                                        height:
                                            (size == 13
                                                ? 16
                                                : size == 14
                                                ? 20
                                                : 24) /
                                            size,
                                        leadingDistribution: TextLeadingDistribution.even,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          DifyInput(value: '', placeholder: '当前 Flutter 输入：中文 English', onChanged: (_) {}),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
