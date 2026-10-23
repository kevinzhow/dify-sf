// dify-spec: web/app/components/workflow/utils/__tests__/node.spec.ts
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_defaults.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/workflow_actions.dart' show genNewNodeTitleFromOld;
import 'package:dify_sf_app/src/workflow_editor/node_insertion/node_insertion.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart' show hasRetryNode;
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _at(num x, num y) => {
  'position': {'x': x, 'y': y},
};

Map<String, Object?> _data(Map<String, Object?> node) => (node['data']! as Map).cast<String, Object?>();

void main() {
  group('nested workflow node layering', () {
    test('should keep nested elements above React Flow selected nodes', () {
      expect(nestedElementZIndex, 1001);
      expect(nestedElementZIndex, greaterThan(1000));
    });
  });

  group('getNodeCatalogType', () {
    test('should use Agent V2 catalog type for graph agent nodes with the Agent V2 discriminator', () {
      expect(
        getNodeCatalogType({
          'title': 'Agent',
          'desc': '',
          'type': 'agent',
          'agent_node_kind': 'dify_agent',
          'version': '2',
        }),
        'agent-v2',
      );
    });

    test('should keep the graph node type for regular nodes and legacy Agent nodes', () {
      expect(getNodeCatalogType({'title': 'Code', 'desc': '', 'type': 'code'}), 'code');
      expect(getNodeCatalogType({'title': 'Agent', 'desc': '', 'type': 'agent'}), 'agent');
    });
  });

  group('generateNewNode', () {
    test('should create a basic node with default CUSTOM_NODE type', () {
      final r = generateNewNode(data: {'title': 'Test', 'desc': '', 'type': 'code'}, position: (x: 100, y: 200));
      expect(r.node['type'], 'custom');
      expect(r.node['position'], {'x': 100, 'y': 200});
      expect(_data(r.node)['title'], 'Test');
      expect(r.node['id'], isNotNull);
    });

    test('should use provided id when given', () {
      final r = generateNewNode(
        id: 'custom-id',
        data: {'title': 'Test', 'desc': '', 'type': 'code'},
        position: (x: 0, y: 0),
      );
      expect(r.node['id'], 'custom-id');
    });

    test('should use the default layer for iteration nodes', () {
      final r = generateNewNode(data: {'title': 'Iter', 'desc': '', 'type': 'iteration'}, position: (x: 0, y: 0));
      expect(r.node['zIndex'], 0);
    });

    test('should use the default layer for loop nodes', () {
      final r = generateNewNode(data: {'title': 'Loop', 'desc': '', 'type': 'loop'}, position: (x: 0, y: 0));
      expect(r.node['zIndex'], 0);
    });

    test('should create an iteration start node for iteration type', () {
      final r = generateNewNode(
        id: 'iter-1',
        data: {'title': 'Iter', 'desc': '', 'type': 'iteration'},
        position: (x: 0, y: 0),
      );
      expect(r.start, isNotNull);
      expect(r.start!['id'], 'iter-1start');
      expect(_data(r.start!)['type'], 'iteration-start');
      expect(_data(r.node)['start_node_id'], 'iter-1start');
      expect(_data(r.node)['_children'], [
        {'nodeId': 'iter-1start', 'nodeType': 'iteration-start'},
      ]);
    });

    test('should create a loop start node for loop type', () {
      final r = generateNewNode(
        id: 'loop-1',
        data: {'title': 'Loop', 'desc': '', 'type': 'loop'},
        position: (x: 0, y: 0),
      );
      expect(r.start, isNotNull);
      expect(r.start!['id'], 'loop-1start');
      expect(_data(r.start!)['type'], 'loop-start');
      expect(_data(r.node)['start_node_id'], 'loop-1start');
      expect(_data(r.node)['_children'], [
        {'nodeId': 'loop-1start', 'nodeType': 'loop-start'},
      ]);
    });

    test('should not create child start nodes for regular types', () {
      final r = generateNewNode(data: {'title': 'Code', 'desc': '', 'type': 'code'}, position: (x: 0, y: 0));
      expect(r.start, isNull);
    });
  });

  group('getIterationStartNode', () {
    test('should create a properly configured iteration start node', () {
      final node = iterationStartNode('parent-iter');
      expect(node['id'], 'parent-iterstart');
      expect(node['type'], 'custom-iteration-start');
      expect(_data(node)['type'], 'iteration-start');
      expect(_data(node)['isInIteration'], true);
      expect(node['parentId'], 'parent-iter');
      expect(node['selectable'], false);
      expect(node['draggable'], false);
      expect(node['zIndex'], nestedElementZIndex);
      expect(node['position'], {'x': 24, 'y': 68});
    });
  });

  group('getLoopStartNode', () {
    test('should create a properly configured loop start node', () {
      final node = loopStartNode('parent-loop');
      expect(node['id'], 'parent-loopstart');
      expect(node['type'], 'custom-loop-start');
      expect(_data(node)['type'], 'loop-start');
      expect(_data(node)['isInLoop'], true);
      expect(node['parentId'], 'parent-loop');
      expect(node['selectable'], false);
      expect(node['draggable'], false);
      expect(node['zIndex'], nestedElementZIndex);
      expect(node['position'], {'x': 24, 'y': 68});
    });
  });

  group('genNewNodeTitleFromOld', () {
    test('should append (1) to a title without a counter', () {
      expect(genNewNodeTitleFromOld('LLM'), 'LLM (1)');
    });

    test('should increment existing counter', () {
      expect(genNewNodeTitleFromOld('LLM (1)'), 'LLM (2)');
      expect(genNewNodeTitleFromOld('LLM (99)'), 'LLM (100)');
    });

    test('should handle titles with spaces around counter', () {
      expect(genNewNodeTitleFromOld('My Node (3)'), 'My Node (4)');
    });

    test('should handle titles that happen to contain parentheses in the name', () {
      expect(genNewNodeTitleFromOld('Node (special) name'), 'Node (special) name (1)');
    });
  });

  group('getTopLeftNodePosition', () {
    test('should return the minimum x and y from nodes', () {
      expect(getTopLeftNodePosition([_at(100, 50), _at(20, 200), _at(50, 10)]), (x: 20, y: 10));
    });

    test('should handle a single node', () {
      expect(getTopLeftNodePosition([_at(42, 99)]), (x: 42, y: 99));
    });

    test('should handle negative positions', () {
      expect(getTopLeftNodePosition([_at(-10, -20), _at(5, -30)]), (x: -10, y: -30));
    });
  });

  group('getNestedNodePosition', () {
    test('should compute relative position of child to parent', () {
      expect(getNestedNodePosition(_at(150, 200), _at(100, 80)), (x: 50, y: 120));
    });
  });

  group('hasRetryNode', () {
    test('should return true for %s', () {
      for (final type in ['llm', 'tool', 'http-request', 'code']) {
        expect(hasRetryNode(type), isTrue, reason: type);
      }
    });

    test('should return false for %s', () {
      for (final type in ['start', 'end', 'if-else', 'iteration']) {
        expect(hasRetryNode(type), isFalse, reason: type);
      }
    });

    test('should return false when nodeType is undefined', () {
      expect(hasRetryNode(null), isFalse);
    });
  });

  group('getNodeCustomTypeByNodeDataType', () {
    test('should return CUSTOM_SIMPLE_NODE for LoopEnd', () {
      expect(getNodeCustomTypeByNodeDataType('loop-end'), 'custom-simple');
    });

    test('should return undefined for other types', () {
      expect(getNodeCustomTypeByNodeDataType('code'), isNull);
      expect(getNodeCustomTypeByNodeDataType('llm'), isNull);
    });
  });
}
