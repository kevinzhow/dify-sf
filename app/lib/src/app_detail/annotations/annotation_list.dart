/// web/app/components/app/annotation/list.tsx and batch-action.tsx: the annotation table with its checkboxes (a
/// CheckboxGroup with a select-all parent), the row actions (edit, remove with confirmation) and, while rows are
/// selected, the floating batch action bar.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show Annotation;
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../auth/account_time.dart';
import 'annotation_overlays.dart';
import 'confirm_modals.dart';

String _t(String ns, String key) => DifyI18n.tr(ns, key);

/// `useTimestamp().formatTime(seconds, format)`; tests replace it.
typedef AnnotationTimeFormatter = String Function(int seconds, String format);

/// List: the table (`min-w-110`, scrolling), the remove confirmation and the batch action bar floating near the
/// bottom (`absolute bottom-20 left-0`) while [selectedIds] is not empty. Needs a bounded height (the page's rest).
class AnnotationList extends StatefulWidget {
  const AnnotationList({
    super.key,
    required this.list,
    required this.onView,
    required this.onRemove,
    required this.selectedIds,
    required this.onSelectedIdsChange,
    required this.onBatchDelete,
    this.formatTime,
  });

  final List<Annotation> list;
  final ValueChanged<Annotation> onView;
  final ValueChanged<String> onRemove;
  final List<String> selectedIds;
  final ValueChanged<List<String>> onSelectedIdsChange;
  final Future<void> Function() onBatchDelete;

  /// Null: the account's time zone ([AccountTime.of], Dify's `useTimestamp`).
  final AnnotationTimeFormatter? formatTime;

  @override
  State<AnnotationList> createState() => _AnnotationListState();
}

class _AnnotationListState extends State<AnnotationList> {
  String? _currId;
  bool _showConfirmDelete = false;

  void _toggle(String id, bool checked) {
    final next = [...widget.selectedIds.where((x) => x != id), if (checked) id];
    // CheckboxGroup keeps the group's order (allValues).
    widget.onSelectedIdsChange([
      for (final i in widget.list)
        if (next.contains(i.id)) i.id,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ids = [for (final i in widget.list) i.id];
    final selected = ids.where(widget.selectedIds.contains).length;
    final all = ids.isNotEmpty && selected == ids.length;
    final dateFormat = _t('appLog', 'dateTimeFormat');
    final created = [
      for (final item in widget.list)
        (widget.formatTime ?? AccountTime.of(context).formatTime)(item.createdAt, dateFormat),
    ];
    return Stack(
      fit: StackFit.expand,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final widths = annotationColumnWidths(
              box.maxWidth,
              widget.list,
              created,
              base: DefaultTextStyle.of(context).style,
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HeaderRow(
                    widths: widths,
                    selectAll: DifyCheckbox(
                      checked: all,
                      indeterminate: selected > 0 && !all,
                      label: _t('common', 'operation.selectAll'),
                      onChanged: (_) => widget.onSelectedIdsChange(all ? const [] : ids),
                    ),
                  ),
                  for (final (i, item) in widget.list.indexed)
                    _Row(
                      key: ValueKey('annotation-row-${item.id}'),
                      item: item,
                      widths: widths,
                      checked: widget.selectedIds.contains(item.id),
                      createdAt: created[i],
                      onChecked: (v) => _toggle(item.id, v),
                      onView: () => widget.onView(item),
                      onRemove: () => setState(() {
                        _currId = item.id;
                        _showConfirmDelete = true;
                      }),
                    ),
                ],
              ),
            );
          },
        ),
        if (widget.selectedIds.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 64,
            child: AnnotationBatchAction(
              selectedIds: widget.selectedIds,
              onBatchDelete: widget.onBatchDelete,
              onSelectedIdsChange: widget.onSelectedIdsChange,
            ),
          ),
        RemoveAnnotationConfirmModal(
          isShow: _showConfirmDelete,
          onHide: () => setState(() => _showConfirmDelete = false),
          onRemove: () {
            widget.onRemove(_currId!);
            setState(() => _showConfirmDelete = false);
          },
        ),
      ],
    );
  }
}

