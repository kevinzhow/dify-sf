import 'package:collab_client/collab_client.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../panel_fields/dialog.dart';
import '../operator/actions.dart' show OperatorReadOnly;
import '../store/store.dart';

String _w(String key) => DifyI18n.tr('workflow', key);
String _a(String key) => DifyI18n.tr('app', key);

typedef WorkflowImport = Future<ReplaceResult> Function(String yaml, {bool confirm});
typedef DslFile = ({String name, String content});
typedef PickDslFile = Future<DslFile?> Function();

Future<DslFile?> pickDslFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'YAML', extensions: ['yaml', 'yml'], uniformTypeIdentifiers: ['public.yaml', 'public.text']),
    ],
  );
  return file == null ? null : (name: file.name, content: await file.readAsString());
}

/// update-dsl-modal.helpers: the current app's mode decides which node types can be imported.
bool validateDslContent(String text, String mode) {
  try {
    final data = loadYaml(text);
    final nodes = data is Map && data['workflow'] is Map && data['workflow']['graph'] is Map
        ? data['workflow']['graph']['nodes']
        : null;
    final invalid = mode == 'advanced-chat'
        ? {'end', 'trigger-webhook', 'trigger-schedule', 'trigger-plugin'}
        : {'answer'};
    return nodes is! List || !nodes.any((n) => n is Map && n['data'] is Map && invalid.contains(n['data']['type']));
  } on Object {
    return false;
  }
}

/// Consumes the pane menu's store flag, preserving the editor's scope while the dialog is in the root navigator.
class ImportDslHost extends StatefulWidget {
  const ImportDslHost({super.key, required this.appMode, this.onImport, this.onBackup, this.pickFile});
  final String appMode;
  final WorkflowImport? onImport;
  final VoidCallback? onBackup;
  final PickDslFile? pickFile;
  @override
  State<ImportDslHost> createState() => _ImportDslHostState();
}

class _ImportDslHostState extends State<ImportDslHost> {
  WorkflowStore? _store;
  bool _opening = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = WorkflowStoreScope.of(context);
    if (store == _store) return;
    _store?.showImportDSLModal.removeListener(_requested);
    _store = store..showImportDSLModal.addListener(_requested);
    _requested();
  }

  void _requested() {
    if (_store!.showImportDSLModal.value && !_opening) {
      _opening = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final store = _store!;
        if (!store.nodesReadOnly) {
          await showDifyDialog<void>(
            context,
            builder: (context) => UpdateDslModal(
              appMode: widget.appMode,
              onImport: widget.onImport == null
                  ? null
                  : (yaml, {confirm = false}) async {
                      store.setIsRestoring(true);
                      try {
                        return await widget.onImport!(yaml, confirm: confirm);
                      } finally {
                        if (mounted) store.setIsRestoring(false);
                      }
                    },
              onBackup: widget.onBackup,
              pickFile: widget.pickFile ?? pickDslFile,
            ),
          );
        }
        if (mounted) {
          store.setShowImportDSLModal(false);
          _opening = false;
        }
      });
    }
  }

  @override
  void dispose() {
    _store?.showImportDSLModal.removeListener(_requested);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Dify's current-app overwrite dialog; the server callback stays injectable for tests and other editor hosts.
class UpdateDslModal extends StatefulWidget {
  const UpdateDslModal({super.key, required this.appMode, required this.pickFile, this.onImport, this.onBackup});
  final String appMode;
  final PickDslFile pickFile;
  final WorkflowImport? onImport;
  final VoidCallback? onBackup;
  @override
  State<UpdateDslModal> createState() => _UpdateDslModalState();
}

class _UpdateDslModalState extends State<UpdateDslModal> {
  DslFile? _file;
  bool _busy = false;
  bool _picking = false;
  Future<void> _pick() async {
    if (_busy || _picking) return;
    _picking = true;
    try {
      final file = await widget.pickFile();
      if (mounted && file != null) setState(() => _file = file);
    } on Object catch (e) {
      toast.error('$e');
    } finally {
      _picking = false;
    }
  }

  Future<void> _import({bool confirm = false}) async {
    if (_busy || _file == null || widget.onImport == null) return;
    if (!validateDslContent(_file!.content, widget.appMode)) {
      toast.error(_w('common.importFailure'));
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.onImport!(_file!.content, confirm: confirm);
      if (!mounted) return;
      if (result.status == 'completed') {
        toast.success(_w('common.importSuccess'));
      } else {
        toast.warning(_w('common.importWarning'), description: _w('common.importWarningDetails'));
      }
      Navigator.of(context).pop();
    } on DslVersionUnconfirmed catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final yes = await showDifyDialog<bool>(
        context,
        builder: (context) => DifyDialogSurface(
          width: 480,
          padding: const EdgeInsets.all(24),
          scrollable: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _a('newApp.appCreateDSLErrorTitle'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '${_a('newApp.appCreateDSLErrorPart1')}${_a('newApp.appCreateDSLErrorPart2')}\n\n${_a('newApp.appCreateDSLErrorPart3')}${e.importedVersion}\n${_a('newApp.appCreateDSLErrorPart4')}${e.currentVersion}',
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DifyButton(
                    key: const Key('cancel-dsl-version'),
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(_a('newApp.Cancel')),
                  ),
                  const SizedBox(width: 8),
                  DifyButton(
                    key: const Key('confirm-dsl-version'),
                    variant: DifyButtonVariant.primary,
                    tone: DifyButtonTone.destructive,
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(_a('newApp.Confirm')),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      if (yes == true && mounted) await _import(confirm: true);
    } on TransportException catch (e) {
      toast.error(e.message);
    } on Object {
      toast.error(_w('common.importFailure'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: _a('importApp'),
    width: 480,
    padding: const EdgeInsets.all(24),
    scrollable: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_a('importApp'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ),
            DifyIconButton(
              label: DifyI18n.tr('common', 'operation.close'),
              icon: const RemixIcon('close-line', size: 18),
              onPressed: _busy ? null : () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: DifyGradients.toastWarningBg.scale(0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_w('common.importDSLTip')),
              const SizedBox(height: 8),
              DifyButton(
                size: DifyButtonSize.small,
                leading: const RemixIcon('file-download-line', size: 14),
                disabled: _busy || widget.onBackup == null,
                onPressed: _busy ? null : widget.onBackup,
                child: Text(_w('common.backupCurrentDraft')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(_w('common.chooseDSL'), style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        DifyButton(
          key: const Key('choose-dsl-file'),
          disabled: _busy,
          onPressed: _pick,
          leading: const RemixIcon('upload-cloud-line', size: 20),
          child: Text(_file?.name ?? _w('common.chooseDSL')),
        ),
        if (widget.onImport == null)
          const Padding(padding: EdgeInsets.only(top: 12), child: Text('Import is not available for this document.')),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            DifyButton(disabled: _busy, onPressed: () => Navigator.pop(context), child: Text(_a('newApp.Cancel'))),
            const SizedBox(width: 8),
            DifyButton(
              key: const Key('overwrite-import-dsl'),
              disabled: _file == null || widget.onImport == null,
              loading: _busy,
              variant: DifyButtonVariant.primary,
              tone: DifyButtonTone.destructive,
              onPressed: _import,
              child: Text(_w('common.overwriteAndImport')),
            ),
          ],
        ),
      ],
    ),
  );
}
