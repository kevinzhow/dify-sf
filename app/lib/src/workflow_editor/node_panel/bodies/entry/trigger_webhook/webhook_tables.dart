/// The Webhook Trigger's tables and response body editor (nodes/trigger-webhook/components: generic-table.tsx,
/// parameter-table.tsx, header-table.tsx, paragraph-input.tsx).
library;

import 'package:flutter/material.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../panel_fields/var_list.dart' show varNameFormatter;
import 'webhook_config.dart' show Json;
import 'webhook_default.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

/// A column's kind (`ColumnType`); [unsupported] cells render nothing.
enum ColumnType { input, select, toggle, custom, unsupported }

/// `ColumnConfig`: [width] null is `flex-1`.
class TableColumn {
  const TableColumn({
    required this.key,
    required this.title,
    required this.type,
    this.width,
    this.placeholder,
    this.options = const [],
    this.render,
  });

  final String key, title;
  final ColumnType type;
  final double? width;
  final String? placeholder;
  final List<({String name, String value})> options;

  /// A custom cell: (value, row, data index or -1, onChange).
  final Widget Function(Object? value, Json row, int index, ValueChanged<Object?> onChange)? render;
}

/// `isPresent`: a non-blank string, or a value other than '', null and false.
bool _present(Object? v) => v is String ? v.trim().isNotEmpty : !(v == null || v == false);

bool _emptyRow(Json row) => row.values.every((v) => v == '' || v == null || v == false);

/// `getDisplayRows`: read-only shows the rows; editable hides empty rows but the last and adds a virtual empty row
/// (data index null) after a non-empty last row.
List<({Json row, int? index})> displayRows(List<Json> data, Json emptyRow, bool readonly) {
  if (readonly) return [for (final (i, r) in data.indexed) (row: r, index: i)];
  if (data.isEmpty) {
    return [
      (row: {...emptyRow}, index: null),
    ];
  }
  return [
    for (final (i, r) in data.indexed)
      if (!_emptyRow(r) || i == data.length - 1) (row: r, index: i),
    if (!_emptyRow(data.last)) (row: {...emptyRow}, index: null),
  ];
}

/// GenericTable: a `system-sm-semibold-uppercase` title, then the rows in a `rounded-lg border-divider-regular`
/// table (an `h-7` header row with [showHeader]); editing the trailing virtual row appends one from [emptyRowData],
/// a row with a primary key (`key` or `name`) can be deleted on hover. Read-only without rows: the [placeholder] box.
/// [onTextFocus] tells when a text cell gains or loses the focus (a typing draft begins or ends).
class GenericTable extends StatelessWidget {
  const GenericTable({
    super.key,
    required this.title,
    required this.columns,
    required this.data,
    required this.onChange,
    required this.emptyRowData,
    this.readonly = false,
    this.placeholder,
    this.showHeader = false,
    this.onTextFocus,
  });

  final String title;
  final List<TableColumn> columns;
  final List<Json> data;
  final ValueChanged<List<Json>> onChange;
  final Json emptyRowData;
  final bool readonly, showHeader;
  final String? placeholder;
  final ValueChanged<bool>? onTextFocus;

  String get _primaryKey => columns.where((c) => c.key == 'key' || c.key == 'name').firstOrNull?.key ?? 'key';

  void _update(int? index, String key, Object? value) {
    if (readonly) return;
    if (index != null && index < data.length) {
      onChange([
        for (final (i, r) in data.indexed) i == index ? {...r, key: value} : r,
      ]);
      return;
    }
    onChange([
      ...data,
      {...emptyRowData, key: value},
    ]);
  }

  void _remove(int index) {
    if (readonly || index < 0 || index >= data.length) return;
    onChange([
      for (final (i, r) in data.indexed)
        if (i != index) r,
    ]);
  }

