/// app-sidebar/app-info/use-app-info-actions.ts and app-info-modals.tsx (Dify 1.17.1): what the app info menu does
/// (edit info, duplicate, export with Dify's warning and secret check, import DSL over the app, delete) and the
/// dialogs it opens. Dify's "Switch to Workflow Orchestrate" applies to chat and completion apps, which dify-sf does
/// not have.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../studio/app_modals.dart';
import '../studio/export_app_dsl.dart';
import '../workflow_editor/dsl/dsl_export_confirm_modal.dart';
import '../workflow_editor/dsl/update_dsl_modal.dart';
import 'app_permission.dart';
import 'app_sidebar.dart' show AppInfoOperation;

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// `AppInfoModalType` (null: none).
enum AppInfoModal { edit, duplicate, delete, switchApp, importDsl, exportWarning }

/// `useAppInfoActions`: the menu's state (the open dialog, the secret variables awaiting the export decision) and
/// its actions on the current app ([appDetail], null while none is loaded). The state belongs to one app: a new
/// [resetKey] (another app) starts over.
class AppInfoActions extends ChangeNotifier {
  AppInfoActions({
    required this.apps,
    required this.appDetail,
    required this.setAppDetail,
    required this.exporter,
    required this.redirect,
    this.emitAppMetaUpdate,
    this._resetKey,
  });

  final AppsApi apps;

  /// The app store's `appDetail`.
  final AppInfo? Function() appDetail;

  /// `setAppDetail` (null: clear, after a delete).
  final void Function(AppInfo? app) setAppDetail;
  final AppDslExporter exporter;

  /// `router.replace`: an app path (`getRedirection` of a copy) or `/apps`.
  final void Function(String path, {AppInfo? app}) redirect;

  /// Tells the app's other collaborators that its info changed (Dify's `app_meta_update` event); null: none.
  final VoidCallback? emitAppMetaUpdate;

  String? _resetKey;
  AppInfoModal? _activeModal;
  List<Map<String, Object?>> _secretEnvList = const [];

  AppInfoModal? get activeModal => _activeModal;
  List<Map<String, Object?>> get secretEnvList => _secretEnvList;
  bool get isExporting => exporter.isExporting;

  /// Another app: the dialog and secret list start over.
  set resetKey(String? key) {
    if (key == _resetKey) return;
    _resetKey = key;
    _activeModal = null;
    _secretEnvList = const [];
    notifyListeners();
  }

  void openModal(AppInfoModal modal) {
    _activeModal = modal;
    notifyListeners();
  }

  void closeModal() {
    if (_activeModal == null) return;
    _activeModal = null;
    notifyListeners();
  }

  void setSecretEnvList(List<Map<String, Object?>> list) {
    _secretEnvList = list;
    notifyListeners();
  }

  /// `onEdit`: saves the info; closes the dialog and shows the change, or tells about the failure.
  Future<void> onEdit(AppInfoPayload p) async {
    final app = appDetail();
    if (app == null) return;
    try {
      final updated = await apps.update(
        app.id,
        name: p.name,
        iconType: p.iconType,
        icon: p.icon,
        iconBackground: p.iconBackground,
        description: p.description,
        useIconAsAnswerIcon: p.useIconAsAnswerIcon,
        maxActiveRequests: p.maxActiveRequests,
      );
      closeModal();
      toast.success(_t('app', 'editDone'));
      setAppDetail(updated);
      emitAppMetaUpdate?.call();
    } on Object {
      toast.error(_t('app', 'editFailed'));
    }
  }

  /// `onCopy`: duplicates the app and opens the copy where its role leads.
  Future<void> onCopy(DuplicatePayload p) async {
    final app = appDetail();
    if (app == null) return;
    final AppInfo copy;
    try {
      copy = await apps.copy(
        app.id,
        name: p.name,
        iconType: p.iconType,
        icon: p.icon,
        iconBackground: p.iconBackground,
      );
    } on Object {
      toast.error(_t('app', 'newApp.appCreateFailed'));
      return;
    }
    closeModal();
    toast.success(_t('app', 'newApp.appCreated'));
    appRedirection(copy, (path) => redirect(path, app: copy));
  }

  /// `onExport`: downloads the app's DSL.
  Future<void> onExport([bool includeSecret = false]) async {
    final app = appDetail();
    if (app == null) return;
    await exporter.exportAppDsl(appId: app.id, appName: app.name, includeSecret: includeSecret);
  }

