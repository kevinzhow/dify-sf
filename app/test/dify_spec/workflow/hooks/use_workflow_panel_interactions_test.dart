// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-panel-interactions.spec.tsx
//
// useWorkflowInteractions().handleCancelDebugAndPreviewPanel is WorkflowRunController's (the move-mode cases are in
// operator/move_mode_test.dart).
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('useWorkflowInteractions', () {
    test('closes the debug panel and clears running state', () {
      final store = WorkflowStore()
        ..setShowDebugAndPreviewPanel(true)
        ..setWorkflowRunningData({'task_id': 'task-1'})
        ..setNodeRunData('n1', {'_runningStatus': NodeRunningStatus.running, '_waitingRun': true})
        ..setEdgeRunData('e1', {'_sourceRunningStatus': NodeRunningStatus.running, '_waitingRun': true});
      addTearDown(store.dispose);
      const graph = StaticRunGraph(
        nodes: [RunGraphNode(id: 'n1', type: 'code')],
        edges: [RunGraphEdge(id: 'e1', source: 'n0', target: 'n1')],
      );
      final run = WorkflowRunController(
        store: store,
        service: MockWorkflowRunService(graph: () => graph),
        graph: graph,
      );

      run.handleCancelDebugAndPreviewPanel();

      expect(store.showDebugAndPreviewPanel.value, isFalse);
      expect(store.workflowRunningData.value, isNull);
      // handleNodeCancelRunningStatus / handleEdgeCancelRunningStatus.
      expect(store.nodeRunDataOf('n1'), {'_waitingRun': false});
      expect(store.edgeRunDataOf('e1'), {'_waitingRun': false});
    });
  });
}
