/// web/app/components/app/annotation/batch-add-annotation-modal: the Bulk Import dialog (index.tsx) with the CSV
/// uploader (csv-uploader.tsx: browse, drag and drop, change, remove) and the template preview and download
/// (csv-downloader.tsx); Run Batch uploads the file and polls the job every 2.5 s until it completes or fails.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:collab_client/collab_client.dart' show AnnotationFiles, AnnotationJobStatus;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/app_locale.dart';
import '../../i18n/dify_i18n.dart';
import 'annotation_modals.dart' show AnnotationToast;
import 'annotation_overlays.dart';
import 'annotation_types.dart';
import 'header_opts.dart' show SaveAnnotationFile, saveAnnotationFile;

String _a(String key) => DifyI18n.tr('appAnnotation', key);
String _c(String key) => DifyI18n.tr('common', key);

/// A picked or dropped CSV file.
typedef AnnotationCsvFile = ({String name, Uint8List bytes});

/// The `.csv` file picker (the hidden `<input type="file" accept=".csv">`).
typedef PickAnnotationCsv = Future<AnnotationCsvFile?> Function();

Future<AnnotationCsvFile?> pickAnnotationCsv() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV', extensions: ['csv'], uniformTypeIdentifiers: ['public.comma-separated-values-text']),
    ],
  );
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

/// The uploader's drag state and drop handling (`dragenter` / `dragleave` / `drop`); the platform's drags
/// (desktop_drop) feed it, tests drive it directly.
class CsvDrop extends ChangeNotifier {
  bool _dragging = false;
  bool get dragging => _dragging;

  /// Set by the uploader: a file to take, and the error for more than one.
  void Function(AnnotationCsvFile file)? onFile;
  VoidCallback? onTooMany;

  void dragEnter() {
    if (_dragging) return;
    _dragging = true;
    notifyListeners();
  }

  void dragLeave() {
    if (!_dragging) return;
    _dragging = false;
    notifyListeners();
  }

  /// `drop`: no files (no `dataTransfer`) are ignored; more than one is refused.
  void drop(List<AnnotationCsvFile>? files) {
    dragLeave();
    if (files == null) return;
    if (files.length > 1) {
      onTooMany?.call();
      return;
    }
    if (files.isNotEmpty) onFile?.call(files.first);
  }
}

/// CSVUploader: the dashed drop zone ("Drag and drop your CSV file here, or browse"; the accent look while
/// dragging) or, with a [file], its name and `.csv` with Change and Delete on hover.
class AnnotationCsvUploader extends StatefulWidget {
  const AnnotationCsvUploader({
    super.key,
    required this.file,
    required this.updateFile,
    this.pickCsv = pickAnnotationCsv,
    this.drop,
    this.toast,
  });

  final AnnotationCsvFile? file;
  final ValueChanged<AnnotationCsvFile?> updateFile;
  final PickAnnotationCsv pickCsv;

  /// The drag state; the uploader makes its own by default.
  final CsvDrop? drop;
  final AnnotationToast? toast;

  @override
  State<AnnotationCsvUploader> createState() => _AnnotationCsvUploaderState();
}

