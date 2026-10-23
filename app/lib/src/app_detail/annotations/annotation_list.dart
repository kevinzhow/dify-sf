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
        SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: DifyTable(
            columns: [
              DifyTableColumn(
                width: _checkW,
                headerPadding: const EdgeInsets.symmetric(horizontal: 8),
                header: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DifyCheckbox(
                    checked: all,
                    indeterminate: selected > 0 && !all,
                    label: _t('common', 'operation.selectAll'),
                    onChanged: (_) => widget.onSelectedIdsChange(all ? const [] : ids),
                  ),
                ),
              ),
              DifyTableColumn(
                width: 20,
                headerPadding: const EdgeInsets.only(left: 8, right: 4),
                header: _headerText('table.header.question'),
              ),
              DifyTableColumn(headerPadding: _headPadding, header: _headerText('table.header.answer')),
              DifyTableColumn(headerPadding: _headPadding, header: _headerText('table.header.createdAt')),
              DifyTableColumn(headerPadding: _headPadding, header: _headerText('table.header.hits')),
              DifyTableColumn(
                width: _actionsW,
                headerPadding: _headPadding,
                header: _headerText('table.header.actions'),
              ),
            ],
            rows: [
              for (final (i, item) in widget.list.indexed)
                _row(
                  item,
                  createdAt: created[i],
                  onRemove: () => setState(() {
                    _currId = item.id;
                    _showConfirmDelete = true;
                  }),
                ),
            ],
          ),
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

/// The header cells' `pl-3` (the row is `h-7`: [DifyTable.headerHeight]).
const _headPadding = EdgeInsets.only(left: 12);

/// A header cell's text (`whitespace-nowrap`).
Widget _headerText(String key) => DifyTextLine(
  difyTransform(DifyType.systemXsMediumUppercase, _t('appAnnotation', key)),
  maxLines: 1,
  softWrap: false,
  overflow: TextOverflow.clip,
  style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
);

/// AnnotationTableRow: `cursor-pointer border-b border-divider-subtle hover:bg-background-default-hover`, a click
/// opens the annotation; the checkbox (`w-12 px-2`) and the actions (`w-24 p-3 pr-2`: edit, remove) stop it. The
/// question and answer cells are `max-w-62.5 truncate p-3 pr-2` (the full text as their `title`), the others
/// `p-3 pr-2`; no cell wraps.
extension on _AnnotationListState {
  DifyTableRow _row(Annotation item, {required String createdAt, required VoidCallback onRemove}) {
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary);
    Widget text(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 250),
        child: DifyTextLine(s, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style),
      ),
    );
    return DifyTableRow(
      key: ValueKey('annotation-row-${item.id}'),
      nowrap: true,
      onTap: () => widget.onView(item),
      cells: [
        // The checkbox cell stops the row's click.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: DifyCheckbox(
                checked: widget.selectedIds.contains(item.id),
                label: item.question,
                onChanged: (v) => _toggle(item.id, v),
              ),
            ),
          ),
        ),
        _CellTitle(message: item.question, child: text(item.question)),
        _CellTitle(message: item.answer, child: text(item.answer)),
        text(createdAt),
        text('${item.hitCount}'),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: Row(
              spacing: 4,
              children: [
                DifyIconButton(
                  label: _t('appDebug', 'feature.annotation.edit'),
                  icon: RemixIcon('edit-line', size: 16, color: DifyColors.textTertiary),
                  onPressed: () => widget.onView(item),
                ),
                DifyIconButton(
                  label: _t('appDebug', 'feature.annotation.remove'),
                  icon: RemixIcon('delete-bin-line', size: 16, color: DifyColors.textTertiary),
                  onPressed: onRemove,
                ),
              ],
            ),
          ),
        ),
      ],
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
                      child: DifyTextLine(
                        '${widget.selectedIds.length}',
                        style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimaryOnSurface),
                      ),
                    ),
                    DifyTextLine(
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
                child: DifyTextLine(_t('common', 'operation.delete')),
              ),
              divider(),
              DifyButton(
                variant: DifyButtonVariant.ghost,
                onPressed: () => widget.onSelectedIdsChange(const []),
                child: DifyTextLine(_t('common', 'operation.cancel')),
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
