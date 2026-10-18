// dify-spec: web/app/components/workflow/__tests__/update-dsl-modal.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/dsl/update_dsl_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';

const success = ReplaceResult(head: 12, ops: 5, nodes: 2, edges: 1, nextCseq: 6);
const file = (
  name: 'workflow.yml',
  content: 'app: {name: Test, mode: workflow}\nkind: app\nworkflow: {graph: {nodes: [], edges: []}}',
);
Future<void> open(WidgetTester t, {WorkflowImport? import, VoidCallback? backup, DslFile selected = file}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Stack(
          children: [
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showDifyDialog<void>(
                  context,
                  builder: (_) => UpdateDslModal(
                    appMode: 'workflow',
                    onImport: import ?? (yaml, {confirm = false}) async => success,
                    onBackup: backup,
                    pickFile: () async => selected,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
            const DifyToastHost(),
          ],
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Future<void> choose(WidgetTester t) async {
  await t.tap(find.byKey(const Key('choose-dsl-file')));
  await t.pumpAndSettle();
}

Future<void> submit(WidgetTester t) async {
  await t.tap(find.byKey(const Key('overwrite-import-dsl')));
  await t.pumpAndSettle();
}

void main() {
  setUp(() async {
    await useAppFonts();
    await DifyI18n.load('en-US');
  });
  group('UpdateDSLModal', () {
    testWidgets('should keep import disabled until a file is selected', (t) async {
      await open(t);
      expect(t.widget<DifyButton>(find.byKey(const Key('overwrite-import-dsl'))).disabled, isTrue);
      await choose(t);
      expect(t.widget<DifyButton>(find.byKey(const Key('overwrite-import-dsl'))).disabled, isFalse);
      expect(find.text(file.name), findsOneWidget);
    });
    testWidgets('should call backup handler from the warning area', (t) async {
      var backups = 0;
      await open(t, backup: () => backups++);
      await t.tap(find.text(DifyI18n.tr('workflow', 'common.backupCurrentDraft')));
      expect(backups, 1);
    });
    testWidgets('should call cancel handler when the import dialog requests close', (t) async {
      await open(t);
      await t.tap(find.text(DifyI18n.tr('app', 'newApp.Cancel')));
      await t.pumpAndSettle();
      expect(find.byType(UpdateDslModal), findsNothing);
    });
    testWidgets('should call cancel handler when the close button is clicked', (t) async {
      await open(t);
      await t.tap(find.byType(DifyIconButton));
      await t.pumpAndSettle();
      expect(find.byType(UpdateDslModal), findsNothing);
    });
    testWidgets('should import a valid file and emit workflow update payload', (t) async {
      String? imported;
      await open(
        t,
        import: (yaml, {confirm = false}) async {
          imported = yaml;
          return success;
        },
      );
      await choose(t);
      await submit(t);
      expect(imported, file.content);
      expect(find.byType(UpdateDslModal), findsNothing);
      expect(find.text(DifyI18n.tr('workflow', 'common.importSuccess')), findsOneWidget);
    });
    testWidgets('should show an error notification when import fails', (t) async {
      await open(
        t,
        import: (yaml, {confirm = false}) async => throw const TransportException('invalid YAML', statusCode: 400),
      );
      await choose(t);
      await submit(t);
      expect(find.text('invalid YAML'), findsOneWidget);
      expect(find.byType(UpdateDslModal), findsOneWidget);
    });
    testWidgets('should open the version warning modal for pending imports and confirm them', (t) async {
      final calls = <bool>[];
      await open(
        t,
        import: (yaml, {confirm = false}) async {
          calls.add(confirm);
          if (!confirm) {
            throw const DslVersionUnconfirmed('confirm version', importedVersion: '9.0', currentVersion: '0.3.1');
          }
          return const ReplaceResult(head: 12, ops: 5, nodes: 2, edges: 1, nextCseq: 6, status: 'pending');
        },
      );
      await choose(t);
      await submit(t);
      expect(find.byKey(const Key('confirm-dsl-version')), findsOneWidget);
      await t.tap(find.byKey(const Key('confirm-dsl-version')));
      await t.pumpAndSettle();
      expect(calls, [false, true]);
      expect(find.byType(UpdateDslModal), findsNothing);
      expect(find.text(DifyI18n.tr('workflow', 'common.importWarning')), findsOneWidget);
    });
    testWidgets('should open the pending modal after the timeout and allow dismissing it', (t) async {
      await open(
        t,
        import: (yaml, {confirm = false}) async =>
            throw const DslVersionUnconfirmed('confirm version', importedVersion: '9.0', currentVersion: '0.3.1'),
      );
      await choose(t);
      await submit(t);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('confirm-dsl-version')), findsOneWidget);
      await t.tap(find.byKey(const Key('cancel-dsl-version')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dsl-version')), findsNothing);
    });
    testWidgets('should close the pending modal when dialog requests close', (t) async {
      await open(
        t,
        import: (yaml, {confirm = false}) async =>
            throw const DslVersionUnconfirmed('confirm version', importedVersion: '9.0', currentVersion: '0.3.1'),
      );
      await choose(t);
      await submit(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('confirm-dsl-version')), findsNothing);
    });
    testWidgets('should show an error when confirming a pending import fails', (t) async {
      await open(
        t,
        import: (yaml, {confirm = false}) async {
          if (!confirm) {
            throw const DslVersionUnconfirmed('confirm version', importedVersion: '9.0', currentVersion: '0.3.1');
          }
          throw const TransportException('import rejected', statusCode: 409);
        },
      );
      await choose(t);
      await submit(t);
      await t.tap(find.byKey(const Key('confirm-dsl-version')));
      await t.pumpAndSettle();
      expect(find.text('import rejected'), findsOneWidget);
      expect(find.byType(UpdateDslModal), findsOneWidget);
    });
    testWidgets('should show an error when the selected file content is invalid for the current app mode', (t) async {
      var calls = 0;
      await open(
        t,
        selected: (name: 'bad.yml', content: 'workflow: {graph: {nodes: [{data: {type: answer}}]}}'),
        import: (yaml, {confirm = false}) async {
          calls++;
          return success;
        },
      );
      await choose(t);
      await submit(t);
      expect(calls, 0);
      expect(find.text(DifyI18n.tr('workflow', 'common.importFailure')), findsOneWidget);
    });
    testWidgets('should show an error notification when import throws', (t) async {
      await open(t, import: (yaml, {confirm = false}) async => throw StateError('offline'));
      await choose(t);
      await submit(t);
      expect(find.text(DifyI18n.tr('workflow', 'common.importFailure')), findsOneWidget);
      expect(find.byType(UpdateDslModal), findsOneWidget);
    });
  });
}
