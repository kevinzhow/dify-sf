/// What the Studio's cards and dialogs need from the page: the apps API, the signed-in user's rights, navigation into
/// an app and the list refetch (react-query's invalidation after a mutation). Plus utils/permission.ts's app rules.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../app_detail/app_permission.dart';
import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;

export '../app_detail/app_permission.dart';

/// How the Studio opens an app: at [path], Dify's `getRedirectionPath` (`/app/{id}/workflow` for roles that may see
/// the editor, `/app/{id}/overview` for normal members, `/app/{id}/access-point` for dataset operators).
typedef OpenStudioApp = Future<void> Function(AppInfo app, {required String path});

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

  /// Opens [app] as Dify's `getRedirection` would (nothing when no page of the app is allowed: Dify's `/apps`).
  Future<void> open(AppInfo app) async {
    final path = appRedirectionPath(
      id: app.id,
      mode: app.mode,
      permissionKeys: app.permissionKeys,
      currentUserId: currentUserId,
      workspacePermissionKeys: canCreateApp ? const [AppPermissionKeys.createAndManagement] : const [],
    );
    if (path.startsWith('/app/')) await openApp(app, path: path);
  }
}

class StudioScope extends InheritedWidget {
  const StudioScope({super.key, required this.services, required super.child});

  final StudioServices services;

  static StudioServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StudioScope>()!.services;

  @override
  bool updateShouldNotify(StudioScope old) => old.services != services;
}
