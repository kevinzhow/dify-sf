/// The Webhook Trigger's tables and response body editor (nodes/trigger-webhook/components: generic-table.tsx,
/// parameter-table.tsx, header-table.tsx, paragraph-input.tsx).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../../../../../design/dify_fonts.dart';
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
///
/// A phone (a dify-sf divergence): each row is one named item ("city, String, Required": its key, the selects' values
/// and the checked toggles) whose cells stay editable, at touch size (48 px rows; the text field, the select and the
/// checkbox are 48 px nodes), with Delete under a "…" in a column of its own inside the table's borders (the header and
/// the rows without a key keep that column empty, so the columns line up) and on a long press.
///
/// Every edit (a cell, Delete) applies to its row by the row's identity in the latest [data], so a select's sheet or a
/// field open while a collaborator adds, removes or moves rows still edits its own row, writes only that cell, and
/// writes nothing once the row is gone.
class GenericTable extends StatefulWidget {
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

  @override
  State<GenericTable> createState() => _GenericTableState();
}

class _GenericTableState extends State<GenericTable> {
  String get _primaryKey => widget.columns.where((c) => c.key == 'key' || c.key == 'name').firstOrNull?.key ?? 'key';

  /// Each data row's identity, in step with [GenericTable.data]: the rows are keyed by it (an open select, a focused
  /// field and the "…" stay with their row when rows are added, removed or moved above it), and every edit finds its
  /// row by it when it applies. The rows are plain maps without ids: identities follow them across a new list by the
  /// row's key, then its content, and the row this table just wrote by the value it wrote ([_follow]).
  late List<Object> _ids = [for (final _ in widget.data) Object()];

  /// The identity of the trailing virtual row; a value typed there appends a row that keeps it (the field keeps the
  /// focus), and a new virtual row gets a new one.
  Object _virtual = Object();

  /// What this table last handed to [GenericTable.onChange], its rows' identities and the cell it wrote ([edit]; none
  /// for a removal): until the next list comes, the rows may be known by what was sent (a name typed into the row)
  /// as well as by what was shown.
  ({List<Json> data, List<Object> ids, ({int index, String key, Object? value})? edit})? _sent;

