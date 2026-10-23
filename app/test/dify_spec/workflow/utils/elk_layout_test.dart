// dify-spec: web/app/components/workflow/utils/__tests__/elk-layout.spec.ts
import 'package:dify_sf_app/src/workflow_editor/organize/elk_layout.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter_test/flutter_test.dart';

// The spec's elkjs mock: records the graph and places child i at (100 + 300i, 50 + 100i), or [mockReturnOverride].
Map<String, Object?>? layoutCallArgs;
Map<String, Object?> Function(Map<String, Object?> graph)? mockReturnOverride;

Map<String, Object?> mockElk(Map<String, Object?> graph) {
  layoutCallArgs = graph;
  if (mockReturnOverride != null) return mockReturnOverride!(graph);
  final children = (graph['children']! as List).cast<DifyJson>();
  return {
    ...graph,
    'children': [
      for (var i = 0; i < children.length; i++)
        {
          ...children[i],
          'x': 100 + i * 300,
          'y': 50 + i * 100,
          'width': children[i]['width'] ?? 244,
          'height': children[i]['height'] ?? 100,
        },
    ],
  };
}

LayoutResult getLayout(List<DifyJson> nodes, List<DifyJson> edges) => getLayoutByELK(nodes, edges, elk: mockElk);

LayoutResult? getChildLayout(String parent, List<DifyJson> nodes, List<DifyJson> edges) =>
    getLayoutForChildNodes(parent, nodes, edges, elk: mockElk);

// __tests__/fixtures.ts createNode / createEdge.
var _nodeIds = 0, _edgeIds = 0;

DifyJson makeWorkflowNode({
  String? id,
  String type = 'custom',
  String? parentId,
  String dataType = 'code',
  Map<String, Object?> data = const {},
}) {
  id ??= 'node-${++_nodeIds}';
  return {
    'id': id,
    'type': type,
    'position': {'x': 0, 'y': 0},
    'targetPosition': 'left',
    'sourcePosition': 'right',
    'data': {
      'title': '',
      'desc': '',
      'type': dataType,
      '_connectedSourceHandleIds': <String>[],
      '_connectedTargetHandleIds': <String>[],
      ...data,
    },
    'parentId': ?parentId,
  };
}

DifyJson makeWorkflowEdge({
  String? id,
  String source = 'source-node',
  String target = 'target-node',
  String? sourceHandle,
  Map<String, Object?> data = const {},
}) => {
  'id': id ?? 'edge-$source-$target-${++_edgeIds}',
  'source': source,
  'target': target,
  'sourceHandle': ?sourceHandle,
  'data': {'sourceType': 'start', 'targetType': 'code', ...data},
};

List<DifyJson> get children => (layoutCallArgs!['children']! as List).cast<DifyJson>();
List<DifyJson> get elkEdges => (layoutCallArgs!['edges']! as List).cast<DifyJson>();
DifyJson child(String id) => children.firstWhere((c) => c['id'] == id);
List<DifyJson> portsOf(String id) => ((child(id)['ports'] as List?) ?? const []).cast<DifyJson>();
List<String> portIds(String id) => [for (final p in portsOf(id)) p['id']! as String];
Object? portOption(DifyJson port, String key) => (port['layoutOptions']! as Map)[key];

