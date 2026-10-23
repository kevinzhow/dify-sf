// Actual design-system controls, not a replacement production renderer.
import 'dart:convert';

import 'control_gallery.dart';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

final entries = <({String id, GlobalKey button, GlobalKey label, GlobalKey icon})>[];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DifyFonts.loadFor('zh-Hans');
  await DifyI18n.load('zh-Hans');
  final family = Uri.base.queryParameters['font'] ?? 'Noto Sans';
  cardFontFamily = family;
  final dark = Uri.base.queryParameters['theme'] == 'dark';
  DifyColors.useDark(dark);
  await IconCache.preload([
    ('assets/remix_icons/add-line.svg', DifyColors.componentsButtonPrimaryText),
    ('assets/remix_icons/arrow-down-s-line.svg', DifyColors.componentsButtonPrimaryText),
  ]);
  runApp(
    DifyApplication(
      theme: difyTheme(
        fontFamily: family,
        fontFamilyFallback: DifyFonts.fallbackFamilies,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      home: DifyPage(
        body: Uri.base.queryParameters['set'] == 'forms'
            ? DifyControlGallery(
                onLayout: (keys, state) {
                  final rows = <String, Object?>{};
                  for (final e in keys.entries) {
                    final r = e.value.currentContext?.findRenderObject();
                    if (r is! RenderBox) continue;
                    final p = r.localToGlobal(Offset.zero);
                    rows[e.key] = {'x': p.dx, 'y': p.dy, 'width': r.size.width, 'height': r.size.height};
                  }
                  web.document.documentElement!.setAttribute('data-gallery-metrics', jsonEncode(rows));
                  web.document.documentElement!.setAttribute('data-gallery-state', jsonEncode(state));
                },
              )
            : const _Probe(),
      ),
    ),
  );
}

class _Probe extends StatelessWidget {
  const _Probe();
  Map<String, double> rect(GlobalKey k) {
    final r = k.currentContext!.findRenderObject()! as RenderBox;
    final p = r.localToGlobal(Offset.zero);
    return {'x': p.dx, 'y': p.dy, 'width': r.size.width, 'height': r.size.height};
  }

  RenderParagraph? paragraph(RenderObject r) {
    if (r is RenderParagraph) return r;
    RenderParagraph? found;
    r.visitChildren((c) {
      found ??= paragraph(c);
    });
    return found;
  }

  Widget button(
    String id,
    String text,
    DifyButtonSize size,
    DifyButtonVariant variant, {
    bool disabled = false,
    bool loading = false,
  }) {
    final b = GlobalKey(), l = GlobalKey(), i = GlobalKey();
    entries.add((id: '${size.name}/$id', button: b, label: l, icon: i));
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox(
            width: 124,
            child: DifyTextLine(id, style: const TextStyle(fontSize: 11, height: 16 / 11)),
          ),
          DifyButton(
            key: b,
            variant: variant,
            size: size,
            onPressed: () {},
            disabled: disabled,
            loading: loading,
            semanticLabel: id,
            leading: SizedBox(key: i, width: 16, height: 16, child: const RemixIcon('add-line', size: 16)),
            trailing: const RemixIcon('arrow-down-s-line', size: 16),
            child: DifyTextLine(text, key: l),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    entries.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      web.document.documentElement!.setAttribute(
        'data-control-metrics',
        jsonEncode([
          for (final e in entries)
            {
              'id': e.id,
              'button': rect(e.button),
              'label': rect(e.label),
              'icon': rect(e.icon),
              'baseline': paragraph(e.label.currentContext!.findRenderObject()!)!.getDryBaseline(
                paragraph(e.label.currentContext!.findRenderObject()!)!.constraints,
                TextBaseline.alphabetic,
              ),
            },
        ]),
      );
    });
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DifyTextLine(
            'Actual Dify buttons: Chinese / Latin / mixed, all variants, sizes, disabled/loading',
            style: TextStyle(fontSize: 16, height: 24 / 16),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final size in DifyButtonSize.values)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DifyTextLine(size.name, style: const TextStyle(fontSize: 14, height: 20 / 14)),
                      for (final v in DifyButtonVariant.values.where((v) => v != DifyButtonVariant.plain))
                        for (final text in ['创建', 'Create', '创建 App']) button('${v.name} $text', text, size, v),
                      button('disabled 创建', '创建', size, DifyButtonVariant.primary, disabled: true),
                      button('loading 创建', '创建', size, DifyButtonVariant.primary, loading: true),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
