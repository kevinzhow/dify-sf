// dify-spec: web/app/components/app-sidebar/app-info/__tests__/app-info-trigger.spec.tsx
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_info_actions.dart';
import 'package:dify_sf_app/src/app_detail/app_permission.dart';
import 'package:dify_sf_app/src/app_detail/app_sidebar.dart';
import 'package:dify_sf_app/src/studio/export_app_dsl.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const _defaultKeys = [AppPermissionKeys.edit, AppPermissionKeys.importExportDsl, AppPermissionKeys.delete];

class _Fixture {
  _Fixture(this.app, {Future<String> Function()? export}) {
    exporter = AppDslExporter(
      exportDsl: (id, {includeSecret = false}) {
        exports++;
        return export?.call() ?? Future.value('yaml');
      },
      environmentVariables: (_) async => const [],
      saveDsl: (_, _) async {},
    );
    actions = AppInfoActions(
      apps: FakeAppsApi(),
      appDetail: () => app,
      setAppDetail: (_) {},
      exporter: exporter,
      redirect: (_, {app}) {},
    );
  }

  final AppInfo app;
  late final AppDslExporter exporter;
  late final AppInfoActions actions;
  int exports = 0;
}

Future<_Fixture> _render(
  WidgetTester t, {
  AppInfo? app,
  bool expand = true,
  bool canCreateApp = true,
  Future<String> Function()? export,
}) async {
  final f = _Fixture(
    app ?? testApp(mode: AppModes.chat, keys: _defaultKeys),
    export: export,
  );
  await renderDetail(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 240,
        child: ListenableBuilder(
          listenable: f.actions,
          builder: (context, _) => AppInfoTrigger(
            app: f.app,
            expand: expand,
            operationGroups: f.actions.operationGroups(
              f.app,
              appACLCapabilities(f.app.permissionKeys),
              canCreateApp: canCreateApp,
            ),
          ),
        ),
      ),
    ),
  );
  return f;
}

final _trigger = find.byKey(const ValueKey('app-info-more'));

List<String> _items() => [
  for (final e
      in find
          .byWidgetPredicate(
            (w) => w.key is ValueKey<String> && '${(w.key! as ValueKey).value}'.startsWith('app-info-op-'),
          )
          .evaluate())
    (e.widget.key! as ValueKey<String>).value.substring('app-info-op-'.length),
];

void main() {
  group('AppInfoTrigger', () {
    testWidgets('renders expanded app metadata without making the app info clickable', (t) async {
      final f = await _render(
        t,
        app: testApp(name: 'My Chatbot', mode: AppModes.advancedChat, keys: _defaultKeys),
      );
      expect(t.widget<DifyAppIcon>(find.byType(DifyAppIcon)).size, DifyAppIconSize.large);
      expect(find.text('My Chatbot'), findsOneWidget);
      expect(find.text('APP.TYPES.ADVANCED'), findsOneWidget, reason: 'app.types.advanced, uppercase');
      final name = t.getSemantics(find.text('My Chatbot'));
      expect(name.flagsCollection.isButton, isFalse);
      await t.tap(find.byType(DifyAppIcon));
      expect(f.actions.activeModal, isNull);
      expect(f.exports, 0);
    });

    testWidgets('renders only the medium app icon when collapsed', (t) async {
      await _render(t, expand: false);
      expect(t.widget<DifyAppIcon>(find.byType(DifyAppIcon)).size, DifyAppIconSize.medium);
      expect(find.text('Test App'), findsNothing);
      expect(_trigger, findsNothing);
    });

    testWidgets('shows every available chat app operation and keeps workflow conversion last', (t) async {
      final f = await _render(t);
      await t.tap(_trigger);
      await settle(t, 3);
      expect(_items(), ['edit', 'duplicate', 'export', 'delete', 'switch']);
      expect(find.text('app.editApp'), findsOneWidget);
      expect(find.text('app.switch'), findsOneWidget);
      await t.tap(find.text('app.switch'));
      await settle(t, 3);
      expect(f.actions.activeModal, AppInfoModal.switchApp);
    });

    testWidgets('shows import DSL for workflow apps without a workflow conversion operation', (t) async {
      final f = await _render(
        t,
        app: testApp(mode: AppModes.workflow, keys: _defaultKeys),
      );
      await t.tap(_trigger);
      await settle(t, 3);
      expect(find.text('workflow.common.importDSL'), findsOneWidget);
      expect(find.text('app.switch'), findsNothing);
      await t.tap(find.text('workflow.common.importDSL'));
      await settle(t, 3);
      expect(f.actions.activeModal, AppInfoModal.importDsl);
    });

    testWidgets('runs export from the menu and disables it while an export is pending', (t) async {
      final pending = Completer<String>();
      final f = await _render(t, export: () => pending.future);
      unawaited(f.exporter.exportAppDsl(appId: 'app-1', appName: 'Test App'));
      await t.pump();
      expect(f.actions.isExporting, isTrue);
      await t.tap(_trigger);
      await settle(t, 3);
      // aria-disabled: choosing it does nothing.
      final during = f.exports;
      await t.tap(find.text('app.export'));
      await settle(t, 3);
      expect(f.exports, during);
      expect(find.text('app.export'), findsOneWidget, reason: 'the menu stays open');
      pending.complete('yaml');
      await settle(t, 3);
      expect(f.actions.isExporting, isFalse);
      final before = f.exports;
      if (find.text('app.export').evaluate().isEmpty) {
        await t.tap(_trigger);
        await settle(t, 3);
      }
      await t.tap(find.text('app.export'));
      await settle(t, 3);
      expect(f.exports, before + 1, reason: 'exportCheck: a chat app exports at once');
    });

    testWidgets('hides the operations trigger when no operation is permitted', (t) async {
      await _render(t, app: testApp(keys: [AppPermissionKeys.viewLayout]), canCreateApp: false);
      expect(_trigger, findsNothing);
    });
  });
}
