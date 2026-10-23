import 'dart:async';

import '../../dify_spec/workflow/nodes_panel/core/harness.dart' show difyNodes;

import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat preview keeps successful cached nodes green until their inspect values are cleared', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start', data: {'type': 'start', 'variables': <Object?>[]}),
        RunGraphNode(
          id: 'template',
          type: 'template-transform',
          data: {'type': 'template-transform', 'template': 'Thanks'},
        ),
        RunGraphNode(id: 'answer', type: 'answer', data: {'type': 'answer', 'answer': '{{#template.output#}}'}),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'template'),
        RunGraphEdge(id: 'b', source: 'template', target: 'answer'),
      ],
    );
    final store = WorkflowStore();
    final canvas = CanvasController();
    final binding = RunCanvasBinding(store, canvas);
    final service = MockWorkflowRunService(
      graph: () => graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero),
    );
    final document = difyNodes([
      for (final n in graph.nodes)
        {
          'id': n.id,
          'type': 'custom',
          'data': n.data,
          'position': {'x': 0, 'y': 0},
        },
    ]);
    final crud = InspectVarsCrud(store: store, services: service.inspectServices, nodes: () => document);
    final run = WorkflowRunController(
      store: store,
      service: service,
      graph: graph,
      isChatMode: () => true,
      toast: (_, _) {},
    );
    final chat = DebugChatController(
      run: run,
      service: service,
      store: store,
      graph: graph,
      fetchInspectVars: () => unawaited(crud.fetchInspectVars()),
    );
    chat.handleSend({'query': 'Hello'});
    await pumpEventQueue(times: 200);
    expect(chat.isResponding, isFalse);
    expect(store.nodeRunDataOf('template')['_runningStatus'], isNull);
    expect(canvas.nodeRun.value['template']?.hasVarValue, isTrue);
    expect(canvas.nodeRun.value['template']?.status, 'succeeded');
    expect(canvas.nodeRun.value['answer']?.status, 'succeeded');
    await crud.deleteNodeInspectorVars('template');
    expect(canvas.nodeRun.value['template']?.status ?? 'idle', 'idle');
    expect(canvas.nodeRun.value['answer']?.status, 'succeeded');
    chat.dispose();
    run.dispose();
    crud.dispose();
    binding.dispose();
    canvas.dispose();
    store.dispose();
  });
}
