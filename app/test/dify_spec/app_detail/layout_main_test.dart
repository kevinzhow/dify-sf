// dify-spec: web/app/(commonLayout)/app/(appDetailLayout)/[appId]/__tests__/layout-main.spec.tsx
//
// The layout is AppDetailPage; Dify's pathname is the page it opens, `router.replace` a page switch (or leaving to
// the Studio for `/apps`). dify-sf has no Deploy and Resource Access pages (enterprise / RBAC) and no Agent apps.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/app_permission.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

/// The apps API with one app, counting `GET /apps/{id}`.
class _Apps extends FakeAppsApi {
  _Apps();
  int gets = 0;

  /// The app's `permission_keys` (Dify's spec sets them per case); null: the owner's.
  List<String>? keys;

  @override
  Future<AppInfo> get(String id) async {
    gets++;
    final app = await super.get(id);
    return keys == null ? app : AppInfo.fromJson({...app.json, 'permission_keys': keys});
  }
}

class _Fixture {
  _Fixture({String mode = AppModes.workflow, List<String>? keys}) {
    final seeded = apps.seed(id: 'app-1', name: 'Demo App', mode: mode);
    appId = seeded.id;
    apps.keys = keys;
  }

  final apps = _Apps();
  late final String appId;
  int left = 0;
}

final _pages = <AppDetailPageId, AppDetailPageBuilder>{
  for (final p in AppDetailPageId.values)
    if (p != AppDetailPageId.workflow) p: (context, detail) => Text('App page content ${p.segment}'),
};

Future<_Fixture> _render(
  WidgetTester t,
  AppDetailPageId? page, {
  String mode = AppModes.workflow,
  List<String>? keys,
}) async {
  final f = _Fixture(mode: mode, keys: keys);
  await renderDetail(
    t,
    AppDetailPage(
      key: UniqueKey(),
      appId: f.appId,
      apps: f.apps,
      initialPage: page,
      pageBuilders: _pages,
      editor: (context, host) => const Text('App page content workflow'),
      onLeave: () => f.left++,
    ),
    size: const Size(1440, 900),
  );
  return f;
}

