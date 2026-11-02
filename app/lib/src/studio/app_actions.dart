/// app-card/interactions.tsx: what a Studio app's operations do (star toggle, Edit info, Duplicate, Export DSL,
/// Delete), shared by the desktop card ([AppCard]: its hover bar, menu and context menu) and the phone row
/// ([AppListRow]: its action sheet).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/dsl/dsl_export_confirm_modal.dart' show showDslExportConfirm;
import 'app_modals.dart';
import 'export_app_dsl.dart';
import 'studio_scope.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);

/// Which operations an app offers (`shouldShowOperationsMenu` and its parts).
class AppOperations {
  const AppOperations({required this.edit, required this.duplicate, required this.export, required this.delete});

  /// The app's ACL and the workspace's create right.
  factory AppOperations.of(AppInfo app, StudioServices services) {
    final acl = appACLCapabilities(app.permissionKeys);
    return AppOperations(
      edit: acl.canEdit,
      duplicate: services.canCreateApp,
      export: acl.canImportExportDSL,
      delete: acl.canDelete,
    );
  }

  final bool edit, duplicate, export, delete;

  /// `shouldShowOperationsMenu`.
  bool get any => edit || duplicate || export || delete;
}

/// The operations of [app] over the page's [services]; the state rebuilds while one is running ([togglingStar],
/// [exporting]).
mixin StudioAppActions<T extends StatefulWidget> on State<T> {
  AppInfo get app;

  /// The page's services, read in `build` ([StudioScope.of]).
  late StudioServices services;

  bool togglingStar = false;

  /// `useExportAppDsl` / `useExportWorkflowAppDsl` over the page's services.
  late final exporter = AppDslExporter(
    exportDsl: (id, {includeSecret = false}) => services.api.exportDsl(id, includeSecret: includeSecret),
    environmentVariables: (id) => services.environmentVariables(id),
    saveDsl: (name, yaml) => services.saveDsl(name, yaml),
  )..addListener(_exportChanged);

  bool get exporting => exporter.isExporting;

  void _exportChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    exporter.dispose();
    super.dispose();
  }

  Future<void> toggleStar(bool pressed) async {
    if (togglingStar) return;
    setState(() => togglingStar = true);
    try {
      if (pressed) {
        await services.api.star(app.id);
      } else {
        await services.api.unstar(app.id);
      }
      await services.refresh();
    } on TransportException catch (e) {
      toast.error(e.message.isNotEmpty ? e.message : _a('studio.starFailed'));
    } on Object {
      toast.error(_a('studio.starFailed'));
    } finally {
      if (mounted) setState(() => togglingStar = false);
    }
  }

  Future<void> editApp() {
    final services = this.services;
    return showEditAppModal(
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
        uploadIcon: services.uploadIcon,
        onHide: hide,
        onConfirm: (p) async {
          try {
            await services.api.update(
              app.id,
              name: p.name,
              iconType: p.iconType,
              icon: p.icon,
              iconBackground: p.iconBackground,
              description: p.description,
              useIconAsAnswerIcon: p.useIconAsAnswerIcon,
              maxActiveRequests: p.maxActiveRequests,
            );
            toast.success(_a('editDone'));
            await services.refresh();
          } on TransportException catch (e) {
            toast.error(e.message.isNotEmpty ? e.message : _a('editFailed'));
          } on Object {
            toast.error(_a('editFailed'));
          }
        },
      ),
    );
  }

  Future<void> duplicateApp() {
    final services = this.services, app = this.app;
    return showDifyDialog<void>(
      context,
      builder: (dialog) => DuplicateAppModal(
        appName: app.name,
        iconType: app.iconType,
        icon: app.icon ?? '',
        iconBackground: app.iconBackground,
        iconUrl: app.iconUrl,
        uploadIcon: services.uploadIcon,
        onHide: () => Navigator.pop(dialog),
        onConfirm: (p) async {
          final AppInfo copy;
          try {
            copy = await services.api.copy(
              app.id,
              name: p.name,
              iconType: p.iconType,
              icon: p.icon,
              iconBackground: p.iconBackground,
            );
          } on Object {
            toast.error(_a('newApp.appCreateFailed'));
            return;
          }
          toast.success(_a('newApp.appCreated'));
          unawaited(services.refresh());
          await services.open(copy);
        },
      ),
    );
  }

  Future<void> deleteApp() {
    final services = this.services, app = this.app;
    return showDifyDialog<void>(
      context,
      dismissible: false,
      builder: (dialog) => DeleteAppDialog(
        appName: app.name,
        onClose: () => Navigator.pop(dialog),
        onConfirm: () async {
          try {
            await services.api.delete(app.id);
          } on TransportException catch (e) {
            toast.error('${_a('appDeleteFailed')}${e.message.isNotEmpty ? ': ${e.message}' : ''}');
            return false;
          } on Object {
            toast.error(_a('appDeleteFailed'));
            return false;
          }
          toast.success(_a('appDeleted'));
          unawaited(services.refresh());
          return true;
        },
      ),
    );
  }

  /// `exportCheck`: a workflow / chatflow asks first when its environment holds secrets.
  Future<void> exportApp() async {
    if (exporting) return;
    final app = this.app;
    final result = app.mode == AppModes.workflow || app.mode == AppModes.advancedChat
        ? await exporter.exportWorkflowAppDsl(appId: app.id, appName: app.name)
        : await exporter.exportAppDsl(appId: app.id, appName: app.name);
    if (result.status != 'confirmation-required' || !mounted) return;
    await showDslExportConfirm(
      context,
      envList: result.secretEnvList,
      onConfirm: (include) async {
        await exporter.exportAppDsl(appId: app.id, appName: app.name, includeSecret: include);
      },
    );
  }
}