  @override
  void didUpdateWidget(GenericTable old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      final sent = _sent;
      _ids = _follow(
        [
          if (sent != null)
            for (final (i, r) in sent.data.indexed) (row: r, id: sent.ids[i]),
          for (final (i, r) in old.data.indexed) (row: r, id: _ids[i]),
        ],
        widget.data,
        edit: sent?.edit,
      );
      if (_ids.contains(_virtual)) _virtual = Object();
    }
    _sent = null;
  }

  /// The identities of [next]'s rows. Each takes the identity of the first unclaimed [known] row (as sent, then as
  /// shown) with the same key, else the same content. Only the row this table's own last [edit] wrote may also be
  /// known by its place, and only if the row there now holds the value written and, for a cell other than the key,
  /// still the key it had (the owner may have normalised the rest of it). Any other row is new: a row another user put where a removed one was, also in the same frame as a
  /// keystroke, is not that row (its open select closes, its focused field goes, its pending action writes nothing).
  List<Object> _follow(
    List<({Json row, Object id})> known,
    List<Json> next, {
    ({int index, String key, Object? value})? edit,
  }) {
    final primary = _primaryKey;
    final taken = <Object>{};
    final out = List<Object?>.filled(next.length, null);
    void claim(bool Function(Json a, Json b) same) {
      for (final (i, row) in next.indexed) {
        if (out[i] != null) continue;
        for (final k in known) {
          if (!taken.contains(k.id) && same(k.row, row)) {
            taken.add(k.id);
            out[i] = k.id;
            break;
          }
        }
      }
    }

    claim((a, b) => _present(b[primary]) && '${a[primary]}' == '${b[primary]}');
    claim(mapEquals);
    if (edit case (:final index, :final key, :final value) when index < next.length && out[index] == null) {
      final (:row, :id) = known[index];
      String text(Object? v) => '${v ?? ''}';
      // The written value is there, and (for any cell but the key) the row's key is still the one it had: another
      // row with the same value in that cell is not the row.
      final written = text(next[index][key]) == text(value);
      final sameKey = key == primary || text(next[index][primary]) == text(row[primary]);
      if (!taken.contains(id) && written && sameKey) out[index] = id;
    }
    return [for (final id in out) id ?? Object()];
  }

  void _send(List<Json> data, List<Object> ids, [({int index, String key, Object? value})? edit]) {
    _sent = (data: data, ids: ids, edit: edit);
    widget.onChange(data);
  }

  /// Sets [key] to [value] in the row [id] of the table as it is when the edit applies (a select's sheet or a field
  /// may have been open while a collaborator added, removed or moved rows): only that cell changes, on the latest
  /// rows; the virtual row appends one; a row no longer there takes nothing.
  void _update(Object id, String key, Object? value) {
    final data = widget.data;
    if (widget.readonly) return;
    if (id == _virtual) {
      _send(
        [
          ...data,
          {...widget.emptyRowData, key: value},
        ],
        [..._ids, _virtual],
        (index: data.length, key: key, value: value),
      );
      return;
    }
    final index = _ids.indexOf(id);
    if (index < 0) return;
    _send(
      [
        for (final (i, r) in data.indexed) i == index ? {...r, key: value} : r,
      ],
      _ids,
      (index: index, key: key, value: value),
    );
  }

  /// Deletes the row [id] from the table as it is when the action runs (a phone's action sheet may have been open
  /// while a collaborator added, removed or changed rows): the other rows are the latest ones; nothing once the row is
  /// gone.
  void _remove(Object id) {
    final data = widget.data;
    if (widget.readonly) return;
    final index = _ids.indexOf(id);
    if (index < 0) return;
    _send(
      [
        for (final (i, r) in data.indexed)
          if (i != index) r,
      ],
      [
        for (final (i, x) in _ids.indexed)
          if (i != index) x,
      ],
    );
  }

  Widget _cell(TableColumn c, Json row, int? index, Object id, bool phone) {
    final readonly = widget.readonly;
    void change(Object? v) => _update(id, c.key, v);
    final value = row[c.key];
    return switch (c.type) {
      ColumnType.input => _InputCell(
        label: c.title,
        value: value is String ? value : '',
        placeholder: c.placeholder,
        disabled: readonly,
        varName: c.key == 'key' || c.key == 'name',
        onChanged: change,
        onFocus: widget.onTextFocus,
      ),
      ColumnType.select => _SelectCell(column: c, value: value, disabled: readonly, onChanged: change),
      ColumnType.toggle => _toggleCell(
        phone,
        DifyCheckbox(checked: value == true, label: c.title, disabled: readonly, onChanged: change),
        readonly ? null : () => change(value != true),
      ),
      ColumnType.custom => c.render?.call(value, row, index ?? -1, change) ?? const SizedBox.shrink(),
      ColumnType.unsupported => const SizedBox.shrink(),
    };
  }

  /// A phone's column widths for a table [tableWidth] wide, measured with the text as it is drawn (font and text
  /// scale): a select as wide as its longest value with its chevron, a toggle as wide as its title (at least its 48 px
  /// checkbox), at most Dify's widths; the name column takes the rest. Should that leave the name column narrower than
  /// its title, the selects give way (their longest values then end in "…", not the name column's title).
  Map<TableColumn, double?> _phoneWidths(BuildContext context, double tableWidth, {required bool moreColumn}) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        // As DifyText / DifyTextLine draw it (the resolved family and fallbacks).
        text: TextSpan(text: text, style: DifyFonts.resolveStyle(base.merge(style))),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    // The header as DifyText draws it (its own family, upper-cased); a value as the select's DifyTextLine does.
    final header = difyStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary);
    final value = difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary);
    double title(TableColumn c) =>
        _cellInset + measure(difyTransform(DifyType.systemXsMediumUppercase, c.title), header) + 4;
    final widths = <TableColumn, double?>{
      for (final c in widget.columns)
        c: switch ((c.type, c.width)) {
          (ColumnType.select, final w?) => math.min(
            w,
            math
                .max(
                  title(c),
                  _cellInset +
                      [
                        for (final o in c.options) measure(o.name, value),
                        measure(c.placeholder ?? '', value),
                      ].fold(0.0, math.max) +
                      _selectChevron +
                      4,
                )
                .ceilToDouble(),
          ),
          (ColumnType.toggle, final w?) => math.min(
            w,
            math.max(title(c), _cellInset + DifyTouch.minTarget).ceilToDouble(),
          ),
          (_, final w) => w,
        },
    };
    final flexible = [
      for (final c in widget.columns)
        if (widths[c] == null) c,
    ];
    if (flexible.isEmpty) return widths;
    final fixed = widths.values.whereType<double>().fold(0.0, (a, b) => a + b) + (moreColumn ? _moreWidth : 0);
    final need = flexible.map(title).fold(0.0, (a, b) => a + b);
    var deficit = need - (tableWidth - fixed);
    for (final c in widget.columns) {
      if (deficit <= 0) break;
      if (c.type != ColumnType.select || widths[c] == null) continue;
      final floor = math.max(title(c), _cellInset + _selectChevron + 24);
      final give = math.min(deficit, math.max(0.0, widths[c]! - floor));
      widths[c] = widths[c]! - give;
      deficit -= give;
    }
    return widths;
  }

  Widget _sized(TableColumn c, bool last, Widget child, Map<TableColumn, double?>? widths) {
    final width = widths == null ? c.width : widths[c];
    final box = Container(
      width: width,
      padding: const EdgeInsets.only(left: _cellInset),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(right: BorderSide(color: DifyColors.dividerRegular)),
            ),
      child: child,
    );
    return width == null ? Expanded(child: box) : box;
  }

  /// A phone row's name: its key, then the selects' values and the checked toggles' titles.
  String _rowName(Json row) => [
    '${row[_primaryKey] ?? ''}',
    for (final c in widget.columns)
      if (c.type == ColumnType.select)
        ?c.options.where((o) => o.value == row[c.key]).firstOrNull?.name
      else if (c.type == ColumnType.toggle && row[c.key] == true)
        c.title,
  ].where((s) => s.isNotEmpty).join(', ');

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final Widget body;
    if (w.readonly && w.data.isEmpty) {
      body = Container(
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          border: Border.all(color: DifyColors.dividerRegular),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: DifyTextLine(
          w.placeholder ?? '',
          style: difyStyle(DifyType.systemXsRegular, DifyColors.textQuaternary).copyWith(height: 18 / 12),
        ),
      );
    } else {
      final primary = _primaryKey;
      final rows = displayRows(w.data, w.emptyRowData, w.readonly);
      final phone = DifyTouch.compactOf(context);
      // A phone's "…" column (none when nothing can be deleted).
      final moreColumn = phone && !w.readonly;
      Widget table(Map<TableColumn, double?>? widths) => Container(
        decoration: BoxDecoration(
          border: Border.all(color: DifyColors.dividerRegular),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DifyRadius.lg - 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (w.showHeader)
                SizedBox(
                  height: 28,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, c) in w.columns.indexed)
                        _sized(
                          c,
                          i == w.columns.length - 1,
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DifyText(c.title, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
                          ),
                          widths,
                        ),
                      if (moreColumn) const SizedBox(width: _moreWidth),
                    ],
                  ),
                ),
              for (final (i, r) in rows.indexed)
                if (r.index == null ? _virtual : _ids[r.index!] case final id)
                  _TableRow(
                    key: ValueKey(id),
                    label: '${r.row[primary] ?? ''}',
                    name: _rowName(r.row),
                    last: i == rows.length - 1,
                    hasContent: _present(r.row[primary]),
                    moreColumn: moreColumn,
                    onDelete: !w.readonly && r.index != null && _present(r.row[primary]) ? () => _remove(id) : null,
                    children: [
                      for (final (j, c) in w.columns.indexed)
                        _sized(c, j == w.columns.length - 1, _cell(c, r.row, r.index, id, phone), widths),
                    ],
                  ),
            ],
          ),
        ),
      );
      // A phone measures its columns against the table's width (the name column keeps its title).
      body = phone
          ? LayoutBuilder(
              builder: (context, constraints) =>
                  table(_phoneWidths(context, constraints.maxWidth - 2, moreColumn: moreColumn)),
            )
          : table(null);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DifyText(w.title, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary),
        ),
        body,
      ],
    );
  }
}

