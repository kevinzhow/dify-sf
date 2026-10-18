/// use-workflow-run-event/__tests__/test-helpers.ts: a store, a graph and a viewport for the run event handlers.
/// Nodes' and edges' `data` run fields (`_runningStatus`, ...) live in the store's run view state.
library;

import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';

/// The fixtures' `createNode`: [data] holds the run fields.
typedef TestNode = ({String id, double x, double y, double width, double height, String? parentId, DifyJson data});

TestNode createNode(
  String id, {
  double x = 0,
  double y = 0,
  double width = 240,
  double height = 90,
  String? parentId,
  DifyJson data = const {},
}) => (id: id, x: x, y: y, width: width, height: height, parentId: parentId, data: data);

typedef TestEdge = ({String id, String source, String target, String sourceHandle, DifyJson data});

TestEdge createEdge(
  String id,
  String source,
  String target, {
  String sourceHandle = 'source',
  DifyJson data = const {},
}) => (id: id, source: source, target: target, sourceHandle: sourceHandle, data: data);

/// `createRunNodes` / `createRunEdges`.
List<TestNode> createRunNodes() => [
  createNode('n1', width: 200, height: 80, data: {'_waitingRun': false}),
];
List<TestEdge> createRunEdges() => [createEdge('e1', 'n0', 'n1')];

/// `createViewportNodes` / `createViewportEdges`.
List<TestNode> createViewportNodes() => [
  createNode('n0', width: 200, height: 80, data: {'_runningStatus': NodeRunningStatus.succeeded}),
  createNode('n1', x: 100, y: 50, width: 200, height: 80, data: {'_waitingRun': true}),
  createNode('n2', x: 400, y: 50, width: 200, height: 80, parentId: 'n1', data: {'_waitingRun': true}),
];
List<TestEdge> createViewportEdges() => [createEdge('e1', 'n0', 'n1')];

const containerParams = (clientWidth: 1200.0, clientHeight: 800.0);

/// React Flow's `transform` ([x, y, zoom]).
class FakeViewport implements RunViewport {
  List<double> transform = [0, 0, 1];
  @override
  double get zoom => transform[2];
  @override
  void setViewport(double x, double y, double zoom) => transform = [x, y, zoom];
}

/// `baseRunningData(overrides)`.
DifyJson baseRunningData([DifyJson overrides = const {}]) => {
  'task_id': 'task-1',
  'result': {'status': WorkflowRunningStatus.running},
  'tracing': <DifyJson>[],
  'resultText': '',
  'resultTabActive': false,
  ...jsonCopy(overrides),
};

/// `createNodeTracing`.
DifyJson createNodeTracing({String nodeId = 'node-1', String status = NodeRunningStatus.running}) => {
  'id': 'trace-$nodeId',
  'index': 0,
  'predecessor_node_id': '',
  'node_id': nodeId,
  'node_type': 'code',
  'title': 'Node',
  'inputs': null,
  'inputs_truncated': false,
  'process_data': null,
  'process_data_truncated': false,
  'outputs_truncated': false,
  'status': status,
  'elapsed_time': 0,
  'metadata': {'iterator_length': 0, 'iterator_index': 0, 'loop_length': 0, 'loop_index': 0},
  'created_at': 0,
  'created_by': {'id': 'user-1', 'name': 'Test', 'email': 'test@test.com'},
  'finished_at': 0,
};

/// `renderRunEventHook` / `renderViewportHook`: the handlers over [nodes] and [edges].
class RunEventHarness {
  RunEventHarness({List<TestNode>? nodes, List<TestEdge>? edges, DifyJson? workflowRunningData, int? iterTimes})
    : nodes = nodes ?? createRunNodes(),
      edges = edges ?? createRunEdges() {
    for (final n in this.nodes) {
      if (n.data.isNotEmpty) store.setNodeRunData(n.id, n.data);
    }
    for (final e in this.edges) {
      if (e.data.isNotEmpty) store.setEdgeRunData(e.id, e.data);
    }
    if (workflowRunningData != null) store.setWorkflowRunningData(workflowRunningData);
    if (iterTimes != null) store.setIterTimes(iterTimes);
  }

  final List<TestNode> nodes;
  final List<TestEdge> edges;
  final store = WorkflowStore();
  final viewport = FakeViewport();

  late final graph = StaticRunGraph(
    nodes: [
      for (final n in nodes)
        RunGraphNode(
          id: n.id,
          type: 'code',
          parentId: n.parentId,
          x: n.x,
          y: n.y,
          width: n.width,
          height: n.height,
        ),
    ],
    edges: [
      for (final e in edges) RunGraphEdge(id: e.id, source: e.source, target: e.target, sourceHandle: e.sourceHandle),
    ],
  );

  late final events = WorkflowRunEvents(store: store, graph: graph, viewport: viewport);

  DifyJson get state => store.workflowRunningData.value!;
  List<DifyJson> get tracing => tracingOf(state);

  /// `getNodeRuntimeState(node)`.
  DifyJson node(String id) => store.nodeRunDataOf(id);
  DifyJson edge(String id) => store.edgeRunDataOf(id);
  DifyJson get firstNode => node(nodes.first.id);
  DifyJson get firstEdge => edge(edges.first.id);

  void dispose() => store.dispose();
}
