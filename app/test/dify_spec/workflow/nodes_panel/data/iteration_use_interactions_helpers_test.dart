// dify-spec: web/app/components/workflow/nodes/iteration/__tests__/use-interactions.helpers.spec.ts
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

({num? x, num? y}) restrict(RfNode node, RfNode? parent) => getRestrictedPosition(node, parent, flag: 'isInIteration');

void main() {
  group('iteration interaction helpers', () {
    test('calculates bounds, resize and drag restriction for iteration containers', () {
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
      expect(
        restrict(
          createNode({
            'position': {'x': -10, 'y': 160},
            'width': 80,
            'height': 40,
            'data': {'isInIteration': true},
          }),
          createNode({'width': 200, 'height': 180}),
        ),
        (x: 16, y: 120),
      );
      expect(
        restrict(
          createNode({
            'position': {'x': 180, 'y': -4},
            'width': 40,
            'height': 30,
            'data': {'isInIteration': true},
          }),
          createNode({'width': 200, 'height': 180}),
        ),
        (x: 144, y: 65),
      );
    });

    test('filters iteration children and increments per-type counts', () {
      final typeCount = <String, int>{};
      expect(getNextChildNodeTypeCount(typeCount, 'code', 2), 3);
      expect(getNextChildNodeTypeCount(typeCount, 'code', 2), 4);
      expect(
        [
          for (final n in getContainerChildren(
            [
              createNode({'id': 'child', 'parentId': 'iteration-1'}),
              createNode({'id': 'start', 'parentId': 'iteration-1', 'type': 'custom-iteration-start'}),
              createNode({'id': 'other', 'parentId': 'other-iteration'}),
            ],
            'iteration-1',
            startType: 'custom-iteration-start',
          ))
            n['id'],
        ],
        ['child'],
      );
    });

    test('keeps bounds, resize and positions empty when no container restriction applies', () {
      expect(getContainerBounds(const []), (rightNode: null, bottomNode: null));
      expect(
        getContainerResize(createNode({'width': 300, 'height': 240}), (rightNode: null, bottomNode: null)),
        (width: null, height: null),
      );
      expect(
        restrict(
          createNode({
            'data': {'isInIteration': true},
          }),
          null,
        ),
        (x: null, y: null),
      );
      expect(
        restrict(
          createNode({
            'data': {'isInIteration': false},
          }),
          createNode({'width': 200, 'height': 180}),
        ),
        (x: null, y: null),
      );
    });

    test('builds copied iteration children with iteration metadata', () {
      final child = createNode({
        'id': 'child',
        'position': {'x': 12, 'y': 24},
        'positionAbsolute': {'x': 12, 'y': 24},
        'extent': 'parent',
        'zIndex': 1002,
        'data': {'type': 'code', 'title': 'Original', 'desc': 'child', 'selected': true},
      });

      final result = buildIterationChildCopy(
        child: child,
        childNodeType: 'code',
        defaultValue: {'title': 'Code', 'desc': '', 'type': 'code'},
        title: 'blocks.code 3',
        newNodeId: 'iteration-2',
      );

      expect(result['parentId'], 'iteration-2');
      expect(result['zIndex'], 1001);
      expect(result['data'], containsPair('title', 'blocks.code 3'));
      expect(result['data'], containsPair('iteration_id', 'iteration-2'));
      expect(result['data'], containsPair('selected', false));
      expect(result['data'], containsPair('_isBundled', false));
    });
  });
}
