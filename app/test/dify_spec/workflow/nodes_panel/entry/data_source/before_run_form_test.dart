// dify-spec: web/app/components/workflow/nodes/data-source/__tests__/before-run-form.spec.tsx
//
// The preparation widgets are the host's (Dify's mocks become a builder); the hook is DataSourceBeforeRun over fakes.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../dify_test_i18n.dart';
import 'before_run_harness.dart';

Widget _preparation(BuildContext context, String type, DataSourcePreparationArgs args) => switch (type) {
  DatasourceType.localFile => Text(args.allowedExtensions.join(',')),
  DatasourceType.onlineDocument => TextButton(
    onPressed: () => args.onCredentialChange('credential-doc'),
    child: const Text('online-documents'),
  ),
  DatasourceType.websiteCrawl => TextButton(
    onPressed: () => args.onCredentialChange('credential-site'),
    child: const Text('website-crawl'),
  ),
  _ => TextButton(onPressed: () => args.onCredentialChange('credential-drive'), child: const Text('online-drive')),
};

Future<void> _render(WidgetTester t, DataSourceBeforeRun beforeRun, {VoidCallback? onCancel}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: SizedBox(
          width: 420,
          child: DataSourceBeforeRunForm(beforeRun: beforeRun, onCancel: onCancel ?? () {}, preparation: _preparation),
        ),
      ),
    ),
  );
  await t.pump();
}

DifyButton _startRun(WidgetTester t) => t.widget<DifyButton>(
  find.ancestor(of: find.text('workflow.singleRun.startRun'), matching: find.byType(DifyButton)),
);

void main() {
  setUp(useDifyTestTranslator);

  group('data-source/before-run-form', () {
    testWidgets('renders the local-file preparation form and triggers run/cancel actions', (t) async {
      final f = FakeRun()..store.localFileList = [localFile];
      var cancels = 0;
      await _render(
        t,
        f.hook(
          payload: createData({
            'fileExtensions': ['pdf', 'md'],
          }),
        ),
        onCancel: () => cancels++,
      );

      expect(find.text('Datasource'), findsOneWidget);
      expect(find.text('pdf,md'), findsOneWidget);

      await t.tap(find.text('common.operation.cancel'));
      await t.tap(find.text('workflow.singleRun.startRun'));
      await t.pump();

      expect(cancels, 1);
      expect(f.syncs, [1]);
    });

    testWidgets('clears stale online document data before switching credentials', (t) async {
      final f = FakeRun()
        ..store.onlineDocuments = [
          {'workspace_id': 'w', 'id': 'doc-1'},
        ];
      await _render(t, f.hook(payload: createData({'provider_type': DatasourceType.onlineDocument})));

      await t.tap(find.text('online-documents'));
      await t.pump();

      expect(f.store.onlineDocuments, isEmpty);
      expect(f.store.currentCredentialId, 'credential-doc');
      expect(_startRun(t).disabled, isTrue);
    });

    testWidgets('clears website crawl data before switching credentials', (t) async {
      final f = FakeRun()
        ..store.websitePages = [
          {'url': 'https://example.com'},
        ];
      await _render(t, f.hook(payload: createData({'provider_type': DatasourceType.websiteCrawl})));

      await t.tap(find.text('website-crawl'));
      await t.pump();

      expect(f.store.websitePages, isEmpty);
      expect(f.store.currentCredentialId, 'credential-site');
    });

    testWidgets('clears online drive data before switching credentials', (t) async {
      final f = FakeRun()
        ..store.selectedFileIds = ['drive-file-1']
        ..store.onlineDriveFileList = [
          {'id': 'drive-file-1', 'type': 'file'},
        ];
      await _render(t, f.hook(payload: createData({'provider_type': DatasourceType.onlineDrive})));

      await t.tap(find.text('online-drive'));
      await t.pump();

      expect(f.store.selectedFileIds, isEmpty);
      expect(f.store.onlineDriveFileList, isEmpty);
      expect(f.store.bucket, '');
      expect(f.store.currentCredentialId, 'credential-drive');
    });
  });
}
