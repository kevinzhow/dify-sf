// dify-spec: web/app/components/app-sidebar/app-info/__tests__/use-app-info-actions.spec.ts
//
// Dify's react-query cache updates are the shell's `setAppDetail` (the sidebar, the title and the editor read the one
// app notifier); the Studio refetches its list when the app page closes.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/app_info_actions.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart' show AppInfoPayload, DuplicatePayload;
import 'package:dify_sf_app/src/studio/export_app_dsl.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The apps API calls of the hook, recorded; each can be made to fail.
class _Apps implements AppsApi {
  final calls = <String, List<Object?>>{};
  Object? failUpdate, failCopy, failDelete;
  AppInfo? updated;

  @override
  Future<AppInfo> update(
    String id, {
    required String name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
    bool? useIconAsAnswerIcon,
    int? maxActiveRequests,
  }) async {
    calls['update'] = [id, name, iconType, icon, iconBackground];
    if (failUpdate case final e?) throw e;
    return updated!;
  }

  @override
  Future<AppInfo> copy(
    String id, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) async {
    calls['copy'] = [id, name, iconType, icon, iconBackground];
    if (failCopy case final e?) throw e;
    return AppInfo(id: 'app-2', name: 'Copy', mode: 'chat', permissionKeys: AppPermissionKeys.forRole('owner'));
  }

