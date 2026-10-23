// dify-spec: web/app/components/app-sidebar/app-info/__tests__/app-info-modals.spec.tsx
//
// The dialogs are opened by AppInfoModalsHost when the actions ask for one (Flutter dialogs are routes, not JSX);
// the actions' calls are recorded through the controller's API and exporter.
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_info_actions.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart';
import 'package:dify_sf_app/src/studio/export_app_dsl.dart';
import 'package:dify_sf_app/src/workflow_editor/dsl/dsl_export_confirm_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/dsl/update_dsl_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

class _Fixture {
  _Fixture({Future<String> Function()? export}) {
    final app = apps.seed(name: 'Test App', mode: AppModes.workflow);
    this.app = app;
    exporter = AppDslExporter(
      exportDsl: (id, {includeSecret = false}) {
        exports.add(includeSecret);
        return export?.call() ?? Future.value('yaml');
      },
      environmentVariables: (_) async => const [],
      saveDsl: (_, _) async {},
    );
    actions = AppInfoActions(
      apps: apps,
      appDetail: () => this.app,
      setAppDetail: (_) {},
      exporter: exporter,
      redirect: (path, {app}) => redirects.add(path),
    );
  }

  final apps = FakeAppsApi();
  late final AppInfo app;
  late final AppDslExporter exporter;
  late final AppInfoActions actions;
  final exports = <bool>[];
  final redirects = <String>[];
}

Future<_Fixture> _render(WidgetTester t, {Future<String> Function()? export}) async {
  final f = _Fixture(export: export);
  await renderDetail(
    t,
    AppInfoModalsHost(
      actions: f.actions,
      app: f.app,
      importDsl: (yaml, {confirm = false}) async =>
          const ReplaceResult(head: 1, ops: 0, nodes: 0, edges: 0, nextCseq: 1),
    ),
  );
  return f;
}

/// UpdateDslModal's fixed-width button row fits short labels, not Dify's `<ns>.<key>` test strings in the one-em
/// test font: these cases show each key's last segment.
class _ShortTranslator implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => key.split('.').last;
}

void _shortLabels() => DifyI18n.current = _ShortTranslator();

Future<void> _open(WidgetTester t, _Fixture f, AppInfoModal modal) async {
  f.actions.openModal(modal);
  await settle(t);
}

const _secret = [
  {'id': 'env-1', 'key': 'SECRET', 'value': '', 'value_type': 'secret', 'name': 'Secret'},
];

void main() {
  group('AppInfoModals', () {
    testWidgets('should render nothing when activeModal is null', (t) async {
      await _render(t);
      expect(find.text('app.deleteAppConfirmTitle'), findsNothing);
      expect(find.byType(EditAppModal), findsNothing);
    });

    testWidgets('should render CreateAppModal in edit mode when activeModal is edit', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.edit);
      expect(t.widget<EditAppModal>(find.byType(EditAppModal)).isEditModal, isTrue);
    });

    testWidgets('should render DuplicateAppModal when activeModal is duplicate', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.duplicate);
      expect(find.byType(DuplicateAppModal), findsOneWidget);
    });

    testWidgets('should render delete alert dialog when activeModal is delete', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.delete);
      expect(find.text('app.deleteAppConfirmTitle'), findsOneWidget);
      expect(find.byType(EditableText), findsOneWidget);
    });

    testWidgets('should name the delete confirmation input with its visible label', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.delete);
      expect(find.bySemanticsLabel(RegExp(r'app\.deleteAppConfirmInputLabel')), findsWidgets);
    });

    testWidgets('should render UpdateDSLModal when activeModal is importDSL', (t) async {
      final f = await _render(t);
      _shortLabels();
      await _open(t, f, AppInfoModal.importDsl);
      expect(find.byType(UpdateDslModal), findsOneWidget);
    });

    testWidgets('should render export warning alert dialog when activeModal is exportWarning', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.exportWarning);
      expect(find.text('workflow.sidebar.exportWarning'), findsOneWidget);
    });

    testWidgets('should render DSLExportConfirmModal when secretEnvList is not empty', (t) async {
      final f = await _render(t);
      f.actions.setSecretEnvList(_secret);
      await settle(t);
      expect(find.byType(DslExportConfirmContent), findsOneWidget);
    });

    testWidgets('should not render DSLExportConfirmModal when secretEnvList is empty', (t) async {
      await _render(t);
      expect(find.byType(DslExportConfirmContent), findsNothing);
    });

    testWidgets('should call closeModal when cancel on delete modal', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.delete);
      await t.tap(find.byKey(const ValueKey('delete-app-cancel')));
      await settle(t);
      expect(f.actions.activeModal, isNull);
      expect(find.text('app.deleteAppConfirmTitle'), findsNothing);
    });

    testWidgets('should clear the delete confirmation input when delete modal is cancelled', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.delete);
      await t.enterText(find.byType(EditableText), 'wrong-name');
      await t.tap(find.byKey(const ValueKey('delete-app-cancel')));
      await settle(t);
      expect(f.actions.activeModal, isNull);
      await _open(t, f, AppInfoModal.delete);
      expect(t.widget<EditableText>(find.byType(EditableText)).controller.text, '');
    });

    testWidgets('should not confirm delete when the form is submitted with unmatched input', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.delete);
      await t.enterText(find.byType(EditableText), 'wrong-name');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await settle(t);
      expect(f.redirects, isEmpty);
      expect(await f.apps.get(f.app.id), isNotNull, reason: 'not deleted');
    });

    testWidgets('should call onConfirmDelete when confirm on delete modal', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.delete);
      await t.enterText(find.byType(EditableText), 'Test App');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('delete-app-confirm')));
      await settle(t, 60);
      expect(f.redirects, ['/apps']);
      expect(f.actions.activeModal, isNull);
    });

    testWidgets('should call handleConfirmExport when confirm on export warning', (t) async {
      final f = await _render(t);
      await _open(t, f, AppInfoModal.exportWarning);
      await t.tap(find.byKey(const ValueKey('export-warning-confirm')));
      await settle(t, 60);
      expect(f.exports, [false], reason: 'exportWorkflowAppDsl without secrets downloads at once');
      expect(find.text('workflow.sidebar.exportWarning'), findsNothing);
    });

    testWidgets('should show the export warning confirmation as pending during export', (t) async {
      final pending = Completer<String>();
      final f = await _render(t, export: () => pending.future);
      await _open(t, f, AppInfoModal.exportWarning);
      await t.tap(find.byKey(const ValueKey('export-warning-confirm')));
      await t.pump();
      expect(find.text('common.operation.exporting'), findsOneWidget);
      pending.complete('yaml');
      await settle(t, 60);
    });

    testWidgets('should call exportCheck when backup on importDSL modal', (t) async {
      final f = await _render(t);
      _shortLabels();
      await _open(t, f, AppInfoModal.importDsl);
      await t.tap(find.text('backupCurrentDraft'));
      await settle(t);
      // exportCheck on a workflow app: the export warning.
      expect(f.actions.activeModal, AppInfoModal.exportWarning);
    });

    testWidgets('should call setSecretEnvList with empty array when closing DSLExportConfirmModal', (t) async {
      final f = await _render(t);
      f.actions.setSecretEnvList(_secret);
      await settle(t);
      await t.tap(find.byKey(const ValueKey('dsl-export-cancel')));
      await settle(t);
      expect(f.actions.secretEnvList, isEmpty);
    });
  });
}