  Widget _cell(TableColumn c, Json row, int? index) {
    void change(Object? v) => _update(index, c.key, v);
    final value = row[c.key];
    return switch (c.type) {
      ColumnType.input => _InputCell(
        label: c.title,
        value: value is String ? value : '',
        placeholder: c.placeholder,
        disabled: readonly,
        varName: c.key == 'key' || c.key == 'name',
        onChanged: change,
        onFocus: onTextFocus,
      ),
      ColumnType.select => _SelectCell(column: c, value: value, disabled: readonly, onChanged: change),
      ColumnType.toggle => SizedBox(
        height: 28,
        child: Align(
          alignment: Alignment.centerLeft,
          child: DifyCheckbox(
            checked: value == true,
            label: c.title,
            disabled: readonly,
            onChanged: change,
          ),
        ),
      ),
      ColumnType.custom => c.render?.call(value, row, index ?? -1, change) ?? const SizedBox.shrink(),
      ColumnType.unsupported => const SizedBox.shrink(),
    };
  }

  Widget _sized(TableColumn c, bool last, Widget child) {
    final box = Container(
      width: c.width,
      padding: const EdgeInsets.only(left: 12),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(right: BorderSide(color: DifyColors.dividerRegular)),
            ),
      child: child,
    );
    return c.width == null ? Expanded(child: box) : box;
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (readonly && data.isEmpty) {
      body = Container(
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          border: Border.all(color: DifyColors.dividerRegular),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Text(
          placeholder ?? '',
          style: difyStyle(DifyType.systemXsRegular, DifyColors.textQuaternary).copyWith(height: 18 / 12),
        ),
      );
    } else {
      final primary = _primaryKey;
      final rows = displayRows(data, emptyRowData, readonly);
      body = Container(
        decoration: BoxDecoration(
          border: Border.all(color: DifyColors.dividerRegular),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DifyRadius.lg - 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showHeader)
                SizedBox(
                  height: 28,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, c) in columns.indexed)
                        _sized(
                          c,
                          i == columns.length - 1,
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DifyText(c.title, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
                          ),
                        ),
                    ],
                  ),
                ),
              for (final (i, r) in rows.indexed)
                _TableRow(
                  key: ValueKey('row-$i'),
                  last: i == rows.length - 1,
                  hasContent: _present(r.row[primary]),
                  onDelete: !readonly && r.index != null && _present(r.row[primary]) ? () => _remove(r.index!) : null,
                  children: [
                    for (final (j, c) in columns.indexed) _sized(c, j == columns.length - 1, _cell(c, r.row, r.index)),
                  ],
                ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DifyText(title, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary),
        ),
        body,
      ],
    );
  }
}

