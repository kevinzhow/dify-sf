/// app/create-from-dsl-modal: Import DSL (from a file, or a URL), its uploader, the DSL version confirmation
/// (dsl-confirm-modal) and the warnings of a completed-with-warnings import (dsl-import-warning-description).
library;

import 'dart:async';
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/panel_fields/file_upload_setting.dart' show formatFileSize;
import 'app_modals.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// A chosen DSL file: its name, size in bytes and a reader for its text (read when the import starts, as Dify's
/// `file.text()`).
typedef DslFileData = ({String name, int size, Future<String> Function() read});

/// A [DslFileData] whose text is already in memory.
DslFileData dslFileOf(String name, String content) =>
    (name: name, size: utf8.encode(content).length, read: () async => content);

/// types.ts `CreateFromDSLModalTab`.
abstract final class CreateFromDSLModalTab {
  static const fromFile = 'from-file';
  static const fromUrl = 'from-url';
}

/// The file picker for `.yaml,.yml` (the hidden `<input type="file">`).
Future<DslFileData?> pickDslFileData() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'YAML', extensions: ['yaml', 'yml'], uniformTypeIdentifiers: ['public.yaml', 'public.text']),
    ],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return (name: file.name, size: bytes.length, read: () async => utf8.decode(bytes, allowMalformed: true));
}

/// `yaml-url` imports: Dify's server fetches the URL; dify-sf's server takes file content only, so the client
/// fetches it (subject to the browser's CORS rules on the web).
Future<String> fetchDslUrl(String url) async {
  final res = await http.get(Uri.parse(url));
  if (res.statusCode >= 400) throw TransportException('HTTP ${res.statusCode}', statusCode: res.statusCode);
  return utf8.decode(res.bodyBytes, allowMalformed: true);
}

/// DSLImportWarningDescription: the distinct warning messages, one per row, at most three and then "…"; [fallback]
/// without any.
List<String> dslImportWarningLines(List<Map<String, Object?>> warnings) {
  final messages = <String>{
    for (final w in warnings)
      if ('${w['message'] ?? ''}'.trim() case final m when m.isNotEmpty) m,
  }.toList();
  return [...messages.take(3), if (messages.length > 3) '…'];
}

/// CreateFromDSLModal. [importDsl] / [confirmImport] are `POST /apps/imports` and its confirm; [onImported] opens
/// the new app (after [onSuccess] and [onClose], as Dify redirects after closing).
class CreateFromDSLModal extends StatefulWidget {
  const CreateFromDSLModal({
    super.key,
    required this.onClose,
    required this.importDsl,
    required this.confirmImport,
    this.onSuccess,
    this.onImported,
    this.activeTab = CreateFromDSLModalTab.fromFile,
    this.dslUrl = '',
    this.droppedFile,
    this.pickFile = pickDslFileData,
    this.fetchUrl = fetchDslUrl,
  });

  final VoidCallback onClose;
  final VoidCallback? onSuccess;
  final Future<AppImport> Function(String yaml) importDsl;
  final Future<AppImport> Function(String importId) confirmImport;
  final Future<void> Function(AppImport response)? onImported;
  final String activeTab;
  final String dslUrl;
  final DslFileData? droppedFile;
  final Future<DslFileData?> Function() pickFile;
  final Future<String> Function(String url) fetchUrl;

  @override
  State<CreateFromDSLModal> createState() => _CreateFromDSLModalState();
}

class _CreateFromDSLModalState extends State<CreateFromDSLModal> {
  late DslFileData? _file = widget.droppedFile;
  late String _tab = widget.activeTab;
  late String _url = widget.dslUrl;
  ({String id, String importedVersion, String systemVersion})? _pending;
  bool _importing = false, _confirming = false;
  final _browse = FocusNode(debugLabel: 'dsl browse');

  /// The version confirmation takes the focus while it is open (an AlertDialog's focus trap).
  final _confirmScope = FocusScopeNode(debugLabel: 'dsl confirm');

  /// Base UI's tabs: only the active tab is in the Tab order (roving tabindex).
  final _tabNodes = {
    CreateFromDSLModalTab.fromFile: FocusNode(debugLabel: 'dsl file tab'),
    CreateFromDSLModalTab.fromUrl: FocusNode(debugLabel: 'dsl url tab'),
  };