void main() {
  setUp(() {
    _nodeIds = _edgeIds = 0;
    layoutCallArgs = null;
    mockReturnOverride = null;
  });

  group('getLayoutByELK', () {
    test('should return layout for simple linear graph', () {
      final nodes = [makeWorkflowNode(id: 'a', dataType: 'start'), makeWorkflowNode(id: 'b')];
      final edges = [makeWorkflowEdge(source: 'a', target: 'b')];

      final result = getLayout(nodes, edges);

      expect(result.nodes.length, 2);
      expect(result.nodes.containsKey('a'), isTrue);
      expect(result.nodes.containsKey('b'), isTrue);
      expect(result.bounds.minX, 0);
      expect(result.bounds.minY, 0);
    });

    test('should filter out nodes with parentId', () {
      final nodes = [makeWorkflowNode(id: 'a', dataType: 'start'), makeWorkflowNode(id: 'child', parentId: 'a')];

      final result = getLayout(nodes, []);
      expect(result.nodes.length, 1);
      expect(result.nodes.containsKey('child'), isFalse);
    });

    test('should filter out non-CUSTOM_NODE type nodes', () {
      final nodes = [
        makeWorkflowNode(id: 'a', dataType: 'start'),
        makeWorkflowNode(id: 'iter-start', type: 'custom-iteration-start', dataType: 'iteration-start'),
      ];

      final result = getLayout(nodes, []);
      expect(result.nodes.length, 1);
    });

    test('should filter out iteration/loop internal edges', () {
      final nodes = [makeWorkflowNode(id: 'a', dataType: 'start'), makeWorkflowNode(id: 'b')];
      final edges = [
        makeWorkflowEdge(source: 'a', target: 'b', data: {'isInIteration': true, 'iteration_id': 'iter-1'}),
      ];

      getLayout(nodes, edges);
      expect(elkEdges, isEmpty);
    });

    test('should use default dimensions when node has no width/height', () {
      final node = makeWorkflowNode(id: 'a', dataType: 'start')
        ..remove('width')
        ..remove('height');

      final result = getLayout([node], []);
      expect(result.nodes.length, 1);
      final info = result.nodes['a']!;
      expect(info.width, 244);
      expect(info.height, 100);
    });

    test('should build ports for IfElse nodes with multiple branches', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-1', 'logical_operator': 'and', 'conditions': <Object>[]},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'if-1', target: 'b', sourceHandle: 'case-1'),
        makeWorkflowEdge(id: 'e2', source: 'if-1', target: 'c', sourceHandle: 'false'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('if-1'), hasLength(2));
      expect((child('if-1')['layoutOptions']! as Map)['elk.portConstraints'], 'FIXED_ORDER');
    });

    test('should build ports for IfElse even with single branch', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-1'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
      ];
      final edges = [makeWorkflowEdge(source: 'if-1', target: 'b', sourceHandle: 'case-1')];

      getLayout(nodes, edges);
      expect(portsOf('if-1'), hasLength(1));
      expect(portOption(portsOf('if-1')[0], 'elk.port.side'), 'EAST');
    });

    test('should build ports for HumanInput nodes with multiple branches', () {
      final nodes = [
        makeWorkflowNode(
          id: 'hi-1',
          dataType: 'human-input',
          data: {
            'user_actions': [
              {'id': 'action-1'},
              {'id': 'action-2'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'hi-1', target: 'b', sourceHandle: 'action-1'),
        makeWorkflowEdge(id: 'e2', source: 'hi-1', target: 'c', sourceHandle: '__timeout'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('hi-1'), hasLength(2));
    });

    test('should build ports for HumanInput even with single branch', () {
      final nodes = [
        makeWorkflowNode(
          id: 'hi-1',
          dataType: 'human-input',
          data: {
            'user_actions': [
              {'id': 'action-1'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
      ];
      final edges = [makeWorkflowEdge(source: 'hi-1', target: 'b', sourceHandle: 'action-1')];

      getLayout(nodes, edges);
      expect(portsOf('hi-1'), hasLength(1));
      expect(portOption(portsOf('hi-1')[0], 'elk.port.side'), 'EAST');
    });

    test('should normalise bounds so minX and minY start at 0', () {
      final result = getLayout([makeWorkflowNode(id: 'a', dataType: 'start')], []);
      expect(result.bounds.minX, 0);
      expect(result.bounds.minY, 0);
    });

    test('should return empty layout when no nodes match filter', () {
      final result = getLayout([], []);
      expect(result.nodes, isEmpty);
      expect(result.bounds, LayoutBounds.zero);
    });

    test('should sort IfElse edges with false (ELSE) last', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-a', 'logical_operator': 'and', 'conditions': <Object>[]},
              {'case_id': 'case-b', 'logical_operator': 'and', 'conditions': <Object>[]},
            ],
          },
        ),
        makeWorkflowNode(id: 'x'),
        makeWorkflowNode(id: 'y'),
        makeWorkflowNode(id: 'z'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e-else', source: 'if-1', target: 'z', sourceHandle: 'false'),
        makeWorkflowEdge(id: 'e-a', source: 'if-1', target: 'x', sourceHandle: 'case-a'),
        makeWorkflowEdge(id: 'e-b', source: 'if-1', target: 'y', sourceHandle: 'case-b'),
      ];

      getLayout(nodes, edges);
      expect(portIds('if-1').last, contains('false'));
    });

    test('should sort HumanInput edges with __timeout last', () {
      final nodes = [
        makeWorkflowNode(
          id: 'hi-1',
          dataType: 'human-input',
          data: {
            'user_actions': [
              {'id': 'a1'},
              {'id': 'a2'},
            ],
          },
        ),
        makeWorkflowNode(id: 'x'),
        makeWorkflowNode(id: 'y'),
        makeWorkflowNode(id: 'z'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e-timeout', source: 'hi-1', target: 'z', sourceHandle: '__timeout'),
        makeWorkflowEdge(id: 'e-a1', source: 'hi-1', target: 'x', sourceHandle: 'a1'),
        makeWorkflowEdge(id: 'e-a2', source: 'hi-1', target: 'y', sourceHandle: 'a2'),
      ];

      getLayout(nodes, edges);
      expect(portIds('hi-1').last, contains('__timeout'));
    });

    test('should assign sourcePort to edges from IfElse nodes with ports', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-1'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'if-1', target: 'b', sourceHandle: 'case-1'),
        makeWorkflowEdge(id: 'e2', source: 'if-1', target: 'c', sourceHandle: 'false'),
      ];

      getLayout(nodes, edges);
      expect(elkEdges.where((e) => e['sourcePort'] != null), isNotEmpty);
    });

    test('should handle edges without sourceHandle for ports (use index)', () {
      final nodes = [
        makeWorkflowNode(id: 'if-1', dataType: 'if-else', data: {'cases': <Object>[]}),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final e1 = makeWorkflowEdge(id: 'e1', source: 'if-1', target: 'b');
      final e2 = makeWorkflowEdge(id: 'e2', source: 'if-1', target: 'c');

      final result = getLayout(nodes, [e1, e2]);
      expect(result.nodes, isNotEmpty);
    });

    test('should handle collectLayout with null x/y/width/height values', () {
      mockReturnOverride = (graph) => {
        ...graph,
        'children': [
          for (final c in graph['children']! as List) {'id': (c as Map)['id']},
        ],
      };

      final result = getLayout([makeWorkflowNode(id: 'a', dataType: 'start')], []);
      final info = result.nodes['a']!;
      expect(info.x, 0);
      expect(info.y, 0);
      expect(info.width, 244);
      expect(info.height, 100);
    });

    test('should parse layer index from layoutOptions', () {
      mockReturnOverride = (graph) {
        final cs = graph['children']! as List;
        return {
          ...graph,
          'children': [
            for (var i = 0; i < cs.length; i++)
              {
                ...cs[i] as Map<String, Object?>,
                'x': i * 300,
                'y': 0,
                'width': 244,
                'height': 100,
                'layoutOptions': {'org.eclipse.elk.layered.layerIndex': '$i'},
              },
          ],
        };
      };

      final result = getLayout([makeWorkflowNode(id: 'a', dataType: 'start'), makeWorkflowNode(id: 'b')], []);
      expect(result.nodes['a']!.layer, 0);
      expect(result.nodes['b']!.layer, 1);
    });

    test('should handle collectLayout with nested children', () {
      mockReturnOverride = (graph) => {
        ...graph,
        'children': [
          {
            'id': 'parent-node',
            'x': 0,
            'y': 0,
            'width': 500,
            'height': 400,
            'children': [
              {'id': 'nested-1', 'x': 10, 'y': 10, 'width': 200, 'height': 100},
              {'id': 'nested-2', 'x': 10, 'y': 120, 'width': 200, 'height': 100},
            ],
          },
        ],
      };

      final result = getLayout([
        makeWorkflowNode(id: 'parent-node', dataType: 'start'),
        makeWorkflowNode(id: 'nested-1'),
        makeWorkflowNode(id: 'nested-2'),
      ], []);
      expect(result.nodes.containsKey('nested-1'), isTrue);
      expect(result.nodes.containsKey('nested-2'), isTrue);
    });

    test('should handle collectLayout with predicate filtering some children', () {
      mockReturnOverride = (graph) => {
        ...graph,
        'children': [
          {'id': 'visible', 'x': 0, 'y': 0, 'width': 200, 'height': 100},
          {'id': 'also-visible', 'x': 300, 'y': 0, 'width': 200, 'height': 100},
        ],
      };

      final result = getLayout([
        makeWorkflowNode(id: 'visible', dataType: 'start'),
        makeWorkflowNode(id: 'also-visible'),
      ], []);
      expect(result.nodes.length, 2);
    });

    test('should sort IfElse edges where case not found in cases array', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'known-case'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'if-1', target: 'b', sourceHandle: 'unknown-case'),
        makeWorkflowEdge(id: 'e2', source: 'if-1', target: 'c', sourceHandle: 'other-unknown'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('if-1'), hasLength(2));
    });

    test('should sort HumanInput edges where action not found in user_actions', () {
      final nodes = [
        makeWorkflowNode(
          id: 'hi-1',
          dataType: 'human-input',
          data: {
            'user_actions': [
              {'id': 'known-action'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'hi-1', target: 'b', sourceHandle: 'unknown-action'),
        makeWorkflowEdge(id: 'e2', source: 'hi-1', target: 'c', sourceHandle: 'another-unknown'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('hi-1'), hasLength(2));
    });

    test('should handle IfElse edges without handles (no sourceHandle)', () {
      final nodes = [
        makeWorkflowNode(id: 'if-1', dataType: 'if-else', data: {'cases': <Object>[]}),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final e1 = makeWorkflowEdge(id: 'e1', source: 'if-1', target: 'b');
      final e2 = makeWorkflowEdge(id: 'e2', source: 'if-1', target: 'c');

      getLayout(nodes, [e1, e2]);
      expect(portsOf('if-1'), hasLength(2));
    });

    test('should handle HumanInput edges without handles', () {
      final nodes = [
        makeWorkflowNode(id: 'hi-1', dataType: 'human-input', data: {'user_actions': <Object>[]}),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final e1 = makeWorkflowEdge(id: 'e1', source: 'hi-1', target: 'b');
      final e2 = makeWorkflowEdge(id: 'e2', source: 'hi-1', target: 'c');

      getLayout(nodes, [e1, e2]);
      expect(portsOf('hi-1'), hasLength(2));
    });

    test('should handle IfElse with no cases property', () {
      final nodes = [
        makeWorkflowNode(id: 'if-1', dataType: 'if-else'),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'if-1', target: 'b', sourceHandle: 'true'),
        makeWorkflowEdge(id: 'e2', source: 'if-1', target: 'c', sourceHandle: 'false'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('if-1'), hasLength(2));
    });

    test('should handle HumanInput with no user_actions property', () {
      final nodes = [
        makeWorkflowNode(id: 'hi-1', dataType: 'human-input'),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'hi-1', target: 'b', sourceHandle: 'action-1'),
        makeWorkflowEdge(id: 'e2', source: 'hi-1', target: 'c', sourceHandle: '__timeout'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('hi-1'), hasLength(2));
    });

    test('should build ports for QuestionClassifier sorted by classes order', () {
      final nodes = [
        makeWorkflowNode(
          id: 'qc-1',
          dataType: 'question-classifier',
          data: {
            'classes': [
              {'id': 'cls-a', 'name': 'A'},
              {'id': 'cls-b', 'name': 'B'},
              {'id': 'cls-c', 'name': 'C'},
            ],
          },
        ),
        makeWorkflowNode(id: 'x'),
        makeWorkflowNode(id: 'y'),
        makeWorkflowNode(id: 'z'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e-c', source: 'qc-1', target: 'z', sourceHandle: 'cls-c'),
        makeWorkflowEdge(id: 'e-a', source: 'qc-1', target: 'x', sourceHandle: 'cls-a'),
        makeWorkflowEdge(id: 'e-b', source: 'qc-1', target: 'y', sourceHandle: 'cls-b'),
      ];

      getLayout(nodes, edges);
      expect(portIds('qc-1'), ['qc-1-out-cls-a', 'qc-1-out-cls-b', 'qc-1-out-cls-c']);
    });

    test('should build ports for QuestionClassifier with single class', () {
      final nodes = [
        makeWorkflowNode(
          id: 'qc-1',
          dataType: 'question-classifier',
          data: {
            'classes': [
              {'id': 'cls-only', 'name': 'Only'},
            ],
          },
        ),
        makeWorkflowNode(id: 'x'),
      ];
      final edges = [makeWorkflowEdge(id: 'e1', source: 'qc-1', target: 'x', sourceHandle: 'cls-only')];

      getLayout(nodes, edges);
      expect(portsOf('qc-1'), hasLength(1));
      expect(portOption(portsOf('qc-1')[0], 'elk.port.side'), 'EAST');
    });

    test('should only create output (EAST) ports, not input (WEST) ports', () {
      final nodes = [
        makeWorkflowNode(id: 'a', dataType: 'start'),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c', dataType: 'end'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'a', target: 'b'),
        makeWorkflowEdge(id: 'e2', source: 'b', target: 'c'),
      ];

      getLayout(nodes, edges);
      for (final c in children) {
        for (final port in portsOf(c['id']! as String)) {
          expect(portOption(port, 'elk.port.side'), 'EAST');
        }
      }
      expect(child('c').containsKey('ports'), isFalse);
    });

    test('should order children array by DFS following port order', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-a', 'logical_operator': 'and', 'conditions': <Object>[]},
            ],
          },
        ),
        makeWorkflowNode(id: 'start', dataType: 'start'),
        makeWorkflowNode(id: 'branch-a'),
        makeWorkflowNode(id: 'branch-else'),
        makeWorkflowNode(id: 'end', dataType: 'end'),
      ];
      final edges = [
        makeWorkflowEdge(source: 'start', target: 'if-1'),
        makeWorkflowEdge(id: 'e-else', source: 'if-1', target: 'branch-else', sourceHandle: 'false'),
        makeWorkflowEdge(id: 'e-a', source: 'if-1', target: 'branch-a', sourceHandle: 'case-a'),
        makeWorkflowEdge(source: 'branch-a', target: 'end'),
        makeWorkflowEdge(source: 'branch-else', target: 'end'),
      ];

      getLayout(nodes, edges);
      final childIds = [for (final c in children) c['id']];
      // DFS from start: start → if-1 → branch-a (case-a first) → end → branch-else
      expect(childIds.indexOf('branch-a'), lessThan(childIds.indexOf('branch-else')));
    });

    test('should order children by DFS across nested branching nodes', () {
      final nodes = [
        makeWorkflowNode(id: 'start', dataType: 'start'),
        makeWorkflowNode(
          id: 'qc-1',
          dataType: 'question-classifier',
          data: {
            'classes': [
              {'id': 'c1', 'name': 'C1'},
              {'id': 'c2', 'name': 'C2'},
            ],
          },
        ),
        makeWorkflowNode(id: 'upper'),
        makeWorkflowNode(id: 'lower'),
      ];
      final edges = [
        makeWorkflowEdge(source: 'start', target: 'qc-1'),
        makeWorkflowEdge(id: 'e-c2', source: 'qc-1', target: 'lower', sourceHandle: 'c2'),
        makeWorkflowEdge(id: 'e-c1', source: 'qc-1', target: 'upper', sourceHandle: 'c1'),
      ];

      getLayout(nodes, edges);
      final childIds = [for (final c in children) c['id']];
      // DFS: start → qc-1 → upper (c1 first) → lower (c2 second)
      expect(childIds.indexOf('upper'), lessThan(childIds.indexOf('lower')));
    });

    test('should handle QuestionClassifier with no classes property', () {
      final nodes = [
        makeWorkflowNode(id: 'qc-1', dataType: 'question-classifier'),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'qc-1', target: 'b', sourceHandle: 'cls-1'),
        makeWorkflowEdge(id: 'e2', source: 'qc-1', target: 'c', sourceHandle: 'cls-2'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('qc-1'), hasLength(2));
    });

    test('should handle QuestionClassifier edges where handle not found in classes', () {
      final nodes = [
        makeWorkflowNode(
          id: 'qc-1',
          dataType: 'question-classifier',
          data: {
            'classes': [
              {'id': 'known', 'name': 'K'},
            ],
          },
        ),
        makeWorkflowNode(id: 'b'),
        makeWorkflowNode(id: 'c'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e1', source: 'qc-1', target: 'b', sourceHandle: 'unknown-1'),
        makeWorkflowEdge(id: 'e2', source: 'qc-1', target: 'c', sourceHandle: 'unknown-2'),
      ];

      getLayout(nodes, edges);
      expect(portsOf('qc-1'), hasLength(2));
    });

    test('should include disconnected nodes in the layout', () {
      final nodes = [
        makeWorkflowNode(id: 'start', dataType: 'start'),
        makeWorkflowNode(id: 'connected'),
        makeWorkflowNode(id: 'isolated'),
      ];
      final edges = [makeWorkflowEdge(source: 'start', target: 'connected')];

      getLayout(nodes, edges);
      final childIds = [for (final c in children) c['id']];
      expect(childIds, contains('isolated'));
      expect(childIds, hasLength(3));
    });

    test('should build edges in DFS order matching port order', () {
      final nodes = [
        makeWorkflowNode(id: 'start', dataType: 'start'),
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-a'},
            ],
          },
        ),
        makeWorkflowNode(id: 'a'),
        makeWorkflowNode(id: 'b'),
      ];
      final edges = [
        makeWorkflowEdge(source: 'start', target: 'if-1'),
        makeWorkflowEdge(id: 'e-else', source: 'if-1', target: 'b', sourceHandle: 'false'),
        makeWorkflowEdge(id: 'e-a', source: 'if-1', target: 'a', sourceHandle: 'case-a'),
      ];

      getLayout(nodes, edges);
      final ifEdges = elkEdges.where((e) => (e['sources']! as List)[0] == 'if-1').toList();
      expect((ifEdges[0]['targets']! as List)[0], 'a');
      expect((ifEdges[1]['targets']! as List)[0], 'b');
    });

    test('should keep edges for components where every node has an incoming edge', () {
      final nodes = [
        makeWorkflowNode(
          id: 'if-1',
          dataType: 'if-else',
          data: {
            'cases': [
              {'case_id': 'case-a'},
            ],
          },
        ),
        makeWorkflowNode(id: 'a'),
        makeWorkflowNode(id: 'b'),
      ];
      final edges = [
        makeWorkflowEdge(id: 'e-a', source: 'if-1', target: 'a', sourceHandle: 'case-a'),
        makeWorkflowEdge(id: 'e-b', source: 'if-1', target: 'b', sourceHandle: 'false'),
        makeWorkflowEdge(id: 'e-back', source: 'a', target: 'if-1'),
      ];

      getLayout(nodes, edges);

      expect(elkEdges, hasLength(3));
      final pairs = [for (final e in elkEdges) '${(e['sources']! as List)[0]}->${(e['targets']! as List)[0]}'];
      expect(pairs, containsAll(['if-1->a', 'if-1->b', 'a->if-1']));
    });

    test('should filter loop internal edges', () {
      final nodes = [makeWorkflowNode(id: 'a', dataType: 'start')];
      final edges = [
        makeWorkflowEdge(source: 'x', target: 'y', data: {'isInLoop': true, 'loop_id': 'loop-1'}),
      ];

      getLayout(nodes, edges);
      expect(elkEdges, isEmpty);
    });
  });

  group('getLayoutForChildNodes', () {
    test('should return null when no child nodes exist', () {
      final nodes = [makeWorkflowNode(id: 'parent', dataType: 'iteration')];
      expect(getChildLayout('parent', nodes, []), isNull);
    });

    test('should layout child nodes of an iteration', () {
      final nodes = [
        makeWorkflowNode(id: 'parent', dataType: 'iteration'),
        makeWorkflowNode(
          id: 'iter-start',
          type: 'custom-iteration-start',
          parentId: 'parent',
          dataType: 'iteration-start',
        ),
        makeWorkflowNode(id: 'child-1', parentId: 'parent'),
      ];
      final edges = [
        makeWorkflowEdge(
          source: 'iter-start',
          target: 'child-1',
          data: {'isInIteration': true, 'iteration_id': 'parent'},
        ),
      ];

      final result = getChildLayout('parent', nodes, edges);
      expect(result, isNotNull);
      expect(result!.nodes.length, 2);
      expect(result.bounds.minX, 0);
    });

    test('should layout child nodes of a loop', () {
      final nodes = [
        makeWorkflowNode(id: 'loop-p', dataType: 'loop'),
        makeWorkflowNode(id: 'loop-start', type: 'custom-loop-start', parentId: 'loop-p', dataType: 'loop-start'),
        makeWorkflowNode(id: 'loop-child', parentId: 'loop-p'),
      ];
      final edges = [
        makeWorkflowEdge(
          source: 'loop-start',
          target: 'loop-child',
          data: {'isInLoop': true, 'loop_id': 'loop-p'},
        ),
      ];

      final result = getChildLayout('loop-p', nodes, edges);
      expect(result, isNotNull);
      expect(result!.nodes.length, 2);
    });

    test('should only include edges belonging to the parent iteration', () {
      final nodes = [
        makeWorkflowNode(id: 'child-a', parentId: 'parent'),
        makeWorkflowNode(id: 'child-b', parentId: 'parent'),
      ];
      final edges = [
        makeWorkflowEdge(
          source: 'child-a',
          target: 'child-b',
          data: {'isInIteration': true, 'iteration_id': 'parent'},
        ),
        makeWorkflowEdge(source: 'x', target: 'y', data: {'isInIteration': true, 'iteration_id': 'other-parent'}),
      ];

      getChildLayout('parent', nodes, edges);
      expect(elkEdges, hasLength(1));
    });

    Map<String, Object?> Function(Map<String, Object?>) placeAt(num x0) => (graph) {
      final cs = graph['children']! as List;
      return {
        ...graph,
        'children': [
          for (var i = 0; i < cs.length; i++)
            {...cs[i] as Map<String, Object?>, 'x': x0 + i * 300, 'y': 50, 'width': 244, 'height': 100},
        ],
      };
    };

    test('should adjust start node position when x exceeds horizontal padding', () {
      mockReturnOverride = placeAt(200);
      final nodes = [
        makeWorkflowNode(id: 'start', type: 'custom-iteration-start', parentId: 'parent', dataType: 'iteration-start'),
        makeWorkflowNode(id: 'child', parentId: 'parent'),
      ];

      final result = getChildLayout('parent', nodes, []);
      expect(result, isNotNull);
      expect(result!.nodes['start']!.x, lessThanOrEqualTo(nodeLayoutHorizontalPadding / 1.5 + 1));
    });

    test('should not shift when start node x is already within padding', () {
      mockReturnOverride = placeAt(10);
      final nodes = [
        makeWorkflowNode(id: 'start', type: 'custom-iteration-start', parentId: 'parent', dataType: 'iteration-start'),
        makeWorkflowNode(id: 'child', parentId: 'parent'),
      ];

      expect(getChildLayout('parent', nodes, []), isNotNull);
    });

    test('should handle child nodes identified by data type LoopStart', () {
      final nodes = [
        makeWorkflowNode(id: 'ls', parentId: 'parent', dataType: 'loop-start'),
        makeWorkflowNode(id: 'child', parentId: 'parent'),
      ];

      final result = getChildLayout('parent', nodes, []);
      expect(result, isNotNull);
      expect(result!.nodes.length, 2);
    });

    test('should handle child nodes identified by data type IterationStart', () {
      final nodes = [
        makeWorkflowNode(id: 'is', parentId: 'parent', dataType: 'iteration-start'),
        makeWorkflowNode(id: 'child', parentId: 'parent'),
      ];

      final result = getChildLayout('parent', nodes, []);
      expect(result, isNotNull);
      expect(result!.nodes.length, 2);
    });

    test('should handle no start node in child layout', () {
      final nodes = [
        makeWorkflowNode(id: 'c1', parentId: 'parent'),
        makeWorkflowNode(id: 'c2', parentId: 'parent'),
      ];

      final result = getChildLayout('parent', nodes, []);
      expect(result, isNotNull);
      expect(result!.nodes.length, 2);
    });

    test('should build ports and DFS-order for branching nodes inside iteration', () {
      final nodes = [
        makeWorkflowNode(id: 'parent', dataType: 'iteration'),
        makeWorkflowNode(
          id: 'iter-start',
          type: 'custom-iteration-start',
          parentId: 'parent',
          dataType: 'iteration-start',
        ),
        makeWorkflowNode(
          id: 'qc-child',
          parentId: 'parent',
          dataType: 'question-classifier',
          data: {
            'classes': [
              {'id': 'cls-1', 'name': 'C1'},
              {'id': 'cls-2', 'name': 'C2'},
            ],
          },
        ),
        makeWorkflowNode(id: 'upper', parentId: 'parent'),
        makeWorkflowNode(id: 'lower', parentId: 'parent'),
      ];
      const inIteration = {'isInIteration': true, 'iteration_id': 'parent'};
      final edges = [
        makeWorkflowEdge(source: 'iter-start', target: 'qc-child', data: inIteration),
        makeWorkflowEdge(id: 'e-c2', source: 'qc-child', target: 'lower', sourceHandle: 'cls-2', data: inIteration),
        makeWorkflowEdge(id: 'e-c1', source: 'qc-child', target: 'upper', sourceHandle: 'cls-1', data: inIteration),
      ];

      getChildLayout('parent', nodes, edges);

      expect(portsOf('qc-child'), hasLength(2));
      expect(portIds('qc-child')[0], contains('cls-1'));
      expect(portIds('qc-child')[1], contains('cls-2'));
      final childIds = [for (final c in children) c['id']];
      expect(childIds.indexOf('upper'), lessThan(childIds.indexOf('lower')));
    });

    test('should return original layout when bounds are not finite', () {
      mockReturnOverride = (graph) => {...graph, 'children': <Object>[]};
      final nodes = [makeWorkflowNode(id: 'c1', parentId: 'parent')];

      final result = getChildLayout('parent', nodes, []);
      expect(result, isNotNull);
      expect(result!.bounds, LayoutBounds.zero);
    });
  });
}
