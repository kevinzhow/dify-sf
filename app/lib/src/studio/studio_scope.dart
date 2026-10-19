/// What the Studio's cards and dialogs need from the page: the apps API, the signed-in user's rights, navigation into
/// an app and the list refetch (react-query's invalidation after a mutation). Plus utils/permission.ts's app rules.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;

/// utils/permission.ts `getAppACLCapabilities` (RBAC off: no maintainer rule, no access config).
typedef AppACLCapabilities = ({
  bool canViewLayout,
  bool canTestAndRun,
  bool canEdit,
  bool canAccessLayout,
  bool canImportExportDSL,
  bool canDelete,
  bool canMonitor,
  bool canAccessConfig,
});

AppACLCapabilities appACLCapabilities(List<String> keys, {bool rbacEnabled = false}) {
  bool has(String k) => keys.contains(k);
  final viewLayout = has(AppPermissionKeys.viewLayout), testAndRun = has(AppPermissionKeys.testAndRun);
  final edit = has(AppPermissionKeys.edit);
  return (
    canViewLayout: viewLayout,
    canTestAndRun: testAndRun,
    canEdit: edit,
    canAccessLayout: viewLayout || testAndRun || edit,
    canImportExportDSL: has(AppPermissionKeys.importExportDsl),
    canDelete: has(AppPermissionKeys.delete),
    canMonitor: has(AppPermissionKeys.monitor),
    canAccessConfig: rbacEnabled && has(AppPermissionKeys.accessConfig),
  );
}

/// `hasOnlyAppPreviewPermission`: the card is a dimmed information-only card.
bool hasOnlyAppPreviewPermission(List<String> keys) => keys.length == 1 && keys.first == AppPermissionKeys.preview;

/// How the Studio opens an app: the editor, read-only without `app.acl.edit` (dify-sf has no overview page, so the
/// roles Dify sends to the overview get the editor in view mode).
typedef OpenStudioApp = Future<void> Function(AppInfo app, {required bool readOnly});

/// Saves an exported DSL file (Dify's `downloadBlob`, `<app name>.yml`).
typedef SaveDslFile = Future<void> Function(String fileName, String yaml);

Future<void> saveDslFile(String fileName, String yaml) async {
  final file = XFile.fromData(utf8.encode(yaml), name: fileName, mimeType: 'application/yaml');
  if (kIsWeb) return file.saveTo(fileName);
  final location = await getSaveLocation(suggestedName: fileName);
  if (location != null) await file.saveTo(location.path);
}

class StudioServices {
  const StudioServices({
    required this.api,
    required this.canCreateApp,
    required this.openApp,
    required this.refresh,
    required this.environmentVariables,
    this.currentUserId,
    this.saveDsl = saveDslFile,
    this.uploadIcon,
  });

  final AppsApi api;

  /// The workspace key `app.create_and_management` (Create, Import, Duplicate).
  final bool canCreateApp;
  final String? currentUserId;
  final OpenStudioApp openApp;

  /// Refetches the list and the starred row.
  final Future<void> Function() refresh;

  /// The app's environment variables (Dify JSON), for the export's secret check (`useExportWorkflowAppDsl`).
  final Future<List<Map<String, Object?>>> Function(String appId) environmentVariables;
  final SaveDslFile saveDsl;

  /// Image icons need file storage; null: the icon picker offers emoji only.
  final UploadAppIcon? uploadIcon;

  /// Opens [app] as Dify's `getRedirection` would.
  Future<void> open(AppInfo app) => openApp(app, readOnly: !appACLCapabilities(app.permissionKeys).canEdit);
}

class StudioScope extends InheritedWidget {
  const StudioScope({super.key, required this.services, required super.child});

  final StudioServices services;

  static StudioServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StudioScope>()!.services;

  @override
  bool updateShouldNotify(StudioScope old) => old.services != services;
}
