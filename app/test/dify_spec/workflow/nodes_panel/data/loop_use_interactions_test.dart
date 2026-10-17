// dify-spec: web/app/components/workflow/nodes/loop/__tests__/use-interactions.spec.tsx
//
// useNodeLoopInteractions over the React Flow nodes (Dify's getNodes / setNodes become the list in and out).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:flutter_test/flutter_test.dart';

RfNode createNode(Map<String, Object?> overrides) => {
  'type': 'custom',
  'position': {'x': 0, 'y': 0},
  'data': {'title': 'Node ${overrides['id']}', 'desc': '', 'type': 'code'},
  ...overrides,
};

RfNode createLoopNode(Map<String, Object?> overrides) => createNode({
  ...overrides,
  'data': {'title': 'Loop', 'desc': '', 'type': 'loop', ...?(overrides['data'] as Map<String, Object?>?)},
});

void main() {
  group('useNodeLoopInteractions', () {
    test('should expand the loop node when children overflow the bounds', () {
      final nodes = [
        createLoopNode({
          'id': 'loop-node',
          'width': 120,
          'height': 80,
          'data': {'width': 120, 'height': 80},
        }),
        createNode({
          'id': 'child-node',
          'parentId': 'loop-node',
          'position': {'x': 100, 'y': 90},
          'width': 60,
          'height': 40,
        }),
      ];

      final updated = containerRerender(nodes, 'loop-node')!;
      final loop = updated.firstWhere((n) => n['id'] == 'loop-node');
      expect(loop['width'], 100 + 60 + containerPadding.right);
      expect(loop['height'], 90 + 40 + containerPadding.bottom);
    });

    test('should restrict dragging to the loop container padding', () {
      final nodes = [
        createLoopNode({
          'id': 'loop-node',
          'width': 200,
          'height': 180,
          'data': {'width': 200, 'height': 180},
        }),
      ];
      final restrict = containerChildDrag(
        nodes,
        createNode({
          'id': 'child-node',
          'parentId': 'loop-node',
          'position': {'x': -10, 'y': -5},
          'width': 80,
          'height': 60,
          'data': {'type': 'code', 'title': 'Child', 'desc': '', 'isInLoop': true},
        }),
        flag: 'isInLoop',
      );

      expect(restrict, (x: containerPadding.left, y: containerPadding.top));
    });

    test('should rerender the parent loop node when a child size changes', () {
      final nodes = [
        createLoopNode({
          'id': 'loop-node',
          'width': 120,
          'height': 80,
          'data': {'width': 120, 'height': 80},
        }),
        createNode({
          'id': 'child-node',
          'parentId': 'loop-node',
          'position': {'x': 100, 'y': 90},
          'width': 60,
          'height': 40,
        }),
      ];

      final parent = containerOfResized(nodes, 'child-node');
      expect(parent, 'loop-node');
      expect(containerRerender(nodes, parent!), isNotNull);
    });

    test('should skip loop rerender when the resized node has no parent', () {
      final nodes = [
        createNode({
          'id': 'standalone-node',
          'data': {'type': 'code', 'title': 'Standalone', 'desc': ''},
        }),
      ];

      expect(containerOfResized(nodes, 'standalone-node'), isNull);
    });

    test('should copy loop children and remap ids', () {
      final nodes = [
        createLoopNode({'id': 'loop-node'}),
        createNode({
          'id': 'child-node',
          'parentId': 'loop-node',
          'data': {'type': 'code', 'title': 'Child', 'desc': ''},
        }),
        createNode({
          'id': 'same-type-node',
          'data': {'type': 'code', 'title': 'Code', 'desc': ''},
        }),
      ];
      final generated = <RfNode>[];

      final copy = loopChildrenCopy(
        nodes,
        'loop-node',
        'new-loop',
        {'existing': 'mapped'},
        generateNewNode: (params) {
          generated.add(params);
          return createNode({
            'id': 'generated',
            'parentId': 'new-loop',
            'data': {'type': 'code', 'title': 'Code 3', 'desc': '', 'isInLoop': true, 'loop_id': 'new-loop'},
          });
        },
        defaultValueOf: (_) => {'title': 'Code'},
      );

      expect(generated.single, containsPair('type', 'custom'));
      expect(generated.single, containsPair('parentId', 'new-loop'));
      expect(copy.copyChildren, hasLength(1));
      expect(copy.newIdMapping, {'existing': 'mapped', 'child-node': 'new-loopgeneratednew-loop0'});
    });
  });
}
