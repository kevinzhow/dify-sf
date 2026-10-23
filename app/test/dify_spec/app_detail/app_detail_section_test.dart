// dify-spec: web/app/components/app-sidebar/__tests__/app-detail-section.spec.tsx
//
// Dify's links carry hrefs; dify-sf's pages are switched in place, so a link is found by its label and its target is
// the page it opens. Deploy and Resource Access are enterprise / RBAC pages that dify-sf never shows.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/app_permission.dart';
import 'package:dify_sf_app/src/app_detail/app_sidebar.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<List<AppDetailPageId>> _render(WidgetTester t, {String mode = 'chat', List<String> keys = const []}) async {
  final opened = <AppDetailPageId>[];
  final app = testApp(mode: mode, keys: keys);
  await renderDetail(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 240,
        height: 600,
        child: AppDetailSection(
          app: app,
          acl: appACLCapabilities(app.permissionKeys),
          current: AppDetailPageId.logs,
          onSelect: opened.add,
          appInfo: const SizedBox(),
        ),
      ),
    ),
  );
  return opened;
}

/// The link's target: tapping it opens [page].
Future<void> _expectLink(WidgetTester t, List<AppDetailPageId> opened, String name, AppDetailPageId page) async {
  expect(find.text(name), findsOneWidget);
  await t.tap(find.text(name));
  expect(opened.last, page);
}

void main() {
  group('AppDetailSection', () {
    group('Rendering', () {
      testWidgets('should render only overview for chat apps with app monitor permission', (t) async {
        final opened = await _render(t, keys: [AppPermissionKeys.monitor]);
        await _expectLink(t, opened, 'common.appMenus.overview', AppDetailPageId.overview);
        expect(find.text('common.appMenus.logs'), findsNothing);
        expect(find.text('common.appMenus.annotations'), findsNothing);
      });

      testWidgets('should render logs and annotations for chat apps with app log and annotation permission', (t) async {
        final opened = await _render(t, keys: [AppPermissionKeys.logAndAnnotation]);
        await _expectLink(t, opened, 'common.appMenus.logs', AppDetailPageId.logs);
        await _expectLink(t, opened, 'common.appMenus.annotations', AppDetailPageId.annotations);
        expect(find.text('common.appMenus.overview'), findsNothing);
      });

      testWidgets('should only render logs navigation for workflow apps', (t) async {
        final opened = await _render(t, mode: AppModes.workflow, keys: [AppPermissionKeys.logAndAnnotation]);
        await _expectLink(t, opened, 'common.appMenus.logs', AppDetailPageId.logs);
        expect(find.text('common.appMenus.annotations'), findsNothing);
      });

      testWidgets('should only render logs navigation for completion apps', (t) async {
        final opened = await _render(t, mode: AppModes.completion, keys: [AppPermissionKeys.logAndAnnotation]);
        await _expectLink(t, opened, 'common.appMenus.logs', AppDetailPageId.logs);
        expect(find.text('common.appMenus.annotations'), findsNothing);
      });

      testWidgets('should render the layout navigation for users with view layout permission', (t) async {
        final opened = await _render(t, keys: [AppPermissionKeys.viewLayout]);
        // Dify's `/configuration` for a chat app: the editor page.
        await _expectLink(t, opened, 'common.appMenus.promptEng', AppDetailPageId.workflow);
        expect(AppDetailPageId.fromPath('/app/app-1/configuration'), AppDetailPageId.workflow);
        expect(find.text('common.appMenus.logs'), findsNothing);
        expect(find.text('common.appMenus.annotations'), findsNothing);
        expect(find.text('common.appMenus.overview'), findsNothing);
      });

      testWidgets('should hide the layout navigation when layout access is missing', (t) async {
        await _render(t, keys: [AppPermissionKeys.monitor]);
        expect(find.text('common.appMenus.promptEng'), findsNothing);
      });

      testWidgets('should render access point navigation using its app route', (t) async {
        final opened = await _render(t, keys: [AppPermissionKeys.accessPointView]);
        await _expectLink(t, opened, 'common.appMenus.accessPoint', AppDetailPageId.accessPoint);
        expect(AppDetailPageId.accessPoint.segment, 'access-point');
        expect(find.text('common.appMenus.apiAccess'), findsNothing);
      });

      testWidgets('should hide access point navigation without view permission', (t) async {
        await _render(t, keys: [AppPermissionKeys.monitor]);
        expect(find.text('common.appMenus.accessPoint'), findsNothing);
      });

      testWidgets('should hide deploy navigation when \$label', (t) async {
        for (final (mode, keys) in [
          ('chat', [appAclDeploy]),
          ('workflow', [AppPermissionKeys.monitor]),
        ]) {
          await _render(t, mode: mode, keys: keys);
          expect(find.text('common.appMenus.deploy'), findsNothing);
        }
      });

      testWidgets('should hide resource access navigation for Agent apps', (t) async {
        await _render(t, mode: 'agent', keys: [AppPermissionKeys.accessConfig]);
        expect(find.text('common.settings.resourceAccess'), findsNothing);
      });

      testWidgets('should hide resource access navigation when app access config permission is missing', (t) async {
        await _render(t, keys: [AppPermissionKeys.monitor]);
        expect(find.text('common.settings.resourceAccess'), findsNothing);
      });

      testWidgets('should hide resource access navigation when RBAC is disabled', (t) async {
        await _render(t, keys: [AppPermissionKeys.accessConfig]);
        expect(find.text('common.settings.resourceAccess'), findsNothing);
      });
    });
  });
}
