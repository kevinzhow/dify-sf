// dify-spec: web/utils/app-redirection.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/app_permission.dart';
import 'package:flutter_test/flutter_test.dart';

String _path(String id, String mode, List<String> keys, {String? agent, bool rbac = false}) =>
    appRedirectionPath(id: id, mode: mode, permissionKeys: keys, boundAgentId: agent, rbacEnabled: rbac);

AppInfo _app(String id, String mode, List<String> keys) => AppInfo(id: id, name: id, mode: mode, permissionKeys: keys);

void main() {
  group('app-redirection', () {
    group('getRedirectionPath', () {
      test('returns access point path when it is the only accessible app page', () {
        expect(_path('app-123', AppModes.chat, [AppPermissionKeys.accessPointView]), '/app/app-123/access-point');
      });

      test('returns the app list when no app page is accessible', () {
        expect(_path('app-123', AppModes.chat, []), '/apps');
      });

      test('returns the access point path for Access Point managers', () {
        expect(_path('app-123', AppModes.chat, [AppPermissionKeys.accessPointManage]), '/app/app-123/access-point');
      });

      test('returns workflow path for workflow mode when app ACL can access layout', () {
        expect(_path('app-123', AppModes.workflow, [AppPermissionKeys.viewLayout]), '/app/app-123/workflow');
      });

      test('returns workflow path for advanced-chat mode when app ACL can access layout', () {
        expect(_path('app-123', AppModes.advancedChat, [AppPermissionKeys.testAndRun]), '/app/app-123/workflow');
      });

      test('returns configuration path for chat mode when app ACL can access layout', () {
        expect(_path('app-123', AppModes.chat, [AppPermissionKeys.edit]), '/app/app-123/configuration');
      });

      test('returns configuration path for completion mode when app ACL can access layout', () {
        expect(_path('app-123', AppModes.completion, [AppPermissionKeys.viewLayout]), '/app/app-123/configuration');
      });

      test('returns configuration path for agent-chat mode when app ACL can access layout', () {
        expect(_path('app-456', AppModes.agentChat, [AppPermissionKeys.viewLayout]), '/app/app-456/configuration');
      });

      test('returns the Agent configure path when the backing Agent ID is available', () {
        expect(_path('app-1', 'agent', [AppPermissionKeys.viewLayout], agent: 'agent-1'), '/agents/agent-1/configure');
      });

      test('falls back to the Agent roster when the backing Agent ID is unavailable', () {
        expect(_path('app-1', 'agent', [AppPermissionKeys.viewLayout]), '/agents');
      });

      test('handles different app IDs', () {
        expect(_path('abc-123', AppModes.chat, [AppPermissionKeys.accessPointView]), '/app/abc-123/access-point');
        expect(_path('xyz-789', AppModes.workflow, [AppPermissionKeys.viewLayout]), '/app/xyz-789/workflow');
      });

      test(
        'returns layout path when the app maintainer has app.create_and_management permission without app ACL keys',
        () {
          expect(
            appRedirectionPath(
              id: 'app-123',
              mode: AppModes.chat,
              permissionKeys: const [],
              currentUserId: 'user-1',
              resourceMaintainer: 'user-1',
              workspacePermissionKeys: const [AppPermissionKeys.createAndManagement],
            ),
            '/app/app-123/configuration',
          );
        },
      );

      test('returns access config path when app ACL can only configure access', () {
        expect(
          _path('app-123', AppModes.chat, [AppPermissionKeys.accessConfig], rbac: true),
          '/app/app-123/access-config',
        );
      });

      test('returns access point path when RBAC is disabled and Access Point remains accessible', () {
        expect(
          _path('app-123', AppModes.chat, [AppPermissionKeys.accessConfig, AppPermissionKeys.accessPointView]),
          '/app/app-123/access-point',
        );
      });

      test('returns overview path when app ACL can only monitor the app', () {
        expect(_path('app-123', AppModes.chat, [AppPermissionKeys.monitor]), '/app/app-123/overview');
      });

      test('returns logs path when app ACL can only access logs and annotations', () {
        expect(_path('app-123', AppModes.chat, [AppPermissionKeys.logAndAnnotation]), '/app/app-123/logs');
      });

      test('returns deploy path when a workflow app ACL can only deploy', () {
        expect(_path('app-123', AppModes.workflow, [appAclDeploy]), '/app/app-123/deploy');
      });
    });

    group('getRedirection', () {
      test('calls redirection function with access point path when it is accessible', () {
        final calls = <String>[];
        appRedirection(_app('app-123', AppModes.chat, [AppPermissionKeys.accessPointView]), calls.add);
        expect(calls, ['/app/app-123/access-point']);
      });

      test('calls redirection function with workflow path when app ACL can access layout', () {
        final calls = <String>[];
        appRedirection(_app('app-123', AppModes.workflow, [AppPermissionKeys.viewLayout]), calls.add);
        expect(calls, ['/app/app-123/workflow']);
      });

      test('calls redirection function with configuration path for chat mode with layout access', () {
        final calls = <String>[];
        appRedirection(_app('app-123', AppModes.chat, [AppPermissionKeys.viewLayout]), calls.add);
        expect(calls, ['/app/app-123/configuration']);
      });

      test('works with different redirection functions', () {
        final paths = <String>[];
        appRedirection(_app('app-123', AppModes.workflow, [AppPermissionKeys.viewLayout]), (p) => paths.add(p));
        expect(paths, ['/app/app-123/workflow']);
      });
    });
  });
}