AppDetailPageState _shell(WidgetTester t) => t.state(find.byType(AppDetailPage));
String _title(WidgetTester t) => t.widget<Title>(find.byType(Title).last).title;
bool _content(AppDetailPageId p) => find.text('App page content ${p.segment}').evaluate().isNotEmpty;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppDetailLayout', () {
    group('Document title', () {
      testWidgets('identifies the current detail page for %s', (t) async {
        for (final (path, title, mode) in [
          ('/app/app-1/workflow', 'common.appMenus.promptEng', AppModes.workflow),
          ('/app/app-1/configuration', 'common.appMenus.promptEng', AppModes.chat),
          ('/app/app-1/access-point', 'common.appMenus.accessPoint', AppModes.workflow),
          ('/app/app-1/logs', 'common.appMenus.logs', AppModes.workflow),
          ('/app/app-1/annotations', 'common.appMenus.annotations', AppModes.chat),
          ('/app/app-1/overview', 'common.appMenus.overview', AppModes.workflow),
        ]) {
          await _render(t, AppDetailPageId.fromPath(path), mode: mode, keys: AppPermissionKeys.forRole('owner'));
          expect(_title(t), '$title · Demo App - Dify', reason: path);
        }
      });

      testWidgets('updates after a directly loaded app is renamed in the store', (t) async {
        final f = await _render(t, AppDetailPageId.workflow);
        expect(_title(t), 'common.appMenus.promptEng · Demo App - Dify');
        await f.apps.update(f.appId, name: 'Renamed App');
        await _shell(t).refreshApp();
        await t.pump();
        expect(_title(t), 'common.appMenus.promptEng · Renamed App - Dify');
      });
    });

    testWidgets('should keep app detail data when navigating between pages in the same app', (t) async {
      final f = await _render(t, AppDetailPageId.workflow);
      expect(f.apps.gets, 1);
      _shell(t).navigate(AppDetailPageId.logs);
      await settle(t);
      expect(_content(AppDetailPageId.logs), isTrue);
      expect(f.apps.gets, 1);
      expect(_shell(t).app?.id, f.appId);
    });

    testWidgets('should redirect restricted app pages before exposing app detail content', (t) async {
      final f = await _render(t, AppDetailPageId.logs, keys: [AppPermissionKeys.viewLayout]);
      expect(_shell(t).page, AppDetailPageId.workflow);
      expect(_content(AppDetailPageId.logs), isFalse);
      expect(f.left, 0);
    });

    testWidgets('should redirect logs pages when log and annotation access is missing', (t) async {
      await _render(t, AppDetailPageId.logs, keys: [AppPermissionKeys.monitor]);
      expect(_shell(t).page, AppDetailPageId.overview);
      expect(_content(AppDetailPageId.logs), isFalse);
    });

    testWidgets('should allow users with log and annotation access to open logs directly', (t) async {
      await _render(t, AppDetailPageId.logs, keys: [AppPermissionKeys.logAndAnnotation]);
      expect(_shell(t).page, AppDetailPageId.logs);
      expect(_content(AppDetailPageId.logs), isTrue);
      expect(_shell(t).app?.id, 'app-1');
    });

    testWidgets('should allow users with Access Point view permission to open the page directly', (t) async {
      await _render(t, AppDetailPageId.accessPoint, keys: [AppPermissionKeys.accessPointView]);
      expect(_shell(t).page, AppDetailPageId.accessPoint);
      expect(_content(AppDetailPageId.accessPoint), isTrue);
    });

    testWidgets('should redirect access point pages when view permission is missing', (t) async {
      final f = await _render(t, AppDetailPageId.accessPoint, keys: []);
      expect(f.left, 1, reason: '/apps: back to the Studio');
      expect(_content(AppDetailPageId.accessPoint), isFalse);
    });

    testWidgets('should keep cached Access Point content hidden while redirecting without view permission', (t) async {
      // dify-sf reads the app on open (no app store kept across pages): the content never shows.
      final f = await _render(t, AppDetailPageId.accessPoint, keys: []);
      expect(_content(AppDetailPageId.accessPoint), isFalse);
      expect(f.left, 1);
    });

    testWidgets('should allow users with layout access to open workflow pages directly', (t) async {
      await _render(t, AppDetailPageId.workflow);
      expect(_shell(t).page, AppDetailPageId.workflow);
      expect(_content(AppDetailPageId.workflow), isTrue);
    });

    testWidgets('should redirect workflow pages when layout access is missing', (t) async {
      final f = await _render(t, AppDetailPageId.workflow, keys: []);
      expect(f.left, 1);
      expect(_content(AppDetailPageId.workflow), isFalse);
    });

    testWidgets('should redirect overview pages when monitor access is missing', (t) async {
      await _render(t, AppDetailPageId.overview, keys: [AppPermissionKeys.viewLayout]);
      expect(_shell(t).page, AppDetailPageId.workflow);
      expect(_content(AppDetailPageId.overview), isFalse);
    });

    testWidgets('should allow users with monitor access to open overview directly', (t) async {
      await _render(t, AppDetailPageId.overview, keys: [AppPermissionKeys.monitor]);
      expect(_shell(t).page, AppDetailPageId.overview);
      expect(_content(AppDetailPageId.overview), isTrue);
    });

    testWidgets('should redirect annotation pages when log and annotation access is missing', (t) async {
      await _render(t, AppDetailPageId.annotations, mode: AppModes.chat, keys: [AppPermissionKeys.monitor]);
      expect(_shell(t).page, AppDetailPageId.overview);
      expect(_content(AppDetailPageId.annotations), isFalse);
    });

    testWidgets('should allow users with log and annotation access to open annotations directly', (t) async {
      await _render(
        t,
        AppDetailPageId.annotations,
        mode: AppModes.chat,
        keys: [AppPermissionKeys.logAndAnnotation],
      );
      expect(_shell(t).page, AppDetailPageId.annotations);
      expect(_content(AppDetailPageId.annotations), isTrue);
    });
  });

  test('the app detail guard matches layout-main', () {
    final none = appACLCapabilities(const []);
    for (final p in AppDetailPageId.values) {
      expect(appDetailPageAllowed(p, none), isFalse, reason: p.name);
    }
  });
}