/// The width of a phone row's "…" column (its 44 px button).
const _moreWidth = 44.0;

/// A cell's start inset (`pl-3`).
const _cellInset = 12.0;

/// A phone select's chevron and the gaps around it: 1 px before the 16 px icon, 4 px after it (a desktop trigger keeps
/// Dify's `pr-6` instead).
const _selectChevron = 1 + 16 + 4.0;

/// A toggle cell: the checkbox on the cell's text line (`h-7`). A phone: the whole 48 px cell is the checkbox's target
/// and its node (a tap anywhere in it toggles), the box still at the cell's start, under its column's title.
Widget _toggleCell(bool phone, Widget checkbox, VoidCallback? toggle) {
  final cell = SizedBox(
    height: phone ? DifyTouch.minTarget : 28,
    child: Align(alignment: Alignment.centerLeft, child: checkbox),
  );
  if (!phone) return cell;
  return MergeSemantics(
    child: GestureDetector(behavior: HitTestBehavior.opaque, excludeFromSemantics: true, onTap: toggle, child: cell),
  );
}

/// A row: `border-t border-divider-regular`, at least 28 px, and but for the [last] the rows' `divide-y
/// divide-divider-subtle` line below; hovered `bg-state-destructive-hover` when it has a primary key (else
/// `bg-state-base-hover`) and showing the "Delete row" bin on the right. A phone: see [GenericTable].
class _TableRow extends StatefulWidget {
  const _TableRow({
    super.key,
    required this.label,
    required this.name,
    required this.last,
    required this.hasContent,
    required this.moreColumn,
    required this.children,
    this.onDelete,
  });

