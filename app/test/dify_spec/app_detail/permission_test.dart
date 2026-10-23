// dify-spec: web/utils/permission.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/app_permission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('permission', () {
    group('hasPermissionKey', () {
      const permissionKey = 'workspace.member.manage';

      test('returns true when the permission key exists', () {
        expect(hasPermission(['workspace.role.manage', permissionKey], permissionKey), isTrue);
      });

      test('returns false when the permission key does not exist', () {
        expect(hasPermission(['workspace.role.manage'], permissionKey), isFalse);
      });
    });

    group('getAppACLCapabilities', () {
      test('allows test-and-run users to access layout without edit', () {
        final c = appACLCapabilities([AppPermissionKeys.testAndRun]);
        expect(c.canTestAndRun, isTrue);
        expect(c.canAccessLayout, isTrue);
        expect(c.canEdit, isFalse);
      });

      test('allows view-layout users to preview the app but not run/debug', () {
        final c = appACLCapabilities([AppPermissionKeys.viewLayout]);
        expect(c.canPreviewApp, isTrue);
        expect(c.canAccessLayout, isTrue);
        expect(c.canTestAndRun, isFalse);
      });

      test('keeps deployment permission independent from app publishing and version management', () {
        final deploy = appACLCapabilities([appAclDeploy]);
        final release = appACLCapabilities([AppPermissionKeys.releaseAndVersion]);
        expect(deploy.canDeploy, isTrue);
        expect(deploy.canReleaseAndVersion, isFalse);
        expect(release.canDeploy, isFalse);
      });

      test('allows Access Point managers to view the page without granting management to viewers', () {
        final view = appACLCapabilities([AppPermissionKeys.accessPointView]);
        final manage = appACLCapabilities([AppPermissionKeys.accessPointManage]);
        expect(view.canViewAccessPoint, isTrue);
        expect(view.canManageAccessPoint, isFalse);
        expect(manage.canViewAccessPoint, isTrue);
        expect(manage.canManageAccessPoint, isTrue);
      });

      test('keeps monitor, tracing config, and log/annotation permissions independent', () {
        final monitor = appACLCapabilities([AppPermissionKeys.monitor]);
        final tracing = appACLCapabilities([AppPermissionKeys.tracingConfig]);
        final logs = appACLCapabilities([AppPermissionKeys.logAndAnnotation]);
        expect(monitor.canMonitor, isTrue);
        expect(monitor.canConfigureTracing, isFalse);
        expect(monitor.canAccessLogAndAnnotation, isFalse);
        expect(tracing.canMonitor, isFalse);
        expect(tracing.canConfigureTracing, isTrue);
        expect(tracing.canAccessLogAndAnnotation, isFalse);
        expect(logs.canMonitor, isFalse);
        expect(logs.canConfigureTracing, isFalse);
        expect(logs.canAccessLogAndAnnotation, isTrue);
      });
    });

    group('hasOnlyAppPreviewPermission', () {
      test('should return true when app ACL contains only preview permission', () {
        expect(hasOnlyAppPreviewPermission([AppPermissionKeys.preview]), isTrue);
      });

      test('should return false when app ACL contains preview permission and another permission', () {
        expect(hasOnlyAppPreviewPermission([AppPermissionKeys.preview, AppPermissionKeys.viewLayout]), isFalse);
      });
    });

    group('app maintainer capabilities', () {
      test('grants all app ACL capabilities without injecting app ACL permission keys', () {
        final keys = <String>[];
        final c = appACLCapabilities(
          keys,
          currentUserId: 'user-1',
          resourceMaintainer: 'user-1',
          workspacePermissionKeys: [AppPermissionKeys.createAndManagement],
          rbacEnabled: true,
        );
        expect(c.canViewLayout, isTrue);
        expect(c.canViewAccessPoint, isTrue);
        expect(c.canManageAccessPoint, isTrue);
        expect(c.canTestAndRun, isTrue);
        expect(c.canEdit, isTrue);
        expect(c.canImportExportDSL, isTrue);
        expect(c.canDelete, isTrue);
        expect(c.canReleaseAndVersion, isTrue);
        expect(c.canDeploy, isFalse);
        expect(c.canMonitor, isTrue);
        expect(c.canConfigureTracing, isTrue);
        expect(c.canAccessLogAndAnnotation, isTrue);
        expect(c.canAccessConfig, isTrue);
        expect(keys, isEmpty);
      });

      test('keeps app ACL capabilities unchanged when the maintainer lacks app.create_and_management permission', () {
        final c = appACLCapabilities(
          [AppPermissionKeys.viewLayout],
          currentUserId: 'user-1',
          resourceMaintainer: 'user-1',
          workspacePermissionKeys: [],
        );
        expect(c.canViewLayout, isTrue);
        expect(c.canEdit, isFalse);
        expect(c.canDelete, isFalse);
      });

      test('does not grant app access config when RBAC is disabled', () {
        expect(appACLCapabilities([AppPermissionKeys.accessConfig]).canAccessConfig, isFalse);
      });
    });
  });
}