/// A row: `border-t border-divider-regular`, at least 28 px, and but for the [last] the rows' `divide-y
/// divide-divider-subtle` line below; hovered `bg-state-destructive-hover` when it has a primary key (else
/// `bg-state-base-hover`) and showing the "Delete row" bin on the right.
class _TableRow extends StatefulWidget {
  const _TableRow({super.key, required this.last, required this.hasContent, required this.children, this.onDelete});
  final bool last, hasContent;
  final List<Widget> children;
  final VoidCallback? onDelete;

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Container(
      constraints: const BoxConstraints(minHeight: 28),
      decoration: BoxDecoration(
        color: _hovered ? (widget.hasContent ? DifyColors.stateDestructiveHover : DifyColors.stateBaseHover) : null,
        border: Border(
          top: BorderSide(color: DifyColors.dividerRegular),
          bottom: widget.last ? BorderSide.none : BorderSide(color: DifyColors.dividerSubtle),
        ),
      ),
      child: Stack(
        children: [
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
          ),
          if (widget.onDelete != null)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: _hovered ? 1 : 0,
                  child: DifyPressable(
                    onPressed: widget.onDelete,
                    semanticLabel: 'Delete row',
                    builder: (context, _, _) => Padding(
                      padding: EdgeInsets.all(4),
                      child: RemixIcon('delete-bin-line', size: 14, color: DifyColors.textDestructive),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The borderless `h-6 system-sm-regular text-text-secondary` input of a cell; spaces become underscores in name
/// columns; Enter blurs.
class _InputCell extends StatefulWidget {
  const _InputCell({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.disabled,
    required this.varName,
    this.placeholder,
    this.onFocus,
  });
  final String label, value;
  final String? placeholder;
  final bool disabled, varName;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool>? onFocus;

  @override
  State<_InputCell> createState() => _InputCellState();
}

class _InputCellState extends State<_InputCell> {
  late final _controller = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode()..addListener(() => widget.onFocus?.call(_focus.hasFocus));

  @override
  void didUpdateWidget(_InputCell old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.value) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary);
    return Semantics(
      label: widget.label,
      textField: true,
      // The `h-6` input stands on the cell's text line, half a pixel down.
      child: Padding(
        padding: const EdgeInsets.only(top: 0.5, bottom: 3.5),
        child: SizedBox(
          height: 24,
          child: Center(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !widget.disabled,
              style: style,
              cursorColor: const Color(0xFF155EEF), // caret-primary-600
              cursorWidth: 1,
              inputFormatters: widget.varName ? [varNameFormatter] : null,
              onChanged: widget.onChanged,
              onSubmitted: (_) => _focus.unfocus(),
              decoration: InputDecoration.collapsed(
                hintText: widget.placeholder,
                hintStyle: style.copyWith(color: DifyColors.textQuaternary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small select of a cell: a transparent `h-6 pr-6 pl-0 system-xs-regular text-text-secondary` trigger with
/// its chevron, the options in a `w-26` popup.
class _SelectCell extends StatelessWidget {
  const _SelectCell({required this.column, required this.value, required this.disabled, required this.onChanged});
  final TableColumn column;
  final Object? value;
  final bool disabled;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = column.options.where((o) => o.value == value).firstOrNull;
    // The `h-6` trigger at the cell's top.
    return SizedBox(
      height: 28,
      child: Align(
        alignment: Alignment.topLeft,
        child: DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          sideOffset: 4,
          alignOffset: -12,
          width: 104,
          semanticLabel: column.title,
          builder: (context, controller) => DifyPressable(
            disabled: disabled,
            onPressed: controller.toggle,
            semanticLabel: selected?.name ?? column.placeholder,
            builder: (context, hovered, _) => SizedBox(
              height: 24,
              child: Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Row(
                  spacing: 1,
                  children: [
                    Expanded(
                      child: Text(
                        selected?.name ?? column.placeholder ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(
                          DifyType.systemXsRegular,
                          disabled ? DifyColors.componentsInputTextFilledDisabled : DifyColors.textSecondary,
                        ),
                      ),
                    ),
                    RemixIcon(
                      'arrow-down-s-line',
                      size: 16,
                      color: hovered || controller.isOpen ? DifyColors.textSecondary : DifyColors.textQuaternary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          children: [
            DifyMenuRadioGroup<String>(
              value: selected?.value,
              onValueChange: onChanged,
              children: [
                for (final o in column.options)
                  DifyMenuRadioItem<String>(value: o.value, closeOnClick: true, child: Text(o.name)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ParameterTable: Variable name / Type / Required; the types [createParameterTypeOptions] offers for
/// [contentType]. Rows without a name are dropped; a text/plain body keeps one string row, an octet-stream body one
/// file row.
class ParameterTable extends StatelessWidget {
  const ParameterTable({
    super.key,
    required this.title,
    required this.parameters,
    required this.onChange,
    this.readonly = false,
    this.placeholder,
    this.contentType,
    this.onTextFocus,
  });

  final String title;
  final List<Json> parameters;
  final ValueChanged<List<Json>> onChange;
  final bool readonly;
  final String? placeholder, contentType;
  final ValueChanged<bool>? onTextFocus;

  void _changed(List<Json> rows) {
    final ct = (contentType ?? '').toLowerCase();
    final textPlain = ct == 'text/plain', octet = ct == 'application/octet-stream';
    final normalized = [
      for (final r in rows)
        if (r['key'] case final String k when k.trim().isNotEmpty)
          <String, Object?>{
            'name': k,
            'type': textPlain
                ? 'string'
                : octet
                ? 'file'
                : normalizeParameterType(r['type']),
            'required': r['required'] == true,
          },
    ];
    onChange(textPlain || octet ? normalized.take(1).toList() : normalized);
  }

  @override
  Widget build(BuildContext context) {
    final options = createParameterTypeOptions(contentType);
    return GenericTable(
      title: title,
      columns: [
        TableColumn(
          key: 'key',
          title: _tw('nodes.triggerWebhook.varName'),
          type: ColumnType.input,
          placeholder: _tw('nodes.triggerWebhook.varNamePlaceholder'),
        ),
        TableColumn(
          key: 'type',
          title: _tw('nodes.triggerWebhook.varType'),
          type: ColumnType.select,
          width: 120,
          placeholder: _tw('nodes.triggerWebhook.varType'),
          options: options,
        ),
        TableColumn(key: 'required', title: _tw('nodes.triggerWebhook.required'), type: ColumnType.toggle, width: 88),
      ],
      data: [
        for (final p in parameters) {'key': p['name'], 'type': p['type'], 'required': p['required']},
      ],
      onChange: _changed,
      readonly: readonly,
      placeholder: placeholder ?? _tw('nodes.triggerWebhook.noParameters'),
      emptyRowData: {'key': '', 'type': options.firstOrNull?.value ?? 'string', 'required': false},
      showHeader: true,
      onTextFocus: onTextFocus,
    );
  }
}

/// HeaderTable ("Header Parameters"): Variable name / Required; rows without a name are dropped.
class HeaderTable extends StatelessWidget {
  const HeaderTable({
    super.key,
    required this.headers,
    required this.onChange,
    this.readonly = false,
    this.onTextFocus,
  });
  final List<Json> headers;
  final ValueChanged<List<Json>> onChange;
  final bool readonly;
  final ValueChanged<bool>? onTextFocus;

  @override
  Widget build(BuildContext context) => GenericTable(
    title: 'Header Parameters',
    columns: [
      TableColumn(
        key: 'name',
        title: _tw('nodes.triggerWebhook.varName'),
        type: ColumnType.input,
        placeholder: _tw('nodes.triggerWebhook.varNamePlaceholder'),
      ),
      TableColumn(key: 'required', title: _tw('nodes.triggerWebhook.required'), type: ColumnType.toggle, width: 88),
    ],
    data: [
      for (final h in headers) {'name': h['name'], 'required': h['required']},
    ],
    onChange: (rows) => onChange([
      for (final r in rows)
        if (r['name'] case final String n when n.trim().isNotEmpty) {'name': n, 'required': r['required'] == true},
    ]),
    readonly: readonly,
    placeholder: _tw('nodes.triggerWebhook.noHeaders'),
    emptyRowData: const {'name': '', 'required': false},
    showHeader: true,
    onTextFocus: onTextFocus,
  );
}

/// Tailwind's `font-mono` stack.
const _mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'Monaco', 'Consolas', 'Liberation Mono', 'DejaVu Sans Mono', 'monospace'],
);

/// ParagraphInput: `rounded-xl bg-components-input-bg-normal px-3 pt-3 pb-2` with a gutter of two-digit line numbers
/// (at least 3) beside a mono `text-xs leading-5` textarea of as many rows.
class ParagraphInput extends StatefulWidget {
  const ParagraphInput({
    super.key,
    required this.value,
    required this.onChange,
    this.placeholder,
    this.disabled = false,
    this.onFocus,
  });
  final String value;
  final ValueChanged<String> onChange;
  final String? placeholder;
  final bool disabled;
  final ValueChanged<bool>? onFocus;

  @override
  State<ParagraphInput> createState() => _ParagraphInputState();
}

class _ParagraphInputState extends State<ParagraphInput> {
  late final _controller = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode()..addListener(() => widget.onFocus?.call(_focus.hasFocus));

  @override
  void didUpdateWidget(ParagraphInput old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.value.isEmpty ? 1 : '\n'.allMatches(widget.value).length + 1;
    final count = lines < 3 ? 3 : lines;
    final text = _mono
        .merge(difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary))
        .copyWith(height: 20 / 12);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
      ),
      child: Stack(
        children: [
          IgnorePointer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 1; i <= count; i++)
                  SizedBox(
                    height: 20,
                    child: Text('$i'.padLeft(2, '0'), style: text.copyWith(color: DifyColors.textQuaternary)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !widget.disabled,
              minLines: count,
              maxLines: count,
              keyboardType: TextInputType.multiline,
              style: text,
              cursorColor: const Color(0xFF155EEF), // caret-primary-600
              cursorWidth: 1,
              onChanged: widget.onChange,
              decoration: InputDecoration.collapsed(
                hintText: widget.placeholder,
                hintStyle: text.copyWith(color: DifyColors.textQuaternary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
