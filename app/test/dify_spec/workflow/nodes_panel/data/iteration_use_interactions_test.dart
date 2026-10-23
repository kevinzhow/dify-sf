// dify-spec: web/app/components/workflow/nodes/iteration/__tests__/use-interactions.spec.tsx
//
// useNodeIterationInteractions over the React Flow nodes (Dify's getNodes / setNodes become the list in and out).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:flutter_test/flutter_test.dart';

RfNode createNode(Map<String, Object?> overrides) => {
  'type': 'custom',
  'position': {'x': 0, 'y': 0},
  'data': {'title': 'Node ${overrides['id']}', 'desc': '', 'type': 'code'},
  ...overrides,
};

RfNode createIterationNode(Map<String, Object?> overrides) => createNode({
  ...overrides,
  'data': {'title': 'Iteration', 'desc': '', 'type': 'iteration', ...?(overrides['data'] as Map<String, Object?>?)},
});

void main() {
  group('useNodeIterationInteractions', () {
    test('should expand the iteration node when children overflow the bounds', () {
      final nodes = [
        createIterationNode({
          'id': 'iteration-node',
          'width': 120,
          'height': 80,
          'data': {'width': 120, 'height': 80},
        }),
        createNode({
          'id': 'child-node',
          'parentId': 'iteration-node',
          'position': {'x': 100, 'y': 90},
          'width': 60,
          'height': 40,
        }),
      ];

      final updated = containerRerender(nodes, 'iteration-node')!;
      final iteration = updated.firstWhere((n) => n['id'] == 'iteration-node');
      expect(iteration['width'], 100 + 60 + containerPadding.right);
      expect(iteration['height'], 90 + 40 + containerPadding.bottom);
    });

    test('should restrict dragging to the iteration container padding', () {
      final nodes = [
        createIterationNode({
          'id': 'iteration-node',
          'width': 200,
          'height': 180,
          'data': {'width': 200, 'height': 180},
        }),
      ];
      final restrict = containerChildDrag(
        nodes,
        createNode({
          'id': 'child-node',
          'parentId': 'iteration-node',
          'position': {'x': -10, 'y': -5},
          'width': 80,
          'height': 60,
          'data': {'type': 'code', 'title': 'Child', 'desc': '', 'isInIteration': true},
        }),
        flag: 'isInIteration',
      );

      expect(restrict, (x: containerPadding.left, y: containerPadding.top));
    });

    test('should rerender the parent iteration node when a child size changes', () {
      final nodes = [
        createIterationNode({
          'id': 'iteration-node',
          'width': 120,
          'height': 80,
          'data': {'width': 120, 'height': 80},
        }),
        createNode({
          'id': 'child-node',
          'parentId': 'iteration-node',
          'position': {'x': 100, 'y': 90},
          'width': 60,
          'height': 40,
        }),
      ];

      final parent = containerOfResized(nodes, 'child-node');
      expect(parent, 'iteration-node');
      expect(containerRerender(nodes, parent!), isNotNull);
    });

    test('should skip iteration rerender when the resized node has no parent', () {
      final nodes = [
        createNode({
          'id': 'standalone-node',
          'data': {'type': 'code', 'title': 'Standalone', 'desc': ''},
        }),
      ];

      expect(containerOfResized(nodes, 'standalone-node'), isNull);
    });

    test('should copy iteration children and remap ids', () {
      final nodes = [
        createIterationNode({'id': 'iteration-node'}),
        createNode({
          'id': 'child-node',
          'parentId': 'iteration-node',
          'data': {'type': 'code', 'title': 'Child', 'desc': ''},
        }),
        createNode({
          'id': 'same-type-node',
          'data': {'type': 'code', 'title': 'Code', 'desc': ''},
        }),
      ];
      final generated = <RfNode>[];

      final copy = iterationChildrenCopy(
        nodes,
        'iteration-node',
        'new-iteration',
        {'existing': 'mapped'},
        generateNewNode: (params) {
          generated.add(params);
          return createNode({
            'id': 'generated',
            'parentId': 'new-iteration',
            'data': {'type': 'code', 'title': 'blocks.code 3', 'desc': '', 'iteration_id': 'new-iteration'},
          });
        },
        blockTitle: (type) => 'blocks.$type',
        defaultValueOf: (_) => {'title': 'Code', 'desc': ''},
      );

      expect(generated.single, containsPair('type', 'custom'));
      expect(generated.single, containsPair('parentId', 'new-iteration'));
      expect(copy.copyChildren, hasLength(1));
      expect(copy.newIdMapping, {'existing': 'mapped', 'child-node': 'new-iterationgenerated0'});
    });
  });
}