  /// `exportCheck`: a workflow or chatflow first warns that the saved version is exported.
  Future<void> exportCheck() async {
    final app = appDetail();
    if (app == null || isExporting) return;
    if (app.mode != AppModes.workflow && app.mode != AppModes.advancedChat) {
      await onExport();
      return;
    }
    openModal(AppInfoModal.exportWarning);
  }

  /// `handleConfirmExport`: exports, or keeps the secret variables for the export decision.
  Future<void> handleConfirmExport() async {
    final app = appDetail();
    if (app == null) return;
    final result = await exporter.exportWorkflowAppDsl(appId: app.id, appName: app.name);
    if (result.status == 'confirmation-required') setSecretEnvList(result.secretEnvList);
    closeModal();
  }

  /// `onConfirmDelete`: deletes the app and goes back to the Studio; the dialog closes either way.
  Future<void> onConfirmDelete() async {
    final app = appDetail();
    if (app == null) return;
    try {
      await apps.delete(app.id);
      toast.success(_t('app', 'appDeleted'));
      setAppDetail(null);
      redirect('/apps');
    } on Object catch (e) {
      final message = e is TransportException ? e.message : '';
      toast.error('${_t('app', 'appDeleteFailed')}${message.isNotEmpty ? ': $message' : ''}');
    }
    closeModal();
  }

  /// app-info-trigger.tsx's operation groups: Edit info (`canEdit`), Duplicate (workspace
  /// `app.create_and_management`), Export DSL (`canImportExportDSL`), Import DSL (the same, workflow and chatflow
  /// apps); Delete (`canDelete`); Switch (`canEdit`, chat and completion apps).
  List<List<AppInfoOperation>> operationGroups(AppInfo app, AppACLCapabilities acl, {required bool canCreateApp}) {
    final workflowLike = app.mode == AppModes.advancedChat || app.mode == AppModes.workflow;
    return [
      [
        if (acl.canEdit)
          (
            id: 'edit',
            title: _t('app', 'editApp'),
            icon: 'edit-line',
            onClick: () => openModal(AppInfoModal.edit),
            loading: false,
            destructive: false,
          ),
        if (canCreateApp)
          (
            id: 'duplicate',
            title: _t('app', 'duplicate'),
            icon: 'file-copy-2-line',
            onClick: () => openModal(AppInfoModal.duplicate),
            loading: false,
            destructive: false,
          ),
        if (acl.canImportExportDSL)
          (
            id: 'export',
            title: _t('app', 'export'),
            icon: 'file-download-line',
            onClick: () => unawaited(exportCheck()),
            loading: isExporting,
            destructive: false,
          ),
        if (acl.canImportExportDSL && workflowLike)
          (
            id: 'import',
            title: _t('workflow', 'common.importDSL'),
            icon: 'file-upload-line',
            onClick: () => openModal(AppInfoModal.importDsl),
            loading: false,
            destructive: false,
          ),
      ],
      [
        if (acl.canDelete)
          (
            id: 'delete',
            title: _t('common', 'operation.delete'),
            icon: 'delete-bin-line',
            onClick: () => openModal(AppInfoModal.delete),
            loading: false,
            destructive: true,
          ),
      ],
      [
        if (acl.canEdit && (app.mode == AppModes.completion || app.mode == AppModes.chat))
          (
            id: 'switch',
            title: _t('app', 'switch'),
            icon: 'exchange-2-line',
            onClick: () => openModal(AppInfoModal.switchApp),
            loading: false,
            destructive: false,
          ),
      ],
    ];
  }
}

/// app-info-modals.tsx: shows the dialog [actions] asks for (and the secret export question while
/// [AppInfoActions.secretEnvList] is not empty); closing a dialog closes it in [actions].
class AppInfoModalsHost extends StatefulWidget {
  const AppInfoModalsHost({super.key, required this.actions, required this.app, this.importDsl, this.uploadIcon});

  final AppInfoActions actions;
  final AppInfo app;

  /// Replaces the app's workflow with a DSL file (the editor's import); null: Import DSL cannot run.
  final WorkflowImport? importDsl;
  final UploadAppIcon? uploadIcon;

  @override
  State<AppInfoModalsHost> createState() => _AppInfoModalsHostState();
}

class _AppInfoModalsHostState extends State<AppInfoModalsHost> {
  AppInfoModal? _showing;
  bool _secretShowing = false;

  @override
  void initState() {
    super.initState();
    widget.actions.addListener(_changed);
  }

