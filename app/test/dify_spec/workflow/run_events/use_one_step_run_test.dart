// dify-spec: web/app/components/workflow/nodes/_base/hooks/__tests__/use-one-step-run.spec.ts
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// `renderUseOneStepRun()`: an IF/ELSE node after the Start node (no variables), in a workflow.
SingleRunController renderUseOneStepRun() {
  const graph = StaticRunGraph(
    nodes: [
      RunGraphNode(id: 'start', type: 'start', title: 'Start', data: {'variables': <Object?>[]}),
      RunGraphNode(id: 'if-else-node', type: 'if-else', title: 'IF/ELSE', data: {'desc': ''}),
    ],
    edges: [RunGraphEdge(id: 'e', source: 'start', target: 'if-else-node')],
  );
  final store = WorkflowStore();
  final service = MockWorkflowRunService(graph: () => graph);
  return SingleRunController(
    nodeId: 'if-else-node',
    store: store,
    service: service,
    graph: graph,
    run: WorkflowRunController(store: store, service: service, graph: graph),
  );
}

void main() {
  group('useOneStepRun single-run input vars', () {
    test('uses value_type when the variable cannot be resolved from output vars', () {
      final inputs = renderUseOneStepRun().toVarInputs([
        {
          'variable': '#start.amount#',
          'value_selector': ['start', 'amount'],
          'value_type': 'number',
        },
      ]);
      expect(inputs, hasLength(1));
      expect(inputs.single, containsPair('variable', '#start.amount#'));
      expect(inputs.single, containsPair('type', 'number'));
    });

    test('resolves global system vars by full variable name', () {
      final inputs = renderUseOneStepRun().varSelectorsToVarInputs([
        ['sys', 'timestamp'],
      ]);
      expect(inputs, hasLength(1));
      expect(inputs.single, containsPair('variable', '#sys.timestamp#'));
      expect(inputs.single, containsPair('type', 'number'));
    });
  });
}
