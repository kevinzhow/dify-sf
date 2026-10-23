// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-available-var-list.spec.ts
//
// useNodesAvailableVarList is nodesAvailableVarList (use_checklist.dart, its one caller), over the real graph
// helpers (Dify mocks getBeforeNodesInSameBranchIncludeParent and getNodeAvailableVars).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart' show node;

void main() {
  group('useNodesAvailableVarList', () {
    test('builds availability per node, carrying loop nodes and parent iteration context', () {
      final doc = Document(
        nodes: [
          node('start', type: 'start', config: const {'variables': VList([])}),
          node('loop-1', type: 'loop', title: 'Loop'),
          node('child-1', type: 'llm', title: 'Writer', parent: 'loop-1'),
          node(
            'iter-1',
            type: 'iteration',
            title: 'Iteration',
            config: const {
              'iterator_selector': VList([VString('start'), VString('items')]),
            },
          ),
          node('iter-child', type: 'llm', parent: 'iter-1'),
        ],
        edges: const [
          Edge(id: 'e1', source: 'start', sourceHandle: 'source', target: 'loop-1', targetHandle: 'target'),
          Edge(id: 'e2', source: 'loop-1', sourceHandle: 'source', target: 'iter-1', targetHandle: 'target'),
        ],
      );
      final g = difyGraphOf(doc);
      DifyFlowNode n(String id) => g.nodes.firstWhere((x) => x.id == id);
      final map = nodesAvailableVarList(
        [n('loop-1'), n('child-1'), n('iter-child')],
        g.nodes,
        g.edges,
        hideEnv: true,
        hideChatVar: true,
      );

      // The loop offers what comes before it and its own variables.
      expect([for (final x in map['loop-1']!.availableNodes) x.id], ['start', 'loop-1']);
      // A child sees the nodes before its container and the container.
      expect([for (final x in map['child-1']!.availableNodes) x.id], ['start', 'loop-1']);
      // In an iteration, the container's item and index come first.
      final iterVars = map['iter-child']!.availableVars;
      expect(iterVars.first.nodeId, 'iter-1');
      expect([for (final v in iterVars.first.vars) v.variable], containsAll(['item', 'index']));
      // hideEnv: no environment group.
      expect(iterVars.where((v) => v.nodeId == 'env'), isEmpty);
    });

    test('keeps system variables outside snippet canvases', () {
      final doc = Document(
        nodes: [
          node('start', type: 'start', config: const {'variables': VList([])}),
          node('node-a', type: 'llm'),
        ],
        edges: const [
          Edge(id: 'e1', source: 'start', sourceHandle: 'source', target: 'node-a', targetHandle: 'target'),
        ],
      );
      final g = difyGraphOf(doc);
      final vars = nodesAvailableVarList([g.nodes.last], g.nodes, g.edges)['node-a']!.availableVars;
      final system = [
        for (final group in vars)
          for (final v in group.vars)
            if (v.variable.startsWith('sys.')) v.variable,
      ];
      expect(system, isNotEmpty);
    });
  });
}
