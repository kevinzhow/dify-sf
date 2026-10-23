/// Dify's CheckboxList (web/app/components/base/checkbox-list).
library;

import 'package:flutter/material.dart';

import '../../i18n/dify_i18n.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// base/checkbox-list: a bordered box with a header (select-all checkbox, [title], the selected count, a search
/// input; each part optional) over the options (`p-1`, at most [maxHeight] tall), each a checkbox and its label.
class DifyCheckboxList extends StatefulWidget {
  const DifyCheckboxList({
    super.key,
    required this.options,
    required this.value,
    required this.onChange,
    this.title = '',
    this.disabled = false,
    this.maxHeight,
    this.showSelectAll = true,
    this.showCount = true,
    this.showSearch = true,
  });

  final List<SelectOption<String>> options;
  final List<String> value;
  final ValueChanged<List<String>> onChange;
  final String title;
  final bool disabled, showSelectAll, showCount, showSearch;
  final double? maxHeight;

  @override
  State<DifyCheckboxList> createState() => _DifyCheckboxListState();
}

class _DifyCheckboxListState extends State<DifyCheckboxList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? w.options
        : [
            for (final o in w.options)
              if (o.label.toLowerCase().contains(q) || o.value.toLowerCase().contains(q)) o,
          ];
    final all = [for (final o in w.options) o.value];
    final allChecked = all.isNotEmpty && all.every(w.value.contains);
    final some = !allChecked && w.value.isNotEmpty;
    Widget list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            child: DifyTextLine(
              q.isEmpty
                  ? DifyI18n.tr('common', 'noData')
                  : DifyI18n.tr('common', 'operation.noSearchResults', {'content': w.title}),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: DifyColors.textTertiary),
            ),
          ),
        for (final o in shown)
          _CheckRow(
            label: o.label,
            checked: w.value.contains(o.value),
            disabled: w.disabled,
            onChanged: (on) => w.onChange(
              on
                  ? [...w.value, o.value]
                  : [
                      for (final v in w.value)
                        if (v != o.value) v,
                    ],
            ),
          ),
      ],
    );
    list = Padding(padding: const EdgeInsets.all(4), child: list);
    if (w.maxHeight != null) {
      list = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: w.maxHeight!),
        child: SingleChildScrollView(child: list),
      );
    }
    final header = w.showSelectAll || w.showSearch || w.title.isNotEmpty || (w.showCount && w.value.isNotEmpty);
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Row(
                spacing: 8,
                children: [
                  if (w.showSelectAll && q.isEmpty)
                    DifyCheckbox(
                      checked: allChecked,
                      indeterminate: some,
                      disabled: w.disabled,
                      label: DifyI18n.tr('common', 'operation.selectAll'),
                      onChanged: (on) => w.onChange(on ? all : const []),
                    ),
                  Expanded(
                    child: Row(
                      spacing: 4,
                      children: [
                        if (w.title.isNotEmpty)
                          Flexible(
                            child: DifyText(
                              w.title,
                              DifyType.systemXsSemiboldUppercase,
                              color: DifyColors.textSecondary,
                            ),
                          ),
                        if (w.showCount && w.value.isNotEmpty)
                          Flexible(
                            child: DifyBadge(DifyI18n.tr('common', 'operation.selectCount', {'count': w.value.length})),
                          ),
                      ],
                    ),
                  ),
                  if (w.showSearch)
                    SizedBox(
                      width: 160,
                      child: DifyInput(
                        value: _query,
                        height: 28,
                        placeholder: DifyI18n.tr('common', 'placeholder.search'),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                ],
              ),
            ),
          list,
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.checked, required this.disabled, required this.onChanged});
  final String label;
  final bool checked, disabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: disabled ? 0.5 : 1,
    child: DifyPressable(
      disabled: disabled,
      onPressed: () => onChanged(!checked),
      builder: (context, hovered, focused) => Semantics(
        checked: checked,
        label: label,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hovered ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Row(
            spacing: 8,
            children: [
              DifyCheckboxBox(checked: checked, disabled: disabled),
              Expanded(
                child: DifyText(label, DifyType.systemSmMedium, centerCap: true, color: DifyColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---- small parts -------------------------------------------------------------------------------------------------
