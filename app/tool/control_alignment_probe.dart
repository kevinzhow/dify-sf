// Actual design-system controls, not a replacement production renderer.
import 'dart:convert';

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
      home: DifyPage(body: Uri.base.queryParameters['set'] == 'forms' ? const _ControlGallery() : const _Probe()),
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

class _ControlGallery extends StatefulWidget {
  const _ControlGallery();
  @override
  State<_ControlGallery> createState() => _ControlGalleryState();
}

class _ControlGalleryState extends State<_ControlGallery> {
  String input = '', search = '', select = 'a', tab = 'a';
  bool checked = false, switched = false;
  int slider = 30, page = 1;
  num number = 13;
  List<String> tags = ['中文', 'Latin'];
  final keys = <String, GlobalKey>{};
  Widget entry(String id, Widget child, {double height = 54}) => SizedBox(
    height: height,
    child: Row(
      children: [
        SizedBox(
          width: 130,
          child: DifyTextLine(id, style: const TextStyle(fontSize: 11, height: 16 / 11)),
        ),
        SizedBox(key: keys.putIfAbsent(id, () => GlobalKey()), width: 300, child: child),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rows = <String, Object?>{};
      for (final e in keys.entries) {
        final r = e.value.currentContext?.findRenderObject();
        if (r is! RenderBox) continue;
        final p = r.localToGlobal(Offset.zero);
        rows[e.key] = {'x': p.dx, 'y': p.dy, 'width': r.size.width, 'height': r.size.height};
      }
      web.document.documentElement!.setAttribute('data-gallery-metrics', jsonEncode(rows));
      web.document.documentElement!.setAttribute(
        'data-gallery-state',
        jsonEncode({
          'input': input,
          'search': search,
          'select': select,
          'tab': tab,
          'checked': checked,
          'switch': switched,
          'slider': slider,
          'page': page,
          'number': number,
          'tags': tags,
        }),
      );
    });
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DifyTextLine(
            'Actual shared controls: geometry, typography, focus, selection, disabled, real input',
            style: TextStyle(fontSize: 16, height: 24 / 16),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    entry(
                      'input',
                      DifyInput(
                        value: input,
                        placeholder: '请输入 Create',
                        semanticLabel: 'gallery-input',
                        leading: const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: RemixIcon('add-line', size: 16),
                        ),
                        onChanged: (v) => setState(() => input = v),
                      ),
                    ),
                    entry(
                      'input-disabled',
                      const DifyInput(value: '中文 Latin', disabled: true, semanticLabel: 'gallery-disabled'),
                    ),
                    entry(
                      'input-invalid',
                      const DifyInput(value: '错误 Error', invalid: true, semanticLabel: 'gallery-invalid'),
                    ),
                    entry(
                      'search',
                      DifySearchInput(
                        value: search,
                        semanticLabel: 'gallery-search',
                        placeholder: '搜索 Search',
                        onValueChange: (v) => setState(() => search = v),
                      ),
                    ),
                    entry(
                      'number',
                      DifyNumberField(
                        value: number,
                        unit: '次 ms',
                        showControls: true,
                        semanticLabel: 'gallery-number',
                        onChanged: (v) => setState(() => number = v ?? 0),
                      ),
                    ),
                    entry(
                      'select',
                      DifySelect<String>(
                        value: select,
                        semanticLabel: 'gallery-select',
                        options: const [(value: 'a', label: '创建 Create'), (value: 'b', label: '运行 Run')],
                        onChanged: (v) => setState(() => select = v),
                      ),
                    ),
                    entry(
                      'select-disabled',
                      const DifySelect<String>(
                        value: 'a',
                        disabled: true,
                        options: [(value: 'a', label: '禁用 Disabled')],
                      ),
                    ),
                    entry(
                      'chip',
                      DifyChip(
                        value: select,
                        items: const [(value: 'a', name: '创建 Create'), (value: 'b', name: '运行 Run')],
                        onSelect: (o) => setState(() => select = o.value),
                        onClear: () => setState(() => select = ''),
                      ),
                    ),
                    entry(
                      'textarea',
                      const DifyTextarea(value: '中文 Latin\n第二行 descenders gyp', semanticLabel: 'gallery-textarea'),
                      height: 110,
                    ),
                    entry(
                      'checkbox-list',
                      DifyCheckboxList(
                        options: const [(value: 'a', label: '创建 Create'), (value: 'b', label: '运行 Run')],
                        value: [select],
                        showSearch: false,
                        showCount: false,
                        showSelectAll: false,
                        onChange: (v) => setState(() => select = v.firstOrNull ?? ''),
                      ),
                      height: 100,
                    ),
                    entry(
                      'tags',
                      DifyTagInput(items: tags, label: 'gallery-tags', onChange: (v) => setState(() => tags = v)),
                      height: 76,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    entry(
                      'checkbox',
                      Row(
                        children: [
                          DifyCheckbox(
                            checked: checked,
                            label: 'gallery-checkbox',
                            onChanged: (v) => setState(() => checked = v),
                          ),
                          const SizedBox(width: 8),
                          const DifyTextLine(
                            '创建 Create',
                            centerCap: true,
                            style: TextStyle(fontSize: 13, height: 16 / 13),
                          ),
                        ],
                      ),
                    ),
                    entry(
                      'radio',
                      DifyRadioGroup<String>(
                        value: select,
                        onValueChange: (v) => setState(() => select = v),
                        children: const [
                          DifyRadio<String>(value: 'a', label: '创建 Create'),
                          DifyRadio<String>(value: 'b', label: '运行 Run'),
                        ],
                      ),
                    ),
                    entry(
                      'switch',
                      Row(
                        children: [
                          DifySwitch(
                            checked: switched,
                            semanticLabel: 'gallery-switch',
                            onCheckedChange: (v) => setState(() => switched = v),
                          ),
                          const SizedBox(width: 8),
                          const DifyTextLine(
                            '开启 Enabled',
                            centerCap: true,
                            style: TextStyle(fontSize: 13, height: 16 / 13),
                          ),
                        ],
                      ),
                    ),
                    entry(
                      'segmented',
                      DifySegmentedControl<String>(
                        value: tab,
                        semanticLabel: 'gallery-segmented',
                        segments: const [
                          (value: 'a', label: '创建 Create', child: DifyTextLine('创建 Create')),
                          (value: 'b', label: '运行 Run', child: DifyTextLine('运行 Run')),
                        ],
                        onChanged: (v) => setState(() => tab = v),
                      ),
                    ),
                    entry(
                      'tabs',
                      DifyTabsList(
                        children: [
                          DifyTab(
                            label: '创建 Create',
                            active: tab == 'a',
                            style: DifyTabStyle.pill,
                            onPressed: () => setState(() => tab = 'a'),
                          ),
                          DifyTab(
                            label: '运行 Run',
                            active: tab == 'b',
                            style: DifyTabStyle.pill,
                            onPressed: () => setState(() => tab = 'b'),
                          ),
                        ],
                      ),
                    ),
                    entry(
                      'badge/kbd',
                      const Row(
                        spacing: 8,
                        children: [DifyBadge('创建 Create', uppercase: false), DifyKbd('Ctrl'), DifyKbd('K')],
                      ),
                    ),
                    entry(
                      'slider',
                      DifySlider(
                        value: slider,
                        semanticLabel: 'gallery-slider',
                        onChanged: (v) => setState(() => slider = v),
                      ),
                    ),
                    entry(
                      'pagination',
                      DifyPagination(page: page, totalPages: 3, onPageChange: (v) => setState(() => page = v)),
                    ),
                    entry(
                      'menu',
                      DifyMenuPopup(
                        width: 280,
                        children: [
                          DifyMenuItem(
                            leading: const RemixIcon('add-line', size: 16),
                            onSelect: () {},
                            child: const DifyTextLine('创建 Create'),
                          ),
                          const DifyMenuItem(disabled: true, child: DifyTextLine('禁用 Disabled')),
                        ],
                      ),
                      height: 94,
                    ),
                    entry('calendar', DifyCalendar(selected: DateTime(2026, 10, 23), onSelect: (_) {}), height: 300),
                    entry(
                      'tooltip',
                      const DifyTooltip(
                        content: DifyTextLine('提示 Tooltip'),
                        child: DifyTextLine('悬停 Hover', style: TextStyle(fontSize: 13, height: 16 / 13)),
                      ),
                    ),
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