  /// The row's key (its primary column); [name] is what a phone reads for the row (the key and its attributes).
  final String label, name;
  final bool last, hasContent, moreColumn;
  final List<Widget> children;
  final VoidCallback? onDelete;

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // A phone: no invisible bin (a blind tap there deleted the row); "…" (inside the row) and a long press offer
    // Delete. The cells stay the row's own fields.
    final phone = DifyTouch.compactOf(context);
    if (!phone) return _row(showBin: true);
    final delete = widget.onDelete;
    // One shape whether the row can be deleted or not: a row that gets its key as it is typed (the empty row) keeps
    // its cells, so the field being typed in keeps the focus and its caret.
    return DifyActionRow.builder(
      label: widget.label,
      semanticLabel: widget.name,
      actions: [if (delete != null) DifyActionRow.delete(delete)],
      builder: (context, more) => _row(
        showBin: false,
        more: more ?? (widget.moreColumn ? const SizedBox(width: _moreWidth) : null),
      ),
    );
  }

  Widget _row({required bool showBin, Widget? more}) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Container(
      constraints: BoxConstraints(minHeight: more != null ? DifyTouch.minTarget : 28),
      decoration: BoxDecoration(
        color: showBin && _hovered
            ? (widget.hasContent ? DifyColors.stateDestructiveHover : DifyColors.stateBaseHover)
            : null,
        border: Border(
          top: BorderSide(color: DifyColors.dividerRegular),
          bottom: widget.last ? BorderSide.none : BorderSide(color: DifyColors.dividerSubtle),
        ),
      ),
      child: Stack(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...widget.children,
                if (more != null) Center(child: more),
              ],
            ),
          ),
          if (widget.onDelete != null && showBin)
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
    final field = DifyTextField(
      controller: _controller,
      focusNode: _focus,
      enabled: !widget.disabled,
      style: style,
      cursorColor: DifyColors.primary600, // caret-primary-600
      cursorWidth: 1,
      inputFormatters: widget.varName ? [varNameFormatter] : null,
      onChanged: widget.onChanged,
      onSubmitted: (_) => _focus.unfocus(),
      decoration: DifyFieldDecoration.collapsed(
        hintText: widget.placeholder,
        hintStyle: style.copyWith(color: DifyColors.textQuaternary),
      ),
    );
    // A phone: the field is one node named by its column, as tall as the 48 px row (not the 24 px line); a tap
    // anywhere in the cell's height focuses it.
    if (DifyTouch.compactOf(context)) {
      return SizedBox(
        height: DifyTouch.minTarget,
        child: Center(
          child: DifyTouchTarget(
            accessible: true,
            child: Semantics(label: widget.label, child: field),
          ),
        ),
      );
    }
    return Semantics(
      label: widget.label,
      textField: true,
      // The `h-6` input stands on the cell's text line, half a pixel down.
      child: Padding(
        padding: const EdgeInsets.only(top: 0.5, bottom: 3.5),
        child: SizedBox(height: 24, child: Center(child: field)),
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
    // A phone: the trigger is the 48 px cell (its node too), named by its column and value.
    final phone = DifyTouch.compactOf(context);
    final name = selected?.name ?? column.placeholder;
    // The `h-6` trigger at the cell's top.
    return SizedBox(
      height: phone ? DifyTouch.minTarget : 28,
      child: Align(
        alignment: phone ? Alignment.centerLeft : Alignment.topLeft,
        child: DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          sideOffset: 4,
          alignOffset: -12,
          width: 104,
          semanticLabel: column.title,
          builder: (context, controller) => DifyPressable(
            disabled: disabled,
            onPressed: controller.toggle,
            semanticLabel: phone && name != null ? '${column.title}, $name' : name,
            builder: (context, hovered, _) => SizedBox(
              height: phone ? DifyTouch.minTarget : 24,
              child: Padding(
                padding: EdgeInsets.only(right: phone ? 4 : 24),
                child: Row(
                  spacing: 1,
                  children: [
                    Expanded(
                      child: DifyTextLine(
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
                  DifyMenuRadioItem<String>(value: o.value, closeOnClick: true, child: DifyTextLine(o.name)),
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
                    child: DifyTextLine('$i'.padLeft(2, '0'), style: text.copyWith(color: DifyColors.textQuaternary)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: DifyTextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !widget.disabled,
              minLines: count,
              maxLines: count,
              keyboardType: TextInputType.multiline,
              style: text,
              cursorColor: DifyColors.textSecondary, // paragraph-input.tsx: the default caret (text-text-secondary)
              cursorWidth: 1,
              onChanged: widget.onChange,
              decoration: DifyFieldDecoration.collapsed(
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
