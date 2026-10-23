// dify-spec: web/app/components/workflow/nodes/data-source/hooks/__tests__/use-before-run-form.branches.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'before_run_harness.dart';

void main() {
  group('data-source/hooks/use-before-run-form branches', () {
    test('derives disabled states for online documents and website crawl sources', () {
      final f = FakeRun();
      final onlineDocument = createData({'provider_type': DatasourceType.onlineDocument});
      final websiteCrawl = createData({'provider_type': DatasourceType.websiteCrawl});
      expect(f.hook(payload: onlineDocument).startRunBtnDisabled, isTrue);

      f.store.onlineDocuments = [
        {'workspace_id': 'workspace-1', 'id': 'doc-1', 'title': 'Document'},
      ];
      expect(f.hook(payload: onlineDocument).startRunBtnDisabled, isFalse);

      expect(f.hook(payload: websiteCrawl).startRunBtnDisabled, isTrue);

      f.store.websitePages = [
        {'url': 'https://example.com'},
      ];
      expect(f.hook(payload: websiteCrawl).startRunBtnDisabled, isFalse);
    });

    test('returns the settled run result directly when chained single-run execution should stop', () async {
      final f = FakeRun()
        ..store.localFileList = [localFile]
        ..settleWith = {'status': NodeRunningStatus.succeeded};

      f
          .hook(
            isRunAfterSingleRun: true,
            payload: createData({'_singleRunningStatus': NodeRunningStatus.running}),
          )
          .handleRunWithSyncDraft();
      await f.flush();

      expect(f.runResults, [
        {'status': NodeRunningStatus.succeeded},
      ]);
      expect(f.inspectFetches, isEmpty);
      expect(f.successes, 0);
    });

    test('builds online document datasource info before running', () async {
      final f = FakeRun()
        ..store.onlineDocuments = [
          {'workspace_id': 'workspace-1', 'id': 'doc-1', 'title': 'Document', 'url': 'https://example.com/doc'},
        ]
        ..settleWith = {'status': NodeRunningStatus.succeeded};

      f.hook(payload: createData({'provider_type': DatasourceType.onlineDocument})).handleRunWithSyncDraft();
      await f.flush();

      expect(f.runs.single['datasource_type'], DatasourceType.onlineDocument);
      expect(f.runs.single['datasource_info'], {
        'workspace_id': 'workspace-1',
        'page': {'id': 'doc-1', 'title': 'Document', 'url': 'https://example.com/doc'},
        'credential_id': 'credential-1',
      });
    });

    test('builds website crawl datasource info and skips the failure update while paused', () async {
      final f = FakeRun()
        ..store.websitePages = [
          {'url': 'https://example.com', 'title': 'Example'},
        ]
        ..fail = true;

      f
          .hook(isPaused: true, payload: createData({'provider_type': DatasourceType.websiteCrawl}))
          .handleRunWithSyncDraft();
      await f.flush();

      expect(f.runs.single['datasource_type'], DatasourceType.websiteCrawl);
      expect(f.runs.single['datasource_info'], {
        'url': 'https://example.com',
        'title': 'Example',
        'credential_id': 'credential-1',
      });
      expect(f.invalidated, 1);
      expect(
        f.nodeDataUpdates.any((u) => (u['data']! as Map)['_singleRunningStatus'] == NodeRunningStatus.failed),
        isFalse,
      );
    });
  });
}
