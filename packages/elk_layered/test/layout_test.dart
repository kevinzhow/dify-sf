import 'dart:convert';
import 'dart:io';

import 'package:elk_layered/elk_layered.dart';
import 'package:test/test.dart';

void main() {
  final inputs = jsonDecode(File('research/graphs.json').readAsStringSync()) as List;
  final reference = {
    for (final record in jsonDecode(File('research/elkjs.json').readAsStringSync()) as List)
      record['id'] as String: record['nodes'] as List,
  };

  group('elkjs 0.11.1 oracle', () {
    for (final record in inputs) {
      final id = record['id'] as String;
      for (final normalize in [true, false]) {
        test('$id (${normalize ? 'Dify normalized' : 'raw elkjs'})', () {
          final graph = record['graph'] as Map<String, dynamic>;
          final before = jsonEncode(graph);
          final result = layoutGraph(graph, normalize: normalize);
          final nodes = reference[id]!;
          final minX = normalize ? nodes.map((n) => n['x'] as num).reduce((a, b) => a < b ? a : b) : 0;
          final minY = normalize ? nodes.map((n) => n['y'] as num).reduce((a, b) => a < b ? a : b) : 0;
          expect(result.nodes.keys.toSet(), nodes.map((n) => n['id']).toSet());
          for (final expected in nodes) {
            final actual = result.nodes[expected['id']]!;
            expect(actual.x, closeTo((expected['x'] as num) - minX, 1e-9), reason: '${expected['id']}.x');
            expect(actual.y, closeTo((expected['y'] as num) - minY, 1e-9), reason: '${expected['id']}.y');
            expect(actual.width, closeTo(expected['width'] as num, 1e-9));
            expect(actual.height, closeTo(expected['height'] as num, 1e-9));
          }
          expect(jsonEncode(graph), before, reason: 'layout must not mutate input data');
        });
      }
    }
  });

  test('empty graph has finite zero bounds', () {
    final result = layoutGraph({'children': [], 'edges': []});
    expect(result.nodes, isEmpty);
    expect([result.bounds.minX, result.bounds.minY, result.bounds.maxX, result.bounds.maxY], [0, 0, 0, 0]);
  });

  test('single node uses Dify dimensions, normalizes, and retains raw padding', () {
    final graph = {
      'children': [
        {'id': 'only'},
      ],
    };
    final result = layoutGraph(graph);
    expect(result.nodes['only']!.toJson(), {'x': 0, 'y': 0, 'width': 244, 'height': 100});
    final raw = layoutGraph(graph, normalize: false);
    expect(raw.nodes['only']!.x, 12);
    expect(raw.nodes['only']!.y, 12);
    expect(result.bounds.width, 244);
    expect(result.bounds.height, 100);
  });

  test('legacy sourcePort is ignored, while unused declared ports affect positions', () {
    final input =
        jsonDecode(jsonEncode(inputs.firstWhere((r) => r['id'] == 'basic/root/chain')['graph']))
            as Map<String, dynamic>;
    final first = layoutGraph(input);
    for (final edge in input['edges'] as List) {
      edge['sourcePort'] = 'this-port-does-not-exist';
    }
    final second = layoutGraph(input);
    expect(second.nodes.map((k, v) => MapEntry(k, v.toJson())), first.nodes.map((k, v) => MapEntry(k, v.toJson())));
    for (final node in input['children'] as List) {
      (node as Map).remove('ports');
    }
    final withoutUnusedPorts = layoutGraph(input);
    expect(
      withoutUnusedPorts.nodes.map((k, v) => MapEntry(k, v.toJson())),
      isNot(first.nodes.map((k, v) => MapEntry(k, v.toJson()))),
    );
  });

  test('unsupported graphs and invalid endpoints fail explicitly', () {
    expect(
      () => layoutGraph({
        'children': [
          {
            'id': 'a',
            'children': [
              {'id': 'b'},
            ],
          },
        ],
      }),
      throwsUnsupportedError,
    );
    expect(
      () => layoutGraph({
        'children': [
          {'id': 'a'},
        ],
        'edges': [
          {
            'id': 'e',
            'sources': ['a'],
            'targets': ['a'],
          },
        ],
      }),
      throwsUnsupportedError,
    );
    expect(
      () => layoutGraph({
        'children': [
          {'id': 'a'},
        ],
        'edges': [
          {
            'id': 'e',
            'sources': ['a'],
            'targets': ['missing'],
          },
        ],
      }),
      throwsArgumentError,
    );
    expect(
      () => layoutGraph({
        'layoutOptions': {'elk.edgeRouting': 'ORTHOGONAL'},
      }),
      throwsUnsupportedError,
    );
  });
}