class _AnnotationCsvUploaderState extends State<AnnotationCsvUploader> {
  CsvDrop? _own;
  CsvDrop get _drop => widget.drop ?? (_own ??= CsvDrop());
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _wire();
  }

  @override
  void didUpdateWidget(AnnotationCsvUploader old) {
    super.didUpdateWidget(old);
    _wire();
  }

  void _wire() {
    _drop
      ..onFile = widget.updateFile
      ..onTooMany = () => (widget.toast ?? difyToast)(
        DifyToastType.error,
        DifyI18n.tr('datasetCreation', 'stepOne.uploader.validation.count'),
      );
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  Future<void> _select() async {
    final file = await widget.pickCsv();
    if (file != null) widget.updateFile(file);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: DropTarget(
      onDragEntered: (_) => _drop.dragEnter(),
      onDragExited: (_) => _drop.dragLeave(),
      onDragDone: (details) async => _drop.drop([
        for (final f in details.files) (name: f.name, bytes: await f.readAsBytes()),
      ]),
      child: ListenableBuilder(
        listenable: _drop,
        builder: (context, _) => widget.file == null ? _zone() : _selected(widget.file!),
      ),
    ),
  );

  Widget _zone() {
    final dragging = _drop.dragging;
    return DashedBorderBox(
      key: const ValueKey('csv-drop-zone'),
      color: dragging ? DifyColors.componentsDropzoneBorderAccent : DifyColors.componentsDropzoneBorder,
      dashed: !dragging,
      fill: dragging ? DifyColors.componentsDropzoneBgAccent : DifyColors.componentsDropzoneBg,
      child: SizedBox(
        height: 80,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            const DifyIcon('public/files/csv', size: 32),
            Flexible(
              child: DifyTextLine.rich(
                TextSpan(
                  children: [
                    TextSpan(text: _a('batchModal.csvUploadTitle')),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: DifyPressable(
                        semanticLabel: _a('batchModal.browse'),
                        onPressed: () => unawaited(_select()),
                        builder: (context, _, _) => DifyTextLine(
                          _a('batchModal.browse'),
                          style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textAccent),
                        ),
                      ),
                    ),
                  ],
                ),
                style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selected(AnnotationCsvFile file) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: _hovered ? DifyColors.componentsPanelBgBlur : DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: _hovered ? DifyColors.componentsPanelBgBlur : DifyColors.componentsPanelBorder),
      ),
      child: Row(
        children: [
          const DifyIcon('public/files/csv', size: 32),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  Flexible(
                    child: DifyTextLine(
                      file.name.replaceFirst(RegExp(r'.csv$'), ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyTw.text14, DifyColors.textPrimary), // inherited 14 px
                    ),
                  ),
                  DifyTextLine('.csv', style: difyTextStyle(DifyTw.text14, DifyColors.textTertiary)),
                ],
              ),
            ),
          ),
          // Shown on hover (`hidden group-hover:flex`); kept in the tree, invisible, so keyboards and screen readers
          // reach them.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Opacity(
                opacity: _hovered ? 1 : 0,
                alwaysIncludeSemantics: true,
                child: Row(
                  children: [
                    DifyButton(
                      onPressed: () => unawaited(_select()),
                      child: DifyTextLine(DifyI18n.tr('datasetCreation', 'stepOne.uploader.change')),
                    ),
                    Container(
                      width: 1,
                      height: 16,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      color: DifyColors.dividerRegular,
                    ),
                    DifyIconButton(
                      label: _c('operation.delete'),
                      size: DifyIconButtonSize.lg,
                      icon: RemixIcon('delete-bin-line', size: 16, color: DifyColors.textTertiary),
                      onPressed: () => widget.updateFile(null),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// CSVDownload: "CSV structure" (`share` `generation.csvStructureTitle`), the two-column preview table and the
/// "Download the template here" link (the locale's template, `template-<locale>.csv`, with a BOM).
class AnnotationCsvDownloader extends StatelessWidget {
  const AnnotationCsvDownloader({super.key, required this.saveFile});

  final SaveAnnotationFile saveFile;

  @override
  Widget build(BuildContext context) {
    final locale = AppLocaleScope.of(context);
    final q = _a('batchModal.question'), a = _a('batchModal.answer');
    // `table text-xs`, `thead text-text-tertiary`, `td text-[13px]` (line height: the table's)
    final head = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary);
    final cell = difyTextStyle(DifyTw.text13Leading16, DifyColors.textSecondary);
    Widget row(List<String> texts, TextStyle style, {Color? border}) => Container(
      height: 36,
      decoration: BoxDecoration(
        border: border == null ? null : Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          for (final t in texts)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 8),
                child: DifyTextLine(t, style: style),
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DifyTextLine(
            DifyI18n.tr('share', 'generation.csvStructureTitle'),
            style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              border: Border.all(color: DifyColors.dividerRegular),
            ),
            child: Column(
              children: [
                row([q, a], head, border: DifyColors.dividerRegular),
                row(['$q 1', '$a 1'], cell, border: DifyColors.dividerSubtle),
                row(['$q 2', '$a 2'], cell),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DifyPressable(
              key: const ValueKey('csv-template-download'),
              semanticLabel: _a('batchModal.template'),
              onPressed: () => unawaited(
                saveFile(
                  AnnotationFiles.templateName(locale),
                  AnnotationFiles.templateCsv(locale: locale),
                  'text/csv;charset=utf-8;',
                ),
              ),
              builder: (context, _, _) => SizedBox(
                height: 18,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: DifyIcon('vender/solid/general/download-02', size: 12, color: DifyColors.textAccent),
                    ),
                    DifyTextLine(
                      _a('batchModal.template'),
                      style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// BatchModal: "Bulk Import" (`max-w-130 rounded-xl px-8 py-6`) with the close button, the uploader, the template
/// and Cancel / Run Batch (disabled without a file, loading while the job waits or runs). The file is forgotten when
/// the dialog hides. Dify's Cloud annotation quota has no counterpart in dify-sf.
class AnnotationBatchModal extends StatefulWidget {
  const AnnotationBatchModal({
    super.key,
    required this.isShow,
    required this.services,
    required this.onCancel,
    required this.onAdded,
    this.pickCsv = pickAnnotationCsv,
    this.saveFile = saveAnnotationFile,
    this.toast,
    this.pollInterval = const Duration(milliseconds: 2500),
    this.uploader,
  });

  final bool isShow;
  final AnnotationServices services;
  final VoidCallback onCancel, onAdded;
  final PickAnnotationCsv pickCsv;
  final SaveAnnotationFile saveFile;
  final AnnotationToast? toast;
  final Duration pollInterval;

  /// Replaces the uploader (Dify's tests mock it): built with the current file and its setter.
  final Widget Function(AnnotationCsvFile? file, ValueChanged<AnnotationCsvFile?> updateFile)? uploader;

  @override
  State<AnnotationBatchModal> createState() => _AnnotationBatchModalState();
}

class _AnnotationBatchModalState extends State<AnnotationBatchModal> {
  AnnotationCsvFile? _currentCsv;
  String? _importStatus;
  Timer? _poll;

  @override
  void didUpdateWidget(AnnotationBatchModal old) {
    super.didUpdateWidget(old);
    if (!widget.isShow && old.isShow) _currentCsv = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  AnnotationToast get _toast => widget.toast ?? difyToast;

  String _runError(Object e) {
    final m = errorMessageOf(e);
    return '${_a('batchModal.runError')}${m.isEmpty ? '' : ': $m'}';
  }

  Future<void> _checkProcess(String jobId) async {
    try {
      final res = await widget.services.batchImportStatus(jobId);
      if (!mounted) return;
      setState(() => _importStatus = res.jobStatus);
      if (res.jobStatus == AnnotationJobStatus.waiting || res.jobStatus == AnnotationJobStatus.processing) {
        _poll = Timer(widget.pollInterval, () => unawaited(_checkProcess(res.jobId ?? jobId)));
      }
      if (res.jobStatus == AnnotationJobStatus.error) _toast(DifyToastType.error, _a('batchModal.runError'));
      if (res.jobStatus == AnnotationJobStatus.completed) {
        _toast(DifyToastType.success, _a('batchModal.completed'));
        widget.onAdded();
        widget.onCancel();
      }
    } on Object catch (e) {
      _toast(DifyToastType.error, _runError(e));
    }
  }

  Future<void> _runBatch(AnnotationCsvFile csv) async {
    try {
      final res = await widget.services.batchImport(csv.bytes, csv.name);
      if (!mounted) return;
      setState(() => _importStatus = res.jobStatus);
      unawaited(_checkProcess(res.jobId ?? ''));
    } on Object catch (e) {
      _toast(DifyToastType.error, _runError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _importStatus == AnnotationJobStatus.processing || _importStatus == AnnotationJobStatus.waiting;
    void update(AnnotationCsvFile? f) => setState(() => _currentCsv = f);
    return AnnotationDialog(
      open: widget.isShow,
      width: 520,
      radius: DifyRadius.xl,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      label: _a('batchModal.title'),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: DifyTextLine(
                  _a('batchModal.title'),
                  style: difyTextStyle(DifyType.systemXlMedium, DifyColors.textPrimary),
                ),
              ),
              widget.uploader?.call(_currentCsv, update) ??
                  AnnotationCsvUploader(
                    file: _currentCsv,
                    updateFile: update,
                    pickCsv: widget.pickCsv,
                    toast: widget.toast,
                  ),
              AnnotationCsvDownloader(saveFile: widget.saveFile),
              Padding(
                padding: const EdgeInsets.only(top: 28 + 24),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  runSpacing: 8,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: DifyButton(onPressed: widget.onCancel, child: DifyTextLine(_a('batchModal.cancel'))),
                    ),
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      disabled: _currentCsv == null,
                      loading: running,
                      onPressed: () {
                        final csv = _currentCsv;
                        if (csv != null) unawaited(_runBatch(csv));
                      },
                      child: DifyTextLine(_a('batchModal.run')),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            top: -16,
            right: -24,
            child: DifyIconButton(
              label: _c('operation.close'),
              size: DifyIconButtonSize.lg,
              icon: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
              onPressed: widget.onCancel,
            ),
          ),
        ],
      ),
    );
  }
}