/// The fixed columns: the checkbox `w-12`, the actions `w-24`.
const _checkW = 48.0, _actionsW = 96.0;

/// The table's column widths as the browser's automatic table layout makes them: the checkbox and actions columns
/// fixed; the question column (`w-5` in the header) as wide as its widest cell; the answer, created-at and hits
/// columns their widest cell plus a share of the remaining width in proportion to it. Question and answer cells
/// count at most `max-w-62.5` of text.
List<double> annotationColumnWidths(
  double width,
  List<Annotation> list,
  List<String> created, {
  TextStyle base = const TextStyle(),
}) {
  double measure(String s, DifyTextStyle st) => (TextPainter(
    text: TextSpan(text: difyTransform(st, s), style: base.merge(st.style)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout()).width;
  double head(String key, double padding) =>
      measure(_t('appAnnotation', key), DifyType.systemXsMediumUppercase) + padding;
  double cells(Iterable<String> texts, {double cap = double.infinity}) => texts.fold(
    0.0,
    (m, s) => [
      m,
      [measure(s, DifyType.systemSmRegular), cap].reduce((a, b) => a < b ? a : b) + 20,
    ].reduce((a, b) => a > b ? a : b),
  );
  final question = [
    head('table.header.question', 12),
    cells([for (final i in list) i.question], cap: 250),
  ].reduce((a, b) => a > b ? a : b);
  final auto = [
    [
      head('table.header.answer', 12),
      cells([for (final i in list) i.answer], cap: 250),
    ].reduce((a, b) => a > b ? a : b),
    [head('table.header.createdAt', 12), cells(created)].reduce((a, b) => a > b ? a : b),
    [
      head('table.header.hits', 12),
      cells([for (final i in list) '${i.hitCount}']),
    ].reduce((a, b) => a > b ? a : b),
  ];
  final sum = auto.reduce((a, b) => a + b);
  final rest = width - _checkW - question - _actionsW;
  final scale = sum <= 0 ? 1.0 : rest / sum;
  return [_checkW, question, for (final w in auto) w * scale, _actionsW];
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.selectAll, required this.widths});
  final Widget selectAll;
  final List<double> widths;

  @override
  Widget build(BuildContext context) {
    Widget cell(String key, {double? width, EdgeInsets padding = const EdgeInsets.only(left: 12)}) {
      final text = Padding(
        padding: padding,
        child: Text(
          difyTransform(DifyType.systemXsMediumUppercase, _t('appAnnotation', key)),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
        ),
      );
      return SizedBox(width: width, child: text);
    }

    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: DifyColors.backgroundSectionBurn,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Row(
        children: [
          SizedBox(
            width: widths[0],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(alignment: AlignmentDirectional.centerStart, child: selectAll),
            ),
          ),
          cell('table.header.question', width: widths[1], padding: const EdgeInsets.only(left: 8, right: 4)),
          cell('table.header.answer', width: widths[2]),
          cell('table.header.createdAt', width: widths[3]),
          cell('table.header.hits', width: widths[4]),
          cell('table.header.actions', width: widths[5]),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.item,
    required this.widths,
    required this.checked,
    required this.createdAt,
    required this.onChecked,
    required this.onView,
    required this.onRemove,
  });

  final Annotation item;
  final List<double> widths;
  final bool checked;
  final String createdAt;
  final ValueChanged<bool> onChecked;
  final VoidCallback onView, onRemove;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary);
    Widget text(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 250),
        child: Text(s, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style),
      ),
    );
    final item = widget.item;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onView,
        child: Container(
          decoration: BoxDecoration(
            color: _hovered ? DifyColors.backgroundDefaultHover : null,
            border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
          ),
          child: Row(
            children: [
              // The checkbox cell stops the row's click.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: SizedBox(
                  width: widget.widths[0],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: DifyCheckbox(checked: widget.checked, label: item.question, onChanged: widget.onChecked),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: widget.widths[1],
                child: _CellTitle(message: item.question, child: text(item.question)),
              ),
              SizedBox(
                width: widget.widths[2],
                child: _CellTitle(message: item.answer, child: text(item.answer)),
              ),
              SizedBox(width: widget.widths[3], child: text(widget.createdAt)),
              SizedBox(width: widget.widths[4], child: text('${item.hitCount}')),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: SizedBox(
                  width: widget.widths[5],
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                    child: Row(
                      spacing: 4,
                      children: [
                        DifyIconButton(
                          label: _t('appDebug', 'feature.annotation.edit'),
                          icon: RemixIcon('edit-line', size: 16, color: DifyColors.textTertiary),
                          onPressed: widget.onView,
                        ),
                        DifyIconButton(
                          label: _t('appDebug', 'feature.annotation.remove'),
                          icon: RemixIcon('delete-bin-line', size: 16, color: DifyColors.textTertiary),
                          onPressed: widget.onRemove,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cell's `title` (the full text on hover): kept as the semantics' tooltip, no visual tooltip (a browser's
/// native title tooltip has no dify-ui look to copy).
class _CellTitle extends StatelessWidget {
  const _CellTitle({required this.message, required this.child});
  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(tooltip: message, child: child);
}

/// BatchAction: the `rounded-[10px] border-components-actionbar-border-accent bg-components-actionbar-bg-accent p-1
/// shadow-xl` bar centred over the page: the selected count, "Selected", Delete (asks "Are you sure Delete?" first)
/// and Cancel (clears the selection).
class AnnotationBatchAction extends StatefulWidget {
  const AnnotationBatchAction({
    super.key,
    required this.selectedIds,
    required this.onBatchDelete,
    required this.onSelectedIdsChange,
  });

  final List<String> selectedIds;
  final Future<void> Function() onBatchDelete;
  final ValueChanged<List<String>> onSelectedIdsChange;

  @override
  State<AnnotationBatchAction> createState() => _AnnotationBatchActionState();
}

class _AnnotationBatchActionState extends State<AnnotationBatchAction> {
  bool _showDeleteConfirm = false, _deleting = false;

  Future<void> _batchDelete() async {
    setState(() => _deleting = true);
    try {
      await widget.onBatchDelete();
    } finally {
      if (mounted) {
        setState(() {
          _showDeleteConfirm = false;
          _deleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget divider() => Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: DifyColors.dividerRegular,
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: DifyColors.componentsActionbarBgAccent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DifyColors.componentsActionbarBorderAccent),
            boxShadow: [
              for (final s in DifyShadows.xl)
                BoxShadow(
                  offset: s.offset,
                  blurRadius: s.blurRadius,
                  spreadRadius: s.spreadRadius,
                  color: DifyColors.shadowShadow5,
                ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: DifyColors.textAccent,
                        borderRadius: BorderRadius.circular(DifyRadius.md),
                      ),
                      child: Text(
                        '${widget.selectedIds.length}',
                        style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimaryOnSurface),
                      ),
                    ),
                    Text(
                      _t('appAnnotation', 'batchAction.selected'),
                      style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textAccent),
                    ),
                  ],
                ),
              ),
              divider(),
              DifyButton(
                variant: DifyButtonVariant.ghost,
                tone: DifyButtonTone.destructive,
                leading: RemixIcon('delete-bin-line', size: 16, color: DifyColors.textDestructive),
                onPressed: () => setState(() => _showDeleteConfirm = true),
                child: Text(_t('common', 'operation.delete')),
              ),
              divider(),
              DifyButton(
                variant: DifyButtonVariant.ghost,
                onPressed: () => widget.onSelectedIdsChange(const []),
                child: Text(_t('common', 'operation.cancel')),
              ),
            ],
          ),
        ),
        AnnotationAlertDialog(
          open: _showDeleteConfirm,
          title: _t('appAnnotation', 'list.delete.title'),
          confirmLabel: _t('common', 'operation.delete'),
          loading: _deleting,
          onCancel: () => setState(() => _showDeleteConfirm = false),
          onConfirm: () => unawaited(_batchDelete()),
        ),
      ],
    );
  }
}