  @override
  void didUpdateWidget(AppInfoModalsHost old) {
    super.didUpdateWidget(old);
    if (old.actions != widget.actions) {
      old.actions.removeListener(_changed);
      widget.actions.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.actions.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final a = widget.actions;
    if (a.activeModal != null && _showing == null) {
      final modal = _showing = a.activeModal;
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => unawaited(_show(modal!)))
        ..scheduleFrame();
    }
    if (a.secretEnvList.isNotEmpty && !_secretShowing) {
      _secretShowing = true;
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => unawaited(_showSecrets()))
        ..scheduleFrame();
    }
  }

  Future<void> _show(AppInfoModal modal) async {
    if (!mounted) return;
    final a = widget.actions, app = widget.app;
    switch (modal) {
      case AppInfoModal.edit:
        await showEditAppModal(
          context,
          (hide) => EditAppModal(
            isEditModal: true,
            appName: app.name,
            appIconType: app.iconType,
            appIcon: app.icon ?? '',
            appIconBackground: app.iconBackground,
            appIconUrl: app.iconUrl,
            appDescription: app.description,
            appMode: app.mode,
            appUseIconAsAnswerIcon: app.useIconAsAnswerIcon,
            maxActiveRequests: app.maxActiveRequests,
            uploadIcon: widget.uploadIcon,
            onHide: hide,
            onConfirm: a.onEdit,
          ),
        );
      case AppInfoModal.duplicate:
        await showDifyDialog<void>(
          context,
          builder: (dialog) => DuplicateAppModal(
            appName: app.name,
            iconType: app.iconType,
            icon: app.icon ?? '',
            iconBackground: app.iconBackground,
            iconUrl: app.iconUrl,
            uploadIcon: widget.uploadIcon,
            onHide: () => Navigator.pop(dialog),
            onConfirm: a.onCopy,
          ),
        );
      case AppInfoModal.delete:
        await showDifyDialog<void>(
          context,
          dismissible: false,
          builder: (dialog) => DeleteAppDialog(
            appName: app.name,
            onClose: () => Navigator.pop(dialog),
            onConfirm: () async {
              await a.onConfirmDelete();
              return true;
            },
          ),
        );
      case AppInfoModal.importDsl:
        await showDifyDialog<void>(
          context,
          builder: (_) => UpdateDslModal(
            appMode: app.mode,
            onImport: widget.importDsl,
            onBackup: () => unawaited(a.exportCheck()),
            pickFile: pickDslFile,
          ),
        );
      case AppInfoModal.exportWarning:
        await showDifyDialog<void>(
          context,
          dismissible: false,
          builder: (dialog) => ExportWarningDialog(actions: a, onClose: () => Navigator.pop(dialog)),
        );
      case AppInfoModal.switchApp:
        break;
    }
    _showing = null;
    // The export warning closes itself through handleConfirmExport; any other way out closes it here.
    if (mounted && a.activeModal == modal) a.closeModal();
  }

  Future<void> _showSecrets() async {
    if (!mounted) return;
    final a = widget.actions;
    await showDslExportConfirm(context, envList: a.secretEnvList, onConfirm: a.onExport);
    _secretShowing = false;
    if (mounted) a.setSecretEnvList(const []);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The export warning AlertDialog: "Export Current Saved Version" with Cancel and Confirm (`tone="default"`,
/// "Exporting..." while the export runs).
class ExportWarningDialog extends StatefulWidget {
  const ExportWarningDialog({super.key, required this.actions, required this.onClose});

  final AppInfoActions actions;
  final VoidCallback onClose;

  @override
  State<ExportWarningDialog> createState() => _ExportWarningDialogState();
}

class _ExportWarningDialogState extends State<ExportWarningDialog> {
  @override
  void initState() {
    super.initState();
    widget.actions.addListener(_changed);
  }

  @override
  void dispose() {
    widget.actions.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // handleConfirmExport closed the modal: the dialog goes.
    if (widget.actions.activeModal != AppInfoModal.exportWarning) {
      widget.onClose();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final exporting = widget.actions.isExporting;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => exporting ? null : widget.onClose()},
      child: DifyAlertDialog(
        title: _t('workflow', 'sidebar.exportWarning'),
        description: _t('workflow', 'sidebar.exportWarningDesc'),
        cancelKey: const ValueKey('export-warning-cancel'),
        confirmKey: const ValueKey('export-warning-confirm'),
        semanticButtonLabels: true,
        cancelLabel: _t('common', 'operation.cancel'),
        cancelDisabled: exporting,
        onCancel: widget.onClose,
        confirmTone: DifyButtonTone.normal,
        confirmLoading: exporting,
        confirmLabel: exporting ? _t('common', 'operation.exporting') : _t('common', 'operation.confirm'),
        onConfirm: () => unawaited(widget.actions.handleConfirmExport()),
      ),
    );
  }
}
