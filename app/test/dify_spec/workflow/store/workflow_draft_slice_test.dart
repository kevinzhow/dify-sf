// dify-spec: web/app/components/workflow/store/__tests__/workflow-draft-slice.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  group('Workflow Draft Slice', () {
    group('Initial State', () {
      test('should have empty default values', () {
        expect(store.backupDraft.value, isNull);
        expect(store.syncWorkflowDraftHash.value, '');
        expect(store.isSyncingWorkflowDraft.value, false);
        expect(store.isWorkflowDataLoaded.value, false);
        expect(store.nodes.value, isEmpty);
      });
    });

    group('setBackupDraft', () {
      test('should set and clear backup draft', () {
        const BackupDraft draft = (
          nodes: [],
          edges: [],
          viewport: (x: 0, y: 0, zoom: 1),
          features: null,
          environmentVariables: [],
        );
        store.setBackupDraft(draft);
        expect(store.backupDraft.value, draft);

        store.setBackupDraft(null);
        expect(store.backupDraft.value, isNull);
      });
    });

    group('setSyncWorkflowDraftHash', () {
      test('should update the hash', () {
        store.setSyncWorkflowDraftHash('abc123');
        expect(store.syncWorkflowDraftHash.value, 'abc123');
      });
    });

    group('setIsSyncingWorkflowDraft', () {
      test('should toggle syncing state', () {
        store.setIsSyncingWorkflowDraft(true);
        expect(store.isSyncingWorkflowDraft.value, true);
      });
    });

    group('setIsWorkflowDataLoaded', () {
      test('should toggle loaded state', () {
        store.setIsWorkflowDataLoaded(true);
        expect(store.isWorkflowDataLoaded.value, true);
      });
    });

    group('setNodes', () {
      test('should update nodes array', () {
        final nodes = <DifyJson>[];
        store.setNodes(nodes);
        expect(store.nodes.value, nodes);
      });
    });

    group('debouncedSyncWorkflowDraft', () {
      test('should be a callable function', () {
        expect(store.debouncedSyncWorkflowDraft.call, isA<void Function(void Function())>());
      });

      testWidgets('should debounce the sync call', (t) async {
        var calls = 0;

        store.debouncedSyncWorkflowDraft(() => calls++);
        expect(calls, 0);

        await t.pump(const Duration(milliseconds: 5000));
        expect(calls, 1);
      });

      testWidgets('should flush pending sync via flushPendingSync', (t) async {
        var calls = 0;

        store.debouncedSyncWorkflowDraft(() => calls++);
        expect(calls, 0);

        store.flushPendingSync();
        expect(calls, 1);
      });
    });
  });
}
