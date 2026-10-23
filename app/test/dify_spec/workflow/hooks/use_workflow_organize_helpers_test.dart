// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-organize.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/organize/workflow_organize.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter_test/flutter_test.dart';

DifyJson createNode({
  String id = 'node',
  String? parentId,
  ({num x, num y}) position = (x: 0, y: 0),
  num width = 100,
  num height = 80,
  String type = 'code',
}) => {
  'id': id,
  'type': 'custom',
  'parentId': ?parentId,
  'position': {'x': position.x, 'y': position.y},
  'width': width,
  'height': height,
  'data': {'type': type, 'title': 'Code', 'desc': ''},
};

LayoutInfo info(num x, num y, num width, num height, [int? layer]) =>
    LayoutInfo(x: x.toDouble(), y: y.toDouble(), width: width.toDouble(), height: height.toDouble(), layer: layer);

LayoutBounds bounds(num minX, num minY, num maxX, num maxY) =>
    LayoutBounds(minX: minX.toDouble(), minY: minY.toDouble(), maxX: maxX.toDouble(), maxY: maxY.toDouble());

Object? positionOf(List<DifyJson> nodes, String id) => nodes.firstWhere((n) => n['id'] == id)['position'];

void main() {
  group('use-workflow-organize helpers', () {
    test('filters top-level container nodes and computes size changes', () {
      final containers = getLayoutContainerNodes([
        createNode(id: 'loop', type: 'loop'),
        createNode(id: 'iteration', type: 'iteration'),
        createNode(id: 'nested-loop', parentId: 'loop', type: 'loop'),
        createNode(id: 'code'),
      ]);
      expect([for (final n in containers) n['id']], ['loop', 'iteration']);

      final sizeChanges = getContainerSizeChanges(containers, {
        'loop': LayoutResult(
          bounds: bounds(10, 20, 180, 150),
          nodes: {'child': info(10, 20, 50, 40)},
        ),
      });
      expect(sizeChanges['loop'], (width: 290, height: 250));
      expect(sizeChanges['iteration'], isNull);
    });

    test('creates aligned layers and applies layout positions to root and child nodes', () {
      final rootNodes = [
        createNode(id: 'root-a'),
        createNode(id: 'root-b'),
        createNode(id: 'loop', type: 'loop', width: 200, height: 180),
        createNode(id: 'loop-child', parentId: 'loop'),
      ];
      final layout = LayoutResult(
        bounds: bounds(0, 0, 400, 300),
        nodes: {
          'root-a': info(10, 100, 120, 40, 0),
          'root-b': info(210, 120, 80, 80, 0),
          'loop': info(320, 40, 200, 180, 1),
        },
      );
      final childLayoutsMap = {
        'loop': LayoutResult(
          bounds: bounds(50, 25, 180, 90),
          nodes: {'loop-child': info(100, 45, 80, 40)},
        ),
      };

      final layerMap = createLayerMap(layout);
      expect(layerMap[0], (minY: 100, maxHeight: 80));

      final resized = applyContainerSizeChanges(rootNodes, {'loop': (width: 260, height: 220)});
      final loop = resized.firstWhere((n) => n['id'] == 'loop');
      expect(loop, containsPair('width', 260));
      expect(loop, containsPair('height', 220));
      expect(loop['data'], allOf(containsPair('width', 260), containsPair('height', 220)));

      final laidOut = applyLayoutToNodes(
        nodes: rootNodes,
        layout: layout,
        parentNodes: [rootNodes[2]],
        childLayoutsMap: childLayoutsMap,
      );
      expect(positionOf(laidOut, 'root-b'), {'x': 210, 'y': 100});
      expect(positionOf(laidOut, 'loop-child'), {'x': 110, 'y': 80});
    });

    test('keeps original positions when layer or child layout data is missing', () {
      final nodes = [
        createNode(id: 'root-a', position: (x: 1, y: 2)),
        createNode(id: 'root-b', position: (x: 3, y: 4)),
        createNode(id: 'loop', type: 'loop', position: (x: 5, y: 6)),
        createNode(id: 'loop-child', parentId: 'loop', position: (x: 7, y: 8)),
      ];
      final layout = LayoutResult(
        bounds: bounds(0, 0, 100, 100),
        nodes: {'root-a': info(20, 30, 50, 20)},
      );

      final laidOut = applyLayoutToNodes(nodes: nodes, layout: layout, parentNodes: [nodes[2]], childLayoutsMap: {});

      expect(positionOf(laidOut, 'root-a'), {'x': 20, 'y': 30});
      expect(positionOf(laidOut, 'root-b'), {'x': 3, 'y': 4});
      expect(positionOf(laidOut, 'loop-child'), {'x': 7, 'y': 8});
    });
  });
}
