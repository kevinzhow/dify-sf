// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions-without-sync.spec.ts
// dify-spec: web/app/components/workflow/hooks/__tests__/use-edges-interactions-without-sync.spec.ts
//
// The handlers are WorkflowRunEvents'; the nodes' and edges' run fields live in the store's run view state.
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run_events/run_event_harness.dart';

RunEventHarness _nodes() => RunEventHarness(
  nodes: [
    createNode('n1', data: {'_runningStatus': NodeRunningStatus.running, '_waitingRun': true}),
    createNode('n2', x: 100, data: {'_runningStatus': NodeRunningStatus.succeeded, '_waitingRun': false}),
    createNode('n3', x: 200, data: {'_runningStatus': NodeRunningStatus.failed, '_waitingRun': true}),
  ],
  edges: const [],
);

List<TestEdge> _edges() => [
  createEdge(
    'e1',
    'a',
    'b',
    data: {
      '_sourceRunningStatus': NodeRunningStatus.running,
      '_targetRunningStatus': NodeRunningStatus.running,
      '_waitingRun': true,
    },
  ),
  createEdge('e2', 'b', 'c', data: {'_sourceRunningStatus': NodeRunningStatus.succeeded, '_waitingRun': false}),
];

void main() {
  group('useNodesInteractionsWithoutSync', () {
    test('clears _runningStatus and _waitingRun on all nodes', () {
      final h = _nodes();
      addTearDown(h.dispose);
      h.events.handleNodeCancelRunningStatus();
      for (final id in ['n1', 'n2', 'n3']) {
        expect(h.node(id)['_runningStatus'], isNull);
        expect(h.node(id)['_waitingRun'], false);
      }
    });

    test('clears _runningStatus only for Succeeded nodes', () {
      final h = _nodes();
      addTearDown(h.dispose);
      h.events.handleCancelAllNodeSuccessStatus();
      expect(h.node('n1')['_runningStatus'], NodeRunningStatus.running);
      expect(h.node('n2')['_runningStatus'], isNull);
      expect(h.node('n3')['_runningStatus'], NodeRunningStatus.failed);
    });

    test('does not modify _waitingRun when clearing all success status', () {
      final h = _nodes();
      addTearDown(h.dispose);
      h.events.handleCancelAllNodeSuccessStatus();
      expect(h.node('n1')['_waitingRun'], true);
      expect(h.node('n3')['_waitingRun'], true);
    });

    test('clears _runningStatus and _waitingRun for the specified succeeded node', () {
      final h = _nodes();
      addTearDown(h.dispose);
      h.events.handleCancelNodeSuccessStatus('n2');
      expect(h.node('n2')['_runningStatus'], isNull);
      expect(h.node('n2')['_waitingRun'], false);
    });

    test('does not modify nodes that are not succeeded', () {
      final h = _nodes();
      addTearDown(h.dispose);
      h.events.handleCancelNodeSuccessStatus('n1');
      expect(h.node('n1')['_runningStatus'], NodeRunningStatus.running);
      expect(h.node('n1')['_waitingRun'], true);
    });

    test('does not modify other nodes', () {
      final h = _nodes();
      addTearDown(h.dispose);
      h.events.handleCancelNodeSuccessStatus('n2');
      expect(h.node('n1')['_runningStatus'], NodeRunningStatus.running);
    });
  });

  group('useEdgesInteractionsWithoutSync', () {
    test('clears running status and waitingRun on all edges', () {
      final h = RunEventHarness(nodes: [createNode('a'), createNode('b'), createNode('c')], edges: _edges());
      addTearDown(h.dispose);
      h.events.handleEdgeCancelRunningStatus();
      for (final id in ['e1', 'e2']) {
        expect(h.edge(id)['_sourceRunningStatus'], isNull);
        expect(h.edge(id)['_targetRunningStatus'], isNull);
        expect(h.edge(id)['_waitingRun'], false);
      }
    });

    test('does not mutate the original edges array', () {
      final edges = _edges();
      final original = {...edges[0].data};
      final h = RunEventHarness(nodes: [createNode('a'), createNode('b'), createNode('c')], edges: edges);
      addTearDown(h.dispose);
      final before = h.store.edgeRunData.value;
      h.events.handleEdgeCancelRunningStatus();
      expect(edges[0].data, original);
      // The store gets a new map; the one read before is unchanged.
      expect(before['e1']!['_sourceRunningStatus'], NodeRunningStatus.running);
    });
  });
}
