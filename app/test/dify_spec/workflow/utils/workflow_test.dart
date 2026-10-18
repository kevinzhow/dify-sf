// dify-spec: web/app/components/workflow/utils/__tests__/workflow.spec.ts
//
// canRunBySingle, hasErrorHandleNode and getValidTreeNodes (the getNodesConnectedSourceOrTargetHandleIdsMap cases are
// in node_insertion/workflow_utils_test.dart).
import 'package:dify_sf_app/src/workflow_editor/context_menu/node_meta.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_reference_picker.dart' show hasErrorHandleNode;
import 'package:flutter_test/flutter_test.dart';

DifyFlowNode _node(String id, String type, {String? parentId}) =>
    DifyFlowNode(id: id, parentId: parentId, data: {'type': type, 'title': '', 'desc': ''});

DifyFlowEdge _edge(String source, String target) => DifyFlowEdge(id: '$source-$target', source: source, target: target);

List<String> _ids(({List<DifyFlowNode> validNodes, int maxDepth}) r) => [for (final n in r.validNodes) n.id];

void main() {
  group('canRunBySingle', () {
    const runnableTypes = [
      'llm', 'knowledge-retrieval', 'code', 'template-transform', 'question-classifier', 'http-request', 'tool', //
      'parameter-extractor', 'iteration', 'agent', 'document-extractor', 'loop', 'start', 'if-else',
      'variable-aggregator', 'assigner', 'human-input', 'datasource', 'trigger-schedule', 'trigger-webhook',
      'trigger-plugin',
    ];

    for (final type in runnableTypes) {
      test('should return true for %s when not a child node', () {
        expect(canRunBySingle(type, isChildNode: false), isTrue);
      });
    }

    test('should return false for Assigner when it is a child node', () {
      expect(canRunBySingle('assigner', isChildNode: true), isFalse);
    });

    test('should return true for LLM even as a child node', () {
      expect(canRunBySingle('llm', isChildNode: true), isTrue);
    });

    test('should return false for End node', () {
      expect(canRunBySingle('end', isChildNode: false), isFalse);
    });

    test('should return false for Answer node', () {
      expect(canRunBySingle('answer', isChildNode: false), isFalse);
    });
  });

  group('hasErrorHandleNode', () {
    for (final type in ['llm', 'tool', 'http-request', 'code', 'agent']) {
      test('should return true for %s', () {
        expect(hasErrorHandleNode(type), isTrue);
      });
    }

    test('should return false for non-error-handle types', () {
      expect(hasErrorHandleNode('start'), isFalse);
      expect(hasErrorHandleNode('iteration'), isFalse);
    });

    test('should return false when undefined', () {
      expect(hasErrorHandleNode(null), isFalse);
    });
  });

  group('getValidTreeNodes', () {
    test('should return empty when there are no start/trigger nodes', () {
      final result = getValidTreeNodes([_node('n1', 'code')], []);
      expect(result.validNodes, isEmpty);
      expect(result.maxDepth, 0);
    });

    test('should traverse a linear graph from Start', () {
      final result = getValidTreeNodes(
        [_node('start', 'start'), _node('llm', 'llm'), _node('end', 'end')],
        [_edge('start', 'llm'), _edge('llm', 'end')],
      );
      expect(_ids(result), ['start', 'llm', 'end']);
      expect(result.maxDepth, 3);
    });

    test('should traverse from trigger nodes', () {
      final result = getValidTreeNodes(
        [_node('trigger', 'trigger-webhook'), _node('code', 'code')],
        [
          _edge('trigger', 'code'),
        ],
      );
      expect(_ids(result), containsAll(['trigger', 'code']));
    });

    test('should include iteration children as valid nodes', () {
      final result = getValidTreeNodes(
        [_node('start', 'start'), _node('iter', 'iteration'), _node('child1', 'code', parentId: 'iter')],
        [_edge('start', 'iter')],
      );
      expect(_ids(result), contains('child1'));
    });

    test('should include loop children when loop has outgoers', () {
      final result = getValidTreeNodes(
        [
          _node('start', 'start'),
          _node('loop', 'loop'),
          _node('loop-child', 'code', parentId: 'loop'),
          _node('end', 'end'),
        ],
        [_edge('start', 'loop'), _edge('loop', 'end')],
      );
      expect(_ids(result), contains('loop-child'));
    });

    test('should include loop children as valid nodes when loop is a leaf', () {
      final result = getValidTreeNodes(
        [_node('start', 'start'), _node('loop', 'loop'), _node('loop-child', 'code', parentId: 'loop')],
        [_edge('start', 'loop')],
      );
      expect(_ids(result), contains('loop-child'));
    });

    test('should handle cycles without infinite loop', () {
      final result = getValidTreeNodes(
        [_node('start', 'start'), _node('a', 'code'), _node('b', 'code')],
        [_edge('start', 'a'), _edge('a', 'b'), _edge('b', 'a')],
      );
      expect(result.validNodes, hasLength(3));
    });

    test('should exclude disconnected nodes', () {
      final result = getValidTreeNodes(
        [_node('start', 'start'), _node('connected', 'code'), _node('isolated', 'code')],
        [_edge('start', 'connected')],
      );
      expect(_ids(result), isNot(contains('isolated')));
    });

    test('should handle multiple start nodes without double-traversal', () {
      final result = getValidTreeNodes(
        [_node('start1', 'start'), _node('trigger', 'trigger-schedule'), _node('shared', 'code')],
        [_edge('start1', 'shared'), _edge('trigger', 'shared')],
      );
      expect(_ids(result), containsAll(['start1', 'trigger', 'shared']));
    });

    test('should not increase maxDepth when visiting nodes at same or lower depth', () {
      final result = getValidTreeNodes(
        [_node('start', 'start'), _node('a', 'code'), _node('b', 'code')],
        [_edge('start', 'a'), _edge('start', 'b')],
      );
      expect(result.maxDepth, 2);
    });

    test('should traverse from all trigger types', () {
      final result = getValidTreeNodes(
        [
          _node('ts', 'trigger-schedule'),
          _node('tp', 'trigger-plugin'),
          _node('code1', 'code'),
          _node('code2', 'code'),
        ],
        [_edge('ts', 'code1'), _edge('tp', 'code2')],
      );
      expect(result.validNodes, hasLength(4));
    });

    test('should skip start nodes already visited by a previous start node traversal', () {
      final result = getValidTreeNodes(
        [_node('start1', 'start'), _node('start2', 'trigger-webhook'), _node('shared', 'code')],
        [_edge('start1', 'start2'), _edge('start2', 'shared')],
      );
      expect(_ids(result), containsAll(['start1', 'start2', 'shared']));
    });
  });
}
