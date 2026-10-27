/// The annotation drawers: add-annotation-modal (with its edit-item), edit-annotation-modal (with its edit-item and
/// EditTitle) and view-annotation-modal (the annotation tab, the hit history tab with hit-history-no-data, the remove
/// confirmation).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show Annotation, AnnotationHitHistory;
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../auth/account_time.dart';
import 'annotation_list.dart' show AnnotationTimeFormatter;
import 'annotation_overlays.dart';
import 'annotation_types.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);
String _a(String key) => _t('appAnnotation', key);
String _c(String key) => _t('common', key);

/// Shows a toast (dify-ui's `toast.success` / `toast.error`); the app's toast host by default.
typedef AnnotationToast = void Function(DifyToastType type, String message);

/// `EditItemType`.
enum EditItemType { query, answer }

Widget _avatar(EditItemType type) =>
    DifyIcon(type == EditItemType.query ? 'public/avatar/user' : 'public/avatar/robot', size: 24);

/// add-annotation-modal/edit-item: the avatar, the name (`system-xs-semibold`) and a Textarea with the placeholder.
class AddAnnotationEditItem extends StatelessWidget {
  const AddAnnotationEditItem({super.key, required this.type, required this.content, required this.onChange});

  final EditItemType type;
  final String content;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    final query = type == EditItemType.query;
    final name = _a(query ? 'addModal.queryName' : 'addModal.answerName');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(right: 12), child: _avatar(type)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: DifyTextLine(name, style: difyTextStyle(DifyType.systemXsSemibold, DifyColors.textPrimary)),
              ),
              DifyTextarea(
                key: ValueKey('add-annotation-${type.name}'),
                // React mounts two autoFocus fields; the final Answer wins.
                // Flutter chooses the first request, so select that same field once.
                autofocus: !query,
                value: content,
                semanticLabel: name,
                placeholder: _a(query ? 'addModal.queryPlaceholder' : 'addModal.answerPlaceholder'),
                onChanged: onChange,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// AddAnnotationModal: "Add Annotation Reply" with the question and the answer; the footer's "Add another annotated
/// response" keeps the drawer open (and empties it) after adding. Add refuses an empty question, then an empty
/// answer, with an error toast. Dify's Cloud annotation quota ([AnnotationFull]) has no counterpart in dify-sf.
class AddAnnotationModal extends StatefulWidget {
  const AddAnnotationModal({super.key, required this.isShow, required this.onHide, required this.onAdd, this.toast});

  final bool isShow;
  final VoidCallback onHide;
  final Future<void> Function(AnnotationItemBasic payload) onAdd;
  final AnnotationToast? toast;

  @override
  State<AddAnnotationModal> createState() => _AddAnnotationModalState();
}

class _AddAnnotationModalState extends State<AddAnnotationModal> {
  String _question = '', _answer = '';
  bool _isCreateNext = false, _isSaving = false;

  String? _invalid() {
    if (_question.isEmpty) return _a('errorMessage.queryRequired');
    if (_answer.isEmpty) return _a('errorMessage.answerRequired');
    return null;
  }

  Future<void> _save() async {
    final error = _invalid();
    if (error != null) {
      (widget.toast ?? difyToast)(DifyToastType.error, error);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await widget.onAdd((question: _question, answer: _answer));
    } on Object {
      // Dify swallows the error here (the request layer toasted it).
    }
    if (!mounted) return;
    setState(() => _isSaving = false);
    if (_isCreateNext) {
      setState(() {
        _question = '';
        _answer = '';
      });
    } else {
      widget.onHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isShow) return const SizedBox.shrink();
    final title = _a('addModal.title');
    return AnnotationDrawer(
      label: title,
      onClose: widget.onHide,
      title: DifyTextLine(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          spacing: 24,
          children: [
            AddAnnotationEditItem(
              type: EditItemType.query,
              content: _question,
              onChange: (v) => setState(() => _question = v),
            ),
            AddAnnotationEditItem(
              type: EditItemType.answer,
              content: _answer,
              onChange: (v) => setState(() => _answer = v),
            ),
          ],
        ),
      ),
      footer: AnnotationDrawerFooter(
        leading: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _isCreateNext = !_isCreateNext),
          child: Row(
            spacing: 8,
            children: [
              DifyCheckbox(
                checked: _isCreateNext,
                label: _a('addModal.createNext'),
                onChanged: (v) => setState(() => _isCreateNext = v),
              ),
              DifyTextLine(_a('addModal.createNext')),
            ],
          ),
        ),
        trailing: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            spacing: 8,
            children: [
              DifyButton(
                size: DifyButtonSize.small,
                onPressed: widget.onHide,
                child: DifyTextLine(_c('operation.cancel')),
              ),
              DifyButton(
                size: DifyButtonSize.small,
                variant: DifyButtonVariant.primary,
                loading: _isSaving,
                onPressed: () => unawaited(_save()),
                child: DifyTextLine(_c('operation.add')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// EditTitle: `h-4.5 system-xs-medium text-text-tertiary` with `edit-fill` (14 px) and a fading line.
class AnnotationEditTitle extends StatelessWidget {
  const AnnotationEditTitle({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 18,
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: RemixIcon('edit-fill', size: 14, color: DifyColors.textTertiary),
        ),
        Flexible(
          child: DifyTextLine(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            margin: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [DifyColors.dividerRegular, DifyColors.backgroundGradientMaskTransparent],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// edit-annotation-modal/edit-item: the avatar, the name and the content; "Edit" opens a Textarea under "Your Query" /
/// "Your Answer" with Save and Cancel. A saved change shows under the content with Delete (saves the original back).
/// A failed save keeps the editor open.
class AnnotationEditItem extends StatefulWidget {
  const AnnotationEditItem({
    super.key,
    required this.type,
    required this.content,
    required this.onSave,
    this.readonly = false,
  });

  final EditItemType type;
  final String content;
  final bool readonly;
  final Future<void> Function(String content) onSave;

  @override
  State<AnnotationEditItem> createState() => _AnnotationEditItemState();
}

class _AnnotationEditItemState extends State<AnnotationEditItem> {
  String _newContent = '';
  bool _isEdit = false;

  bool get _showNewContent => _newContent.isNotEmpty && _newContent != widget.content;

  @override
  void didUpdateWidget(AnnotationEditItem old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content) _newContent = '';
  }

  Future<void> _save() async {
    try {
      await widget.onSave(_newContent);
      if (mounted) setState(() => _isEdit = false);
    } on Object {
      // Keep editing; the parent reported the failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.type == EditItemType.query;
    final name = _a(query ? 'editModal.queryName' : 'editModal.answerName');
    final editTitle = _a(query ? 'editModal.yourQuery' : 'editModal.yourAnswer');
    final body = difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary);
    Widget link(String label, String icon, Color color, VoidCallback onTap) => DifyPressable(
      onPressed: onTap,
      semanticLabel: label,
      builder: (context, _, _) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          RemixIcon(icon, size: 14, color: color),
          DifyTextLine(label, style: difyTextStyle(DifyType.systemXsMedium, color)),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(right: 12), child: _avatar(widget.type)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: DifyTextLine(name, style: difyTextStyle(DifyType.systemXsSemibold, DifyColors.textPrimary)),
              ),
              DifyTextLine(widget.content, style: body),
              if (!_isEdit) ...[
                if (_showNewContent)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnnotationEditTitle(title: editTitle),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: DifyTextLine(_newContent, style: body),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (!widget.readonly)
                        link(_c('operation.edit'), 'edit-line', DifyColors.textAccent, () {
                          setState(() => _isEdit = true);
                        }),
                      if (_showNewContent)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Row(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: DifyTextLine(
                                  '·',
                                  style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                                ),
                              ),
                              link(_c('operation.delete'), 'delete-bin-line', DifyColors.textTertiary, () async {
                                try {
                                  await widget.onSave(widget.content);
                                  if (mounted) setState(() => _newContent = widget.content);
                                } on Object {
                                  // The parent reported it; nothing changes.
                                }
                              }),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AnnotationEditTitle(title: editTitle),
                      DifyTextarea(
                        key: ValueKey('edit-annotation-${widget.type.name}'),
                        autofocus: true,
                        value: _newContent,
                        semanticLabel: editTitle,
                        placeholder: _a(query ? 'editModal.queryPlaceholder' : 'editModal.answerPlaceholder'),
                        onChanged: (v) => setState(() => _newContent = v),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            DifyButton(
                              size: DifyButtonSize.small,
                              variant: DifyButtonVariant.primary,
                              onPressed: () => unawaited(_save()),
                              child: DifyTextLine(_c('operation.save')),
                            ),
                            DifyButton(
                              size: DifyButtonSize.small,
                              onPressed: () => setState(() {
                                _newContent = '';
                                _isEdit = false;
                              }),
                              child: DifyTextLine(_c('operation.cancel')),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The footer's "Remove this Annotation" (`message-check-remove` and the label, `pl-3`).
Widget _removeThisCache(VoidCallback onTap) => DifyPressable(
  onPressed: onTap,
  semanticLabel: _a('editModal.removeThisCache'),
  builder: (context, _, _) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        DifyIcon('vender/line/communication/message-check-remove', size: 16, color: DifyColors.textTertiary),
        DifyTextLine(_a('editModal.removeThisCache')),
      ],
    ),
  ),
);

/// "Created At <time>" in the footer.
Widget _createdAt(String time) => DifyTextLine('${_a('editModal.createdAt')} $time');

/// EditAnnotationModal (the logs' annotation editor): "Edit Annotation Reply" with the query (read-only with
/// [onlyEditResponse]) and the answer; each save sends both through [editAnnotation] (with [messageId]) and toasts
/// the result (the error's message, else "Action failed", keeping the editor open). The footer removes the
/// annotation after a confirmation and shows when it was created.
class EditAnnotationModal extends StatefulWidget {
  const EditAnnotationModal({
    super.key,
    required this.isShow,
    required this.onHide,
    required this.annotationId,
    required this.query,
    required this.answer,
    required this.onEdited,
    required this.onRemove,
    required this.editAnnotation,
    this.messageId,
    this.createdAt,
    this.onlyEditResponse = false,
    this.toast,
    this.formatTime,
  });

  final bool isShow;
  final VoidCallback onHide;
  final String annotationId, query, answer;
  final String? messageId;
  final int? createdAt;
  final void Function(String editedQuery, String editedAnswer) onEdited;
  final VoidCallback onRemove;
  final bool onlyEditResponse;

  /// `editAnnotation(appId, annotationId, {message_id, question, answer})`.
  final Future<void> Function(
    String annotationId, {
    required String question,
    required String answer,
    String? messageId,
  })
  editAnnotation;
  final AnnotationToast? toast;

  /// Null: the account's time zone ([AccountTime.of], Dify's `useTimestamp`).
  final AnnotationTimeFormatter? formatTime;

  @override
  State<EditAnnotationModal> createState() => _EditAnnotationModalState();
}

class _EditAnnotationModalState extends State<EditAnnotationModal> {
  bool _showModal = false;

  Future<void> _save(EditItemType type, String edited) async {
    final w = widget;
    final q = type == EditItemType.query ? edited : w.query;
    final a = type == EditItemType.answer ? edited : w.answer;
    final toast = w.toast ?? difyToast;
    try {
      await w.editAnnotation(w.annotationId, question: q, answer: a, messageId: w.messageId);
      w.onEdited(q, a);
      toast(DifyToastType.success, _c('api.actionSuccess'));
    } catch (e) {
      final message = errorMessageOf(e);
      toast(DifyToastType.error, message.isNotEmpty ? message : _c('api.actionFailed'));
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (!w.isShow) return const SizedBox.shrink();
    final title = _a('editModal.title');
    final createdAt = w.createdAt;
    return AnnotationDrawer(
      label: title,
      onClose: w.onHide,
      title: DifyTextLine(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          spacing: 24,
          children: [
            AnnotationEditItem(
              type: EditItemType.query,
              content: w.query,
              readonly: w.onlyEditResponse,
              onSave: (c) => _save(EditItemType.query, c),
            ),
            AnnotationEditItem(
              type: EditItemType.answer,
              content: w.answer,
              onSave: (c) => _save(EditItemType.answer, c),
            ),
            AnnotationAlertDialog(
              open: _showModal,
              title: _t('appDebug', 'feature.annotation.removeConfirm'),
              onCancel: () => setState(() => _showModal = false),
              onConfirm: () {
                w.onRemove();
                setState(() => _showModal = false);
                w.onHide();
              },
            ),
          ],
        ),
      ),
      footer: AnnotationDrawerFooter(
        leading: _removeThisCache(() => setState(() => _showModal = true)),
        trailing: createdAt != null && createdAt != 0
            ? _createdAt(
                (w.formatTime ?? AccountTime.of(context).formatTime)(createdAt, _t('appLog', 'dateTimeFormat')),
              )
            : null,
      ),
    );
  }
}

/// hit-history-no-data: `mx-auto mt-20 w-120 rounded-2xl bg-background-section-burn p-5` with the
/// `clock-fast-forward` box and "No hit history".
class HitHistoryNoData extends StatelessWidget {
  const HitHistoryNoData({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 480,
      margin: const EdgeInsets.only(top: 80),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: DifyColors.backgroundSectionBurn,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: DifyColors.dividerSubtle),
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: DifyIcon('vender/line/time/clock-fast-forward', size: 20, color: DifyColors.textTertiary),
          ),
          DifyTextLine(
            _a('viewModal.noHitHistory'),
            style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
          ),
        ],
      ),
    ),
  );
}

/// ViewAnnotationModal: the `w-200` drawer with the "Annotation Reply" / "Hit History" tabs (the hit count badge once
/// there are hits); the annotation tab edits the question and the answer through [onSave]; the hit history tab pages
/// through [fetchHitHistory] (ten per page). The footer removes the annotation after a confirmation and shows when
/// it was created.
class ViewAnnotationModal extends StatefulWidget {
  const ViewAnnotationModal({
    super.key,
    required this.isShow,
    required this.onHide,
    required this.item,
    required this.onSave,
    required this.onRemove,
    required this.fetchHitHistory,
    this.formatTime,
  });

  final bool isShow;
  final VoidCallback onHide;
  final Annotation item;
  final Future<void> Function(String editedQuestion, String editedAnswer) onSave;
  final Future<void> Function() onRemove;

  /// `fetchHitHistoryList(appId, id, {page, limit: 10})`.
  final Future<AnnotationListPage<AnnotationHitHistory>> Function(String annotationId, int page) fetchHitHistory;

  /// Null: the account's time zone ([AccountTime.of], Dify's `useTimestamp`).
  final AnnotationTimeFormatter? formatTime;

  @override
  State<ViewAnnotationModal> createState() => _ViewAnnotationModalState();
}

enum _Tab { annotation, hitHistory }

class _ViewAnnotationModalState extends State<ViewAnnotationModal> {
  late String _newQuestion = widget.item.question, _newAnswer = widget.item.answer;
  int _currPage = 0, _total = 0;
  List<AnnotationHitHistory> _hits = const [];
  _Tab _activeTab = _Tab.annotation;
  bool _showModal = false;

  @override
  void initState() {
    super.initState();
    if (widget.isShow && widget.item.id.isNotEmpty) unawaited(_fetchHitHistory(1));
  }

  @override
  void didUpdateWidget(ViewAnnotationModal old) {
    super.didUpdateWidget(old);
    final i = widget.item, o = old.item;
    if (i.question != o.question || i.answer != o.answer || i.id != o.id) {
      _newQuestion = i.question;
      _newAnswer = i.answer;
      _currPage = 0;
      _total = 0;
      _hits = const [];
    }
    if (widget.isShow && i.id.isNotEmpty && (i.id != o.id || !old.isShow)) unawaited(_fetchHitHistory(1));
  }

  Future<void> _fetchHitHistory(int page) async {
    try {
      final res = await widget.fetchHitHistory(widget.item.id, page);
      if (!mounted) return;
      setState(() {
        _hits = res.data;
        _total = res.total;
      });
    } on Object {
      // Dify ignores a failed fetch.
    }
  }

  Future<void> _save(EditItemType type, String edited) async {
    try {
      if (type == EditItemType.query) {
        await widget.onSave(edited, _newAnswer);
        if (mounted) setState(() => _newQuestion = edited);
      } else {
        await widget.onSave(_newQuestion, edited);
        if (mounted) setState(() => _newAnswer = edited);
      }
    } on Object {
      // A failed save leaves the local state as it was.
    }
  }

  Widget _hitTable() {
    final dateFormat = _t('appLog', 'dateTimeFormat');
    final head = difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary);
    Widget h(String key) => DifyTextLine(
      difyTransform(DifyType.systemXsMediumUppercase, _a(key)),
      maxLines: 1,
      softWrap: false,
      style: head,
    );
    // `max-w-62.5 truncate p-3 pr-2` (query, match, response), `p-3 pr-2` (the rest); no cell wraps.
    Widget c(String text, {bool truncate = false}) {
      final t = DifyTextLine(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: truncate ? ConstrainedBox(constraints: const BoxConstraints(maxWidth: 250), child: t) : t,
      );
    }

    const pl3 = EdgeInsets.fromLTRB(12, 6, 0, 6);
    final totalPages = _total == 0 ? 1 : (_total / appPageLimit).ceil().clamp(1, 1 << 30);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifyTable(
          columns: [
            DifyTableColumn(
              width: 20,
              headerPadding: const EdgeInsets.only(left: 8, right: 4),
              header: h('hitHistoryTable.query'),
            ),
            DifyTableColumn(headerPadding: pl3, header: h('hitHistoryTable.match')),
            DifyTableColumn(headerPadding: pl3, header: h('hitHistoryTable.response')),
            DifyTableColumn(headerPadding: pl3, header: h('hitHistoryTable.source')),
            DifyTableColumn(headerPadding: pl3, header: h('hitHistoryTable.score')),
            DifyTableColumn(width: 160, headerPadding: pl3, header: h('hitHistoryTable.time')),
          ],
          rows: [
            for (final hit in _hits)
              DifyTableRow(
                cellPadding: EdgeInsets.zero,
                nowrap: true,
                cells: [
                  c(hit.question ?? '', truncate: true),
                  c(hit.match ?? '', truncate: true),
                  c(hit.response ?? '', truncate: true),
                  c(hit.source ?? ''),
                  c((hit.score ?? 0) != 0 ? hit.score!.toStringAsFixed(2) : '-'),
                  c((widget.formatTime ?? AccountTime.of(context).formatTime)(hit.createdAt ?? 0, dateFormat)),
                ],
              ),
          ],
        ),
        if (_total > appPageLimit)
          DifyPagination(
            page: _currPage + 1,
            totalPages: totalPages,
            onPageChange: (page) {
              setState(() => _currPage = page - 1);
              unawaited(_fetchHitHistory(page));
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (!w.isShow) return const SizedBox.shrink();
    final hitLabel = _a('viewModal.hitHistory');
    return AnnotationDrawer(
      width: 800,
      label: _a('viewModal.annotatedResponse'),
      onClose: w.onHide,
      title: Transform.translate(
        offset: const Offset(0, 9),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: DifyTabSliderPlain(
            value: _activeTab.name,
            itemPaddingBottom: 14,
            onChange: (v) => setState(() => _activeTab = _Tab.values.byName(v)),
            options: [
              (value: _Tab.annotation.name, text: DifyTextLine(_a('viewModal.annotatedResponse'))),
              (
                value: _Tab.hitHistory.name,
                text: _hits.isNotEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: [
                          Flexible(child: DifyTextLine(hitLabel)),
                          DifyBadge('$_total ${_a(_hits.length > 1 ? 'viewModal.hits' : 'viewModal.hit')}'),
                        ],
                      )
                    : DifyTextLine(hitLabel),
              ),
            ],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 24,
          children: [
            if (_activeTab == _Tab.annotation) ...[
              AnnotationEditItem(
                type: EditItemType.query,
                content: w.item.question,
                onSave: (c) => _save(EditItemType.query, c),
              ),
              AnnotationEditItem(
                type: EditItemType.answer,
                content: w.item.answer,
                onSave: (c) => _save(EditItemType.answer, c),
              ),
            ] else if (_total == 0)
              const HitHistoryNoData()
            else
              _hitTable(),
            AnnotationAlertDialog(
              open: _showModal,
              title: _t('appDebug', 'feature.annotation.removeConfirm'),
              onCancel: () => setState(() => _showModal = false),
              onConfirm: () async {
                await w.onRemove();
                if (mounted) setState(() => _showModal = false);
                w.onHide();
              },
            ),
          ],
        ),
      ),
      footer: w.item.id.isEmpty
          ? null
          : AnnotationDrawerFooter(
              leading: _removeThisCache(() => setState(() => _showModal = true)),
              trailing: _createdAt(
                (w.formatTime ?? AccountTime.of(context).formatTime)(w.item.createdAt, _t('appLog', 'dateTimeFormat')),
              ),
            ),
    );
  }
}
