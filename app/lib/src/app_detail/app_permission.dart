/// web/utils/permission.ts (`getAppACLCapabilities`) and web/utils/app-redirection.ts (`getRedirectionPath`), Dify
/// 1.17.1. dify-sf is the community edition: RBAC is off and apps have no maintainer, so in practice the legacy role
/// keys decide; the maintainer rule is ported anyway (it costs nothing and keeps Dify's specs).
library;

import 'package:collab_client/collab_client.dart';

/// `AppACLPermission` keys not in collab_client's [AppPermissionKeys] (enterprise: no community-edition role has it).
const appAclDeploy = 'app.acl.deploy';

/// `hasPermission`: [keys] holds [key] (or, for a list, any of them).
bool hasPermission(List<String>? keys, Object key) {
  if (keys == null) return false;
  if (key is List<String>) return key.any(keys.contains);
  return keys.contains(key);
}

/// `ResourceMaintainerPermissionOptions`.
typedef ResourceMaintainerOptions = ({
  String? currentUserId,
  String? resourceMaintainer,
  List<String>? workspacePermissionKeys,
  bool isRbacEnabled,
});

/// `getAppACLCapabilities`'s result.
typedef AppACLCapabilities = ({
  bool canManageAccessPoint,
  bool canViewAccessPoint,
  bool canViewLayout,
  bool canTestAndRun,
  bool canEdit,
  bool canAccessLayout,
  bool canPreviewApp,
  bool canImportExportDSL,
  bool canDelete,
  bool canReleaseAndVersion,
  bool canDeploy,
  bool canMonitor,
  bool canConfigureTracing,
  bool canAccessLogAndAnnotation,
  bool canAccessConfig,
});

/// `getAppACLCapabilities`: the app's legacy keys, plus everything (but deploy) for the app's maintainer when the
/// maintainer may create apps.
AppACLCapabilities appACLCapabilities(
  List<String>? keys, {
  bool rbacEnabled = false,
  String? currentUserId,
  String? resourceMaintainer,
  List<String>? workspacePermissionKeys,
}) {
  final maintainer =
      currentUserId != null &&
      currentUserId.isNotEmpty &&
      resourceMaintainer != null &&
      resourceMaintainer.isNotEmpty &&
      currentUserId == resourceMaintainer &&
      hasPermission(workspacePermissionKeys, AppPermissionKeys.createAndManagement);
  bool has(String k) => maintainer || hasPermission(keys, k);
  final viewLayout = has(AppPermissionKeys.viewLayout), testAndRun = has(AppPermissionKeys.testAndRun);
  final edit = has(AppPermissionKeys.edit), manageAccessPoint = has(AppPermissionKeys.accessPointManage);
  return (
    canManageAccessPoint: manageAccessPoint,
    canViewAccessPoint: manageAccessPoint || has(AppPermissionKeys.accessPointView),
    canViewLayout: viewLayout,
    canTestAndRun: testAndRun,
    canEdit: edit,
    canAccessLayout: viewLayout || testAndRun || edit,
    canPreviewApp: viewLayout || testAndRun,
    canImportExportDSL: has(AppPermissionKeys.importExportDsl),
    canDelete: has(AppPermissionKeys.delete),
    canReleaseAndVersion: has(AppPermissionKeys.releaseAndVersion),
    canDeploy: hasPermission(keys, appAclDeploy),
    canMonitor: has(AppPermissionKeys.monitor),
    canConfigureTracing: has(AppPermissionKeys.tracingConfig),
    canAccessLogAndAnnotation: has(AppPermissionKeys.logAndAnnotation),
    canAccessConfig: rbacEnabled && has(AppPermissionKeys.accessConfig),
  );
}

/// `hasOnlyAppPreviewPermission`: the card is a dimmed information-only card.
bool hasOnlyAppPreviewPermission(List<String>? keys) =>
    keys != null && keys.length == 1 && keys.first == AppPermissionKeys.preview;

/// `getRedirectionPath`: where opening an app leads (`/app/{id}/{page}`, `/apps` when no page is allowed; Agent apps
/// go to Dify's agent pages, which dify-sf does not have).
String appRedirectionPath({
  required String id,
  required String mode,
  List<String>? permissionKeys,
  String? boundAgentId,
  bool rbacEnabled = false,
  String? currentUserId,
  String? resourceMaintainer,
  List<String>? workspacePermissionKeys,
}) {
  if (mode == 'agent') {
    return boundAgentId != null && boundAgentId.isNotEmpty ? '/agents/$boundAgentId/configure' : '/agents';
  }
  final acl = appACLCapabilities(
    permissionKeys,
    rbacEnabled: rbacEnabled,
    currentUserId: currentUserId,
    resourceMaintainer: resourceMaintainer,
    workspacePermissionKeys: workspacePermissionKeys,
  );
  if (acl.canAccessLayout) {
    return mode == AppModes.workflow || mode == AppModes.advancedChat ? '/app/$id/workflow' : '/app/$id/configuration';
  }
  if (acl.canMonitor) return '/app/$id/overview';
  if (acl.canAccessLogAndAnnotation) return '/app/$id/logs';
  if (acl.canAccessConfig) return '/app/$id/access-config';
  if (mode == AppModes.workflow && acl.canDeploy) return '/app/$id/deploy';
  if (acl.canViewAccessPoint) return '/app/$id/access-point';
  return '/apps';
}

/// `getRedirection`: hands [appRedirectionPath] to [redirect].
void appRedirection(
  AppInfo app,
  void Function(String path) redirect, {
  bool rbacEnabled = false,
  String? currentUserId,
  List<String>? workspacePermissionKeys,
}) => redirect(
  appRedirectionPath(
    id: app.id,
    mode: app.mode,
    permissionKeys: app.permissionKeys,
    rbacEnabled: rbacEnabled,
    currentUserId: currentUserId,
    workspacePermissionKeys: workspacePermissionKeys,
  ),
);