  @override
  void initState() {
    super.initState();
    // `initialFocus={browseButtonRef}`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _file == null && _tab == CreateFromDSLModalTab.fromFile) _browse.requestFocus();
    });
  }

  @override
  void dispose() {
    _browse.dispose();
    _confirmScope.dispose();
    for (final n in _tabNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  bool get _createDisabled => _tab == CreateFromDSLModalTab.fromFile && _file == null;

  /// Escape: closes the version confirmation first (unless it is confirming), else the dialog (unless importing).
  void _close() {
    if (_pending != null) {
      if (!_confirming) setState(() => _pending = null);
      return;
    }
    if (_importing) return;
    widget.onClose();
  }

  Future<void> _completed(AppImport response) async {
    widget.onSuccess?.call();
    widget.onClose();
    if (response.status == AppImportStatus.completed) {
      toast.success(_a('newApp.appCreated'));
    } else {
      final lines = dslImportWarningLines(response.warnings);
      toast.warning(
        _a('newApp.caution'),
        description: lines.isEmpty ? _a('newApp.appCreateDSLWarning') : lines.join('\n'),
      );
    }
    if (response.appId == null || response.appMode == null) return;
    await widget.onImported?.call(response);
  }

  Future<void> _handleResponse(AppImport response) async {
    if (response.completed) return _completed(response);
    if (response.pending) {
      setState(
        () => _pending = (
          id: response.id,
          importedVersion: response.importedDslVersion,
          systemVersion: response.currentDslVersion,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pending != null) _confirmScope.requestFocus();
      });
      return;
    }
    toast.error(response.error.isNotEmpty ? response.error : _a('newApp.appCreateFailed'));
  }

  Future<void> _submit() async {
    if (_importing) return;
    String? yaml;
    setState(() => _importing = true);
    try {
      if (_tab == CreateFromDSLModalTab.fromFile) {
        if (_file == null) return;
        yaml = await _file!.read();
        if (!mounted) return;
      } else {
        final url = _url.trim();
        if (url.isEmpty) return;
        yaml = await widget.fetchUrl(url);
      }
      final response = await widget.importDsl(yaml);
      if (!mounted) return;
      setState(() => _importing = false);
      await _handleResponse(response);
    } on Object {
      toast.error(_a('newApp.appCreateFailed'));
    } finally {
      if (mounted && _importing) setState(() => _importing = false);
    }
  }

  Future<void> _confirm() async {
    final pending = _pending;
    if (pending == null || _confirming) return;
    setState(() => _confirming = true);
    try {
      final response = await widget.confirmImport(pending.id);
      if (!mounted) return;
      setState(() => _confirming = false);
      if (response.completed) {
        setState(() => _pending = null);
        await _completed(response);
        return;
      }
      if (response.failed) toast.error(response.error.isNotEmpty ? response.error : _a('newApp.appCreateFailed'));
    } on Object {
      toast.error(_a('newApp.appCreateFailed'));
    } finally {
      if (mounted && _confirming) setState(() => _confirming = false);
    }
  }

  Widget _tabButton(String value, String label) {
    final active = _tab == value;
    final node = _tabNodes[value]!..skipTraversal = !active;
    return DifyTab(
      key: ValueKey('dsl-tab-$value'),
      label: label,
      active: active,
      focusNode: node,
      disabled: _importing,
      onPressed: () {
        setState(() => _tab = value);
        node.requestFocus();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_createDisabled && !_importing && _pending == null;
    final dialog = CallbackShortcuts(
      bindings: {
        ...modEnter(canSubmit ? () => unawaited(_submit()) : null),
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: DifyDialogSurface(
        label: _a('importApp'),
        bordered: true,
        scrollable: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _a('importApp'),
                      style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                    ),
                  ),
                  DifyIconButton(
                    key: const ValueKey('dsl-close'),
                    label: _c('operation.cancel'),
                    variant: DifyButtonVariant.ghost,
                    size: DifyIconButtonSize.lg,
                    disabled: _importing,
                    icon: RemixIcon('close-line', size: 20, color: DifyColors.textTertiary),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 24,
                children: [
                  Flexible(child: _tabButton(CreateFromDSLModalTab.fromFile, _a('importFromDSLFile'))),
                  Flexible(child: _tabButton(CreateFromDSLModalTab.fromUrl, _a('importFromDSLUrl'))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: _tab == CreateFromDSLModalTab.fromFile
                  ? DslUploader(
                      file: _file,
                      browseFocusNode: _browse,
                      disabled: _importing,
                      pickFile: widget.pickFile,
                      onChange: (f) => setState(() => _file = f),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 4,
                      children: [
                        Text(
                          _a('importFromDSLUrl'),
                          style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                        ),
                        DifyInput(
                          key: const ValueKey('dsl-url'),
                          value: _url,
                          disabled: _importing,
                          keyboardType: TextInputType.url,
                          placeholder: _a('importFromDSLUrlPlaceholder'),
                          semanticLabel: _a('importFromDSLUrl'),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => unawaited(_submit()),
                          onChanged: (v) => setState(() => _url = v),
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  DifyButton(
                    key: const ValueKey('dsl-cancel'),
                    disabled: _importing,
                    semanticLabel: _a('newApp.Cancel'),
                    onPressed: widget.onClose,
                    child: Text(_a('newApp.Cancel')),
                  ),
                  DifyButton(
                    key: const ValueKey('dsl-create'),
                    variant: DifyButtonVariant.primary,
                    disabled: _createDisabled,
                    loading: _importing,
                    semanticLabel: _a('newApp.Create'),
                    onPressed: () => unawaited(_submit()),
                    child: labelWithModEnter(_a('newApp.Create'), disabled: _createDisabled),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final pending = _pending;
    // A click outside (or the route's Escape) does not close the dialog while it imports or asks to confirm.
    if (pending == null) return PopScope(canPop: !_importing, child: dialog);
    return PopScope(
      canPop: false,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(child: dialog),
            ColoredBox(color: DifyColors.backgroundOverlay),
            FocusScope(
              node: _confirmScope,
              autofocus: true,
              child: DSLConfirmModal(
                importedVersion: pending.importedVersion,
                systemVersion: pending.systemVersion,
                confirmLoading: _confirming,
                onCancel: () {
                  if (!_confirming) setState(() => _pending = null);
                },
                onConfirm: () => unawaited(_confirm()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows [CreateFromDSLModal]: a click outside closes it unless an import is running or a version confirmation is
/// open (the modal ignores the close then).
Future<void> showCreateFromDSLModal(BuildContext context, CreateFromDSLModal Function(VoidCallback close) builder) {
  var closing = false;
  return showDifyDialog<void>(
    context,
    builder: (context) => builder(() {
      if (closing) return;
      closing = true;
      Navigator.pop(context);
    }),
  );
}

/// Uploader: the dashed drop area with "Drag and drop file here, or Browse", then the chosen file's row (YAML icon,
/// name, `YAML · <size>`, a delete button on hover). A drop of several files is refused.
class DslUploader extends StatefulWidget {
  const DslUploader({
    super.key,
    required this.file,
    required this.onChange,
    required this.pickFile,
    this.browseFocusNode,
    this.disabled = false,
    this.displayName = 'YAML',
  });

  final DslFileData? file;
  final ValueChanged<DslFileData?> onChange;
  final Future<DslFileData?> Function() pickFile;
  final FocusNode? browseFocusNode;
  final bool disabled;
  final String displayName;

  @override
  State<DslUploader> createState() => DslUploaderState();
}

class DslUploaderState extends State<DslUploader> {
  bool _dragging = false;
  bool _hovered = false;
  // `focus-visible`: a ring only once the keyboard has been used. The dialog focuses Browse when it opens
  // (`initialFocus`, with `focusVisible: false`), which a plain `hasFocus` check would draw a ring for.
  bool _keyboardFocus = false;
  final _row = FocusNode(debugLabel: 'dsl file row');
  FocusNode? _ownBrowse;
  FocusNode get _browse => widget.browseFocusNode ?? (_ownBrowse ??= FocusNode(debugLabel: 'dsl browse'));

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent event) {
    if (!_keyboardFocus) setState(() => _keyboardFocus = true);
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _row.dispose();
    _ownBrowse?.dispose();
    super.dispose();
  }

  Future<void> _select() async {
    if (widget.disabled) return;
    final original = widget.file;
    final picked = await widget.pickFile();
    if (!mounted) return;
    if (picked == null) {
      // The picker was cancelled: the previous file stays.
      widget.onChange(original);
      return;
    }
    widget.onChange(picked);
    // The chosen file's row takes the focus that Browse had (`pendingFocusRef`).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _row.requestFocus();
    });
  }

  void _remove() {
    if (widget.disabled) return;
    widget.onChange(null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _browse.requestFocus();
    });
  }

  /// `handleDragEnter` / `handleDragLeave` (the platform's drag over the uploader).
  void dragEnter() {
    if (widget.disabled || _dragging) return;
    setState(() => _dragging = true);
  }

  void dragExit() {
    if (_dragging) setState(() => _dragging = false);
  }

  /// `handleDrop`: one file only; null = a drop without `dataTransfer`. Focus stays where it is.
  Future<void> drop(List<({String name, Future<int> Function() length, Future<String> Function() read})>? files) async {
    setState(() => _dragging = false);
    if (widget.disabled || files == null) return;
    if (files.length > 1) {
      toast.error(DifyI18n.tr('dataset-creation', 'stepOne.uploader.validation.count'));
      return;
    }
    if (files.isEmpty) return;
    final f = files.first;
    widget.onChange((name: f.name, size: await f.length(), read: f.read));
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    Widget body;
    if (file == null) {
      // `flex h-12 items-center rounded-[10px] border border-dashed ...` with a centred `space-x-2` group and, inside
      // it, the label followed by the Browse button (`ml-1 h-6 px-1`). Both are intrinsic: wrapping them in Flexible
      // makes the button take the rest of the row, which moves the whole group left and draws a ring across it.
      body = SizedBox(
        height: 48,
        child: DashedBorderBox(
          key: const ValueKey('dsl-dropzone'),
          radius: 10,
          fill: _dragging ? DifyColors.componentsDropzoneBgAccent : DifyColors.componentsDropzoneBg,
          color: _dragging ? DifyColors.componentsDropzoneBorderAccent : DifyColors.componentsDropzoneBorder,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              RemixIcon('upload-cloud-2-line', size: 24, color: DifyColors.textTertiary),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _a('dslUploader.button'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary), // inherited 14/20
                      ),
                    ),
                    DifyPressable(
                      key: const ValueKey('dsl-browse'),
                      focusNode: _browse,
                      disabled: widget.disabled,
                      semanticLabel: _a('dslUploader.browse'),
                      onPressed: () => unawaited(_select()),
                      // `focus-visible:ring-2`: the dialog focuses Browse when it opens (`initialFocus`, with
                      // `focusVisible: false`), so the ring waits for the keyboard the way the browser does.
                      builder: (context, hovered, focused) => Container(
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: focused && _keyboardFocus
                            ? BoxDecoration(
                                borderRadius: BorderRadius.circular(DifyRadius.md),
                                border: Border.all(color: DifyColors.stateAccentSolid, width: 2),
                              )
                            : null,
                        child: Text(
                          _a('dslUploader.browse'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // `text-sm font-normal hover:underline`
                          style:
                              difyTextStyle(
                                DifyType.systemMdRegular,
                                widget.disabled ? DifyColors.textDisabled : DifyColors.textAccent,
                              ).copyWith(
                                decoration: hovered && !widget.disabled ? TextDecoration.underline : null,
                                decorationColor: DifyColors.textAccent,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      final showRemove = _hovered || _row.hasFocus;
      body = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Focus(
          key: const ValueKey('dsl-file'),
          focusNode: _row,
          onFocusChange: (_) => setState(() {}),
          child: Semantics(
            container: true,
            label: file.name,
            child: Container(
              decoration: BoxDecoration(
                color: _hovered
                    ? DifyColors.componentsPanelOnPanelItemBgHover
                    : DifyColors.componentsPanelOnPanelItemBg,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
                boxShadow: DifyShadows.xs,
              ),
              child: Row(
                children: [
                  const Padding(padding: EdgeInsets.all(12), child: DifyIcon('public/files/yaml', size: 24)),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 4, right: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // `text-[12px] leading-4 font-medium text-text-secondary`
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary),
                          ),
                          SizedBox(
                            height: 12,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: widget.displayName),
                                  TextSpan(
                                    text: ' · ',
                                    style: TextStyle(color: DifyColors.textQuaternary),
                                  ),
                                  TextSpan(text: formatFileSize(file.size).toUpperCase()),
                                ],
                              ),
                              // `text-2xs leading-3 font-medium text-text-tertiary uppercase`
                              style: difyTextStyle(DifyType.system2xsMedium, DifyColors.textTertiary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Opacity(
                      opacity: showRemove ? 1 : 0,
                      alwaysIncludeSemantics: true,
                      child: DifyIconButton(
                        key: const ValueKey('dsl-file-remove'),
                        label: _c('operation.delete'),
                        variant: DifyButtonVariant.ghost,
                        disabled: widget.disabled,
                        icon: RemixIcon('delete-bin-line', size: 16, color: DifyColors.textTertiary),
                        onPressed: _remove,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: DropTarget(
        enable: !widget.disabled,
        onDragEntered: (_) => dragEnter(),
        onDragExited: (_) => dragExit(),
        onDragDone: (d) => unawaited(
          drop([for (final f in d.files) (name: f.name, length: f.length, read: f.readAsString)]),
        ),
        child: Semantics(container: true, explicitChildNodes: true, role: SemanticsRole.none, child: body),
      ),
    );
  }
}
