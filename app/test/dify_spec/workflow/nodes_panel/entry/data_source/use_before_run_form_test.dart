// dify-spec: web/app/components/workflow/nodes/data-source/hooks/__tests__/use-before-run-form.spec.tsx
//
// useBeforeRunForm as DataSourceBeforeRun: the data source store, hooks and services are fakes recording calls.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'before_run_harness.dart';

void main() {
  group('data-source/hooks/use-before-run-form', () {
    test('derives the run button disabled state from the selected datasource payload', () {
      final f = FakeRun();
      expect(f.hook().startRunBtnDisabled, isTrue);

      f.store.localFileList = [localFile];
      expect(f.hook().startRunBtnDisabled, isFalse);

      f.store.selectedFileIds = [];
      expect(f.hook(payload: createData({'provider_type': DatasourceType.onlineDrive})).startRunBtnDisabled, isTrue);
    });

    test('syncs the draft, runs the datasource, and appends inspect vars on success', () async {
      final f = FakeRun()
        ..store.localFileList = [localFile]
        ..settleWith = {'status': NodeRunningStatus.succeeded};

      f.hook().handleRunWithSyncDraft();
      await f.flush();

      expect(f.runAfterSingleRun, [true]);
      expect(f.nodeDataUpdates.first['id'], 'data-source-node');
      expect((f.nodeDataUpdates.first['data']! as Map)['_singleRunningStatus'], NodeRunningStatus.running);
      expect(f.runs.single, {
        'pipeline_id': 'flow-id',
        'start_node_id': 'data-source-node',
        'start_node_title': 'Datasource',
        'datasource_type': DatasourceType.localFile,
        'datasource_info': {
          'related_id': 'file-1',
          'name': 'doc.pdf',
          'type': 'document',
          'size': 12,
          'extension': 'pdf',
          'mime_type': 'application/pdf',
          'url': '',
          'transfer_method': 'local_file',
        },
      });
      expect(f.inspectFetches.single, ['ragPipeline', 'flow-id', 'data-source-node']);
      expect(f.appended.single, [
        'data-source-node',
        [
          {'name': 'metadata'},
        ],
        [
          {
            'id': 'data-source-node',
            'data': {'title': 'Datasource'},
          },
        ],
      ]);
      expect(f.successes, 1);
      final last = f.nodeDataUpdates.last['data']! as Map;
      expect(last['_isSingleRun'], isFalse);
      expect(last['_singleRunningStatus'], NodeRunningStatus.succeeded);
    });

    test('marks the last run invalid and updates the node to failed when the single run errors', () async {
      final f = FakeRun()
        ..store.selectedFileIds = ['drive-file-1']
        ..store.onlineDriveFileList = [
          {'id': 'drive-file-1', 'type': 'file'},
        ]
        ..fail = true;

      f.hook(payload: createData({'provider_type': DatasourceType.onlineDrive})).handleRunWithSyncDraft();
      await f.flush();

      expect(f.invalidated, 1);
      expect((f.runs.single['datasource_info']! as Map)['bucket'], 'drive-bucket');
      final last = f.nodeDataUpdates.last['data']! as Map;
      expect(last['_isSingleRun'], isFalse);
      expect(last['_singleRunningStatus'], NodeRunningStatus.failed);
    });
  });
}
