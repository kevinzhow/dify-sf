// dify-spec: web/app/components/workflow/nodes/loop/__tests__/use-interactions.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:flutter_test/flutter_test.dart';

RfNode createNode([Map<String, Object?> overrides = const {}]) => {
  'id': 'node',
  'type': 'custom',
  'position': {'x': 0, 'y': 0},
  'width': 100,
  'height': 80,
  'data': {'type': 'code', 'title': 'Code', 'desc': ''},
  ...overrides,
};

void main() {
  group('loop interaction helpers', () {
    test('calculates bounds and container resize from overflowing children', () {
      final children = [
        createNode({
          'id': 'a',
          'position': {'x': 20, 'y': 10},
          'width': 80,
          'height': 40,
        }),
        createNode({
          'id': 'b',
          'position': {'x': 120, 'y': 60},
          'width': 50,
          'height': 30,
        }),
      ];

      final bounds = getContainerBounds(children);
      expect(bounds.rightNode?['id'], 'b');
      expect(bounds.bottomNode?['id'], 'b');
      expect(getContainerResize(createNode({'width': 120, 'height': 80}), bounds), (width: 186, height: 110));
      expect(getContainerResize(createNode({'width': 300, 'height': 300}), bounds), (width: null, height: null));
    });

    test('restricts loop positions only for loop children and filters loop-start nodes', () {
      final parent = createNode({'id': 'parent', 'width': 200, 'height': 180});
      ({num? x, num? y}) restrict(RfNode n) => getRestrictedPosition(n, parent, flag: 'isInLoop');
      expect(
        restrict(
          createNode({
            'data': {'isInLoop': false},
          }),
        ),
        (x: null, y: null),
      );
      expect(
        restrict(
          createNode({
            'position': {'x': -10, 'y': 160},
            'width': 80,
            'height': 40,
            'data': {'isInLoop': true},
          }),
        ),
        (x: 16, y: 120),
      );
      expect(
        restrict(
          createNode({
            'position': {'x': 180, 'y': -4},
            'width': 40,
            'height': 30,
            'data': {'isInLoop': true},
          }),
        ),
        (x: 144, y: 65),
      );
      expect(
        [
          for (final n in getContainerChildren(
            [
              createNode({'id': 'child', 'parentId': 'loop-1'}),
              createNode({'id': 'start', 'parentId': 'loop-1', 'type': 'custom-loop-start'}),
              createNode({'id': 'other', 'parentId': 'other-loop'}),
            ],
            'loop-1',
            startType: 'custom-loop-start',
          ))
            n['id'],
        ],
        ['child'],
      );
    });

    test('builds copied loop children with derived title and loop metadata', () {
      final child = createNode({
        'id': 'child',
        'position': {'x': 12, 'y': 24},
        'positionAbsolute': {'x': 12, 'y': 24},
        'extent': 'parent',
        'data': {'type': 'code', 'title': 'Original', 'desc': 'child', 'selected': true},
      });

      final result = buildLoopChildCopy(
        child: child,
        childNodeType: 'code',
        defaultValue: {'title': 'Code', 'desc': '', 'type': 'code'},
        nodesWithSameTypeCount: 2,
        newNodeId: 'loop-2',
        index: 3,
      );

      expect(result.newId, 'loop-23');
      expect(result.params['parentId'], 'loop-2');
      expect(result.params['zIndex'], 1001);
      expect(
        result.params['data'],
        allOf(
          containsPair('title', 'Code 3'),
          containsPair('isInLoop', true),
          containsPair('loop_id', 'loop-2'),
          containsPair('selected', false),
          containsPair('_isBundled', false),
        ),
      );
    });
  });
}
