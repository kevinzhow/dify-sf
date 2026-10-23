// Shared actual-control fixture used by native typography and Wasm browser tests.
import 'package:flutter/widgets.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

class DifyControlGallery extends StatefulWidget {
  const DifyControlGallery({super.key, this.onLayout});
  final void Function(Map<String, GlobalKey>, Map<String, Object?>)? onLayout;
  @override
  State<DifyControlGallery> createState() => DifyControlGalleryState();
}

class DifyControlGalleryState extends State<DifyControlGallery> {
  String input = '', search = '', select = 'a', tab = 'a';
  bool checked = false, switched = false;
  int slider = 30, page = 1;
  num number = 13;
  List<String> tags = ['中文', 'Latin'];
  final keys = <String, GlobalKey>{};
  Widget entry(String id, Widget child, {double height = 54, double width = 300}) => SizedBox(
    height: height,
    child: Row(
      children: [
        SizedBox(
          width: 130,
          child: DifyTextLine(id, style: const TextStyle(fontSize: 11, height: 16 / 11)),
        ),
        SizedBox(key: keys.putIfAbsent(id, () => GlobalKey()), width: width, child: child),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onLayout?.call(keys, {
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
      });
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
                      'text-field',
                      const DifyTextField(
                        decoration: DifyFieldDecoration(hintText: '编辑 Edit', outlined: true),
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
                      width: 540,
                      height: 64,
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
                    entry(
                      'tab-slider',
                      DifyTabSliderPlain(
                        value: tab,
                        onChange: (v) => setState(() => tab = v),
                        options: const [
                          (value: 'a', text: DifyTextLine('创建 Create')),
                          (value: 'b', text: DifyTextLine('运行 Run')),
                        ],
                      ),
                    ),
                    entry(
                      'labeled-switch',
                      DifyLabeledSwitch(
                        title: const DifyTextLine('开启 Enabled'),
                        subtitle: const DifyTextLine('说明 Description'),
                        value: switched,
                        onChanged: (v) => setState(() => switched = v),
                      ),
                      height: 80,
                    ),
                    entry(
                      'collapse',
                      DifyCollapse<String>(
                        title: '展开 Expand',
                        items: const ['子项 Child'],
                        itemBuilder: (_, item) => DifyTextLine(item),
                      ),
                      height: 100,
                    ),
                    entry('calendar', DifyCalendar(selected: DateTime(2026, 10, 23), onSelect: (_) {}), height: 340),
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