  @override
  Future<void> delete(String id) async {
    calls['delete'] = [id];
    if (failDelete case final e?) throw e;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  _Fixture({AppInfo? app, this.noApp = false, List<Map<String, Object?>> env = const []})
    : app = app ?? testApp(mode: AppModes.chat) {
    exporter = AppDslExporter(
      exportDsl: (id, {includeSecret = false}) async {
        exports.add((id: id, includeSecret: includeSecret));
        return 'yaml';
      },
      environmentVariables: (_) async => env,
      saveDsl: (name, _) async => saved.add(name),
    );
    actions = AppInfoActions(
      apps: apps,
      appDetail: () => noApp ? null : this.app,
      setAppDetail: setAppDetail.add,
      exporter: exporter,
      redirect: (path, {app}) => redirects.add(path),
      resetKey: 'app-1',
    );
  }

  AppInfo app;
  final bool noApp;
  final apps = _Apps();
  late final AppDslExporter exporter;
  late final AppInfoActions actions;
  final exports = <({String id, bool includeSecret})>[];
  final saved = <String>[];
  final setAppDetail = <AppInfo?>[];
  final redirects = <String>[];
}

const AppInfoPayload _edit = (
  name: 'Updated',
  iconType: 'emoji',
  icon: '🤖',
  iconBackground: '#fff',
  description: '',
  useIconAsAnswerIcon: false,
  maxActiveRequests: null,
);

const DuplicatePayload _copy = (name: 'Copy', iconType: 'emoji', icon: '🤖', iconBackground: '#fff');

/// The toasts need a host: an empty page.
Future<void> _host(WidgetTester t) => renderDetail(t, const SizedBox());

void main() {
  group('useAppInfoActions', () {
    group('Initial state', () {
      test('should return initial state correctly', () {
        final f = _Fixture();
        expect(f.actions.appDetail(), f.app);
        expect(f.actions.activeModal, isNull);
        expect(f.actions.secretEnvList, isEmpty);
      });
    });

    group('App-scoped state', () {
      test('should reset app-scoped state when resetKey changes', () {
        final f = _Fixture();
        f.actions.openModal(AppInfoModal.delete);
        expect(f.actions.activeModal, AppInfoModal.delete);
        f.actions.resetKey = 'app-2';
        expect(f.actions.activeModal, isNull);
        expect(f.actions.secretEnvList, isEmpty);
      });
    });

    group('Modal management', () {
      test('should open modal', () {
        final f = _Fixture()..actions.openModal(AppInfoModal.edit);
        expect(f.actions.activeModal, AppInfoModal.edit);
      });

      test('should close modal', () {
        final f = _Fixture()
          ..actions.openModal(AppInfoModal.delete)
          ..actions.closeModal();
        expect(f.actions.activeModal, isNull);
      });
    });

    group('onEdit', () {
      testWidgets('should update app info and close modal on success', (t) async {
        await _host(t);
        final f = _Fixture()..actions.openModal(AppInfoModal.edit);
        final updated = AppInfo(id: 'app-1', name: 'Updated', mode: 'chat');
        f.apps.updated = updated;
        await f.actions.onEdit(_edit);
        await t.pump();
        expect(f.apps.calls['update'], ['app-1', 'Updated', 'emoji', '🤖', '#fff']);
        expect(f.setAppDetail, [updated]);
        expect(f.actions.activeModal, isNull);
        expect(find.text('app.editDone'), findsOneWidget);
        await settle(t, 60);
      });

      testWidgets('should notify error on edit failure', (t) async {
        await _host(t);
        final f = _Fixture()..apps.failUpdate = Exception('fail');
        await f.actions.onEdit(_edit);
        await t.pump();
        expect(find.text('app.editFailed'), findsOneWidget);
        await settle(t, 60);
      });

      test('should not call updateAppInfo when appDetail is undefined', () async {
        final f = _Fixture(noApp: true);
        await f.actions.onEdit(_edit);
        expect(f.apps.calls['update'], isNull);
      });
    });

    group('onCopy', () {
      // dify-sf's copy always answers the new app (no pending DSL import): the completed case.
      testWidgets('should redirect only when the copy is completed (%s)', (t) async {
        await _host(t);
        final f = _Fixture();
        await f.actions.onCopy(_copy);
        await t.pump();
        expect(f.apps.calls['copy'], ['app-1', 'Copy', 'emoji', '🤖', '#fff']);
        expect(find.text('app.newApp.appCreated'), findsOneWidget);
        expect(f.redirects, ['/app/app-2/configuration']);
        await settle(t, 60);
      });

      testWidgets('should notify error on copy failure', (t) async {
        await _host(t);
        final f = _Fixture()..apps.failCopy = Exception('fail');
        await f.actions.onCopy(_copy);
        await t.pump();
        expect(find.text('app.newApp.appCreateFailed'), findsOneWidget);
        expect(f.redirects, isEmpty);
        await settle(t, 60);
      });
    });

    group('onCopy - early return', () {
      test('should not call copyApp when appDetail is undefined', () async {
        final f = _Fixture(noApp: true);
        await f.actions.onCopy(_copy);
        expect(f.apps.calls['copy'], isNull);
      });
    });

    group('onExport', () {
      testWidgets('should export the app DSL', (t) async {
        await _host(t);
        final f = _Fixture();
        await f.actions.onExport(false);
        expect(f.exports, [(id: 'app-1', includeSecret: false)]);
        expect(f.saved, ['Test App.yml']);
        await settle(t, 60);
      });
    });

    group('onExport - early return', () {
      test('should not export when appDetail is undefined', () async {
        final f = _Fixture(noApp: true);
        await f.actions.onExport();
        expect(f.exports, isEmpty);
      });
    });

    group('exportCheck', () {
      testWidgets('should call onExport directly for non-workflow modes', (t) async {
        await _host(t);
        final f = _Fixture();
        await f.actions.exportCheck();
        expect(f.exports, hasLength(1));
        await settle(t, 60);
      });

      test('should open export warning modal for workflow mode', () async {
        final f = _Fixture(app: testApp(mode: AppModes.workflow));
        await f.actions.exportCheck();
        expect(f.actions.activeModal, AppInfoModal.exportWarning);
      });

      test('should open export warning modal for advanced_chat mode', () async {
        final f = _Fixture(app: testApp(mode: AppModes.advancedChat));
        await f.actions.exportCheck();
        expect(f.actions.activeModal, AppInfoModal.exportWarning);
      });
    });

    group('exportCheck - early return', () {
      test('should not do anything when appDetail is undefined', () async {
        final f = _Fixture(noApp: true);
        await f.actions.exportCheck();
        expect(f.exports, isEmpty);
        expect(f.actions.activeModal, isNull);
      });
    });

    group('handleConfirmExport', () {
      testWidgets('should export directly when no secret env variables', (t) async {
        await _host(t);
        final f = _Fixture(app: testApp(mode: AppModes.workflow))..actions.openModal(AppInfoModal.exportWarning);
        await f.actions.handleConfirmExport();
        expect(f.exports, [(id: 'app-1', includeSecret: false)]);
        expect(f.actions.activeModal, isNull);
        await settle(t, 60);
      });

      test('should set secret env list when secret variables exist', () async {
        const secretVars = [
          {'value_type': 'secret', 'name': 'API_KEY', 'value': 'secret'},
        ];
        final f = _Fixture(
          app: testApp(mode: AppModes.workflow),
          env: secretVars,
        );
        await f.actions.handleConfirmExport();
        expect(f.actions.secretEnvList, secretVars);
        expect(f.exports, isEmpty);
      });
    });

    group('handleConfirmExport - early return', () {
      test('should not do anything when appDetail is undefined', () async {
        final f = _Fixture(noApp: true);
        await f.actions.handleConfirmExport();
        expect(f.exports, isEmpty);
      });
    });

    group('onConfirmDelete', () {
      testWidgets('should delete app and redirect on success', (t) async {
        await _host(t);
        final f = _Fixture();
        await f.actions.onConfirmDelete();
        await t.pump();
        expect(f.apps.calls['delete'], ['app-1']);
        expect(find.text('app.appDeleted'), findsOneWidget);
        expect(f.redirects, ['/apps']);
        expect(f.setAppDetail, [null]);
        await settle(t, 60);
      });

      test('should not delete when appDetail is undefined', () async {
        final f = _Fixture(noApp: true);
        await f.actions.onConfirmDelete();
        expect(f.apps.calls['delete'], isNull);
      });

      testWidgets('should notify error on delete failure', (t) async {
        await _host(t);
        final f = _Fixture()..apps.failDelete = TransportException('cannot delete', statusCode: 403);
        await f.actions.onConfirmDelete();
        await t.pump();
        expect(find.textContaining('app.appDeleteFailed'), findsOneWidget);
        expect(f.redirects, isEmpty);
        await settle(t, 60);
      });
    });
  });
}
