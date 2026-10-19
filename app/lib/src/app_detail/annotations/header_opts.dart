/// web/app/components/app/annotation/header-opts/index.tsx and filter.tsx: "Add Annotation" and the More menu (Bulk
/// Import, Bulk Export as CSV / JSONL, Delete All), and the search row above the table.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collab_client/collab_client.dart' show Annotation, AnnotationFiles;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/app_locale.dart';
import '../../i18n/dify_i18n.dart';
import 'annotation_modals.dart';
import 'annotation_types.dart';
import 'batch_add_modal.dart';
import 'confirm_modals.dart';

String _a(String key) => DifyI18n.tr('appAnnotation', key);
String _c(String key) => DifyI18n.tr('common', key);

/// Saves a downloaded file (Dify's `downloadBlob`): its name, its text and its MIME type.
typedef SaveAnnotationFile = Future<void> Function(String fileName, String content, String mimeType);

Future<void> saveAnnotationFile(String fileName, String content, String mimeType) async {
  final file = XFile.fromData(utf8.encode(content), name: fileName, mimeType: mimeType);
  if (kIsWeb) return file.saveTo(fileName);
  final location = await getSaveLocation(suggestedName: fileName);
  if (location != null) await file.saveTo(location.path);
}

/// Filter: nothing until the annotation count has loaded (`useAnnotationsCount`, from [services]; a failed count
/// keeps it hidden), then the `w-50` search box (its edits go to [onKeywordChange]) and [child] on the right.
class AnnotationFilter extends StatefulWidget {
  const AnnotationFilter({
    super.key,
    required this.services,
    required this.keyword,
    required this.onKeywordChange,
    required this.child,
  });

  final AnnotationServices services;
  final String keyword;
  final ValueChanged<String> onKeywordChange;
  final Widget child;

  @override
  State<AnnotationFilter> createState() => _AnnotationFilterState();
}

class _AnnotationFilterState extends State<AnnotationFilter> {
  int? _count;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final c = await widget.services.count();
      if (mounted) setState(() => _count = c);
    } on Object {
      // No data: nothing is shown.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_count == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          DifySearchInput(
            width: 200,
            value: widget.keyword,
            placeholder: _c('operation.search'),
            onValueChange: widget.onKeywordChange,
          ),
          widget.child,
        ],
      ),
    );
  }
}

/// HeaderOptions: loads the export list (again whenever [controlUpdateList] changes) for the export items, which are
/// disabled while it is empty. Add opens [AddAnnotationModal]; Bulk Import the batch modal; Delete All asks first,
/// then clears and calls [onAdded] (a failure is only logged, as Dify does).
class AnnotationHeaderOptions extends StatefulWidget {
  const AnnotationHeaderOptions({
    super.key,
    required this.services,
    required this.onAdd,
    required this.onAdded,
    this.controlUpdateList = 0,
    this.saveFile = saveAnnotationFile,
    this.pickCsv = pickAnnotationCsv,
    this.toast,
  });

  final AnnotationServices services;
  final Future<void> Function(AnnotationItemBasic payload) onAdd;
  final VoidCallback onAdded;
  final int controlUpdateList;
  final SaveAnnotationFile saveFile;
  final PickAnnotationCsv pickCsv;
  final AnnotationToast? toast;

  @override
  State<AnnotationHeaderOptions> createState() => _AnnotationHeaderOptionsState();
}

class _AnnotationHeaderOptionsState extends State<AnnotationHeaderOptions> {
  List<Annotation> _list = const [];
  bool _showBulkImport = false, _showClearConfirm = false, _showAdd = false, _menuOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_fetchList());
  }

  @override
  void didUpdateWidget(AnnotationHeaderOptions old) {
    super.didUpdateWidget(old);
    if (widget.controlUpdateList != old.controlUpdateList && widget.controlUpdateList != 0) unawaited(_fetchList());
  }

  Future<void> _fetchList() async {
    try {
      final list = await widget.services.exportList();
      if (mounted) setState(() => _list = list);
    } on Object {
      // The export items stay as they were.
    }
  }

  Future<void> _clearAll() async {
    try {
      await widget.services.clearAll();
      widget.onAdded();
    } on Object catch (e) {
      debugPrint('failed to clear all annotations, $e');
    } finally {
      if (mounted) setState(() => _showClearConfirm = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = AppLocaleScope.of(context);
    final unavailable = _list.isEmpty;
    // `flex space-x-2` between Add and More; the dialogs below take no room.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DifyButton(
          variant: DifyButtonVariant.primary,
          leading: RemixIcon('add-line', size: 16, color: DifyColors.componentsButtonPrimaryText),
          onPressed: () => setState(() => _showAdd = true),
          child: Text(_a('table.header.addAnnotation')),
        ),
        const SizedBox(width: 8),
        DifyDropdownMenu(
          open: _menuOpen,
          onOpenChange: (v) => setState(() => _menuOpen = v),
          width: 155,
          builder: (context, controller) => DifyIconButton(
            key: const ValueKey('annotation-more'),
            label: _c('operation.more'),
            variant: DifyButtonVariant.secondary,
            size: DifyIconButtonSize.lg,
            icon: const RemixIcon('more-fill', size: 16),
            onPressed: controller.toggle,
          ),
          children: [
            DifyMenuItem(
              leading: DifyIcon('vender/line/files/file-plus-02', size: 16, color: DifyColors.textTertiary),
              onSelect: () => setState(() => _showBulkImport = true),
              child: Text(_a('table.header.bulkImport')),
            ),
            DifyMenuSubmenu(
              leading: DifyIcon('vender/line/files/file-download-02', size: 16, color: DifyColors.textTertiary),
              label: Text(_a('table.header.bulkExport')),
              width: 100,
              children: [
                DifyMenuItem(
                  disabled: unavailable,
                  onSelect: () => unawaited(
                    widget.saveFile(
                      AnnotationFiles.csvName(locale),
                      AnnotationFiles.csv(_list, locale: locale),
                      'text/csv;charset=utf-8;',
                    ),
                  ),
                  child: const Text('CSV'),
                ),
                DifyMenuItem(
                  disabled: unavailable,
                  onSelect: () => unawaited(
                    widget.saveFile(
                      AnnotationFiles.jsonlName(locale),
                      AnnotationFiles.jsonl(_list),
                      'application/jsonl',
                    ),
                  ),
                  child: const Text('JSONL'),
                ),
              ],
            ),
            DifyMenuItem(
              variant: DifyMenuItemVariant.destructive,
              leading: RemixIcon('delete-bin-line', size: 16, color: DifyColors.textDestructive),
              onSelect: () => setState(() => _showClearConfirm = true),
              child: Text(_a('table.header.clearAll')),
            ),
          ],
        ),
        AddAnnotationModal(
          isShow: _showAdd,
          onHide: () => setState(() => _showAdd = false),
          onAdd: widget.onAdd,
          toast: widget.toast,
        ),
        if (_showBulkImport)
          AnnotationBatchModal(
            isShow: _showBulkImport,
            services: widget.services,
            onCancel: () => setState(() => _showBulkImport = false),
            onAdded: widget.onAdded,
            pickCsv: widget.pickCsv,
            saveFile: widget.saveFile,
            toast: widget.toast,
          ),
        ClearAllAnnotationsConfirmModal(
          isShow: _showClearConfirm,
          onHide: () => setState(() => _showClearConfirm = false),
          onConfirm: () => unawaited(_clearAll()),
        ),
      ],
    );
  }
}
