// dify-spec: web/app/components/workflow/utils/__tests__/workflow.spec.ts
//
// The getNodesConnectedSourceOrTargetHandleIdsMap cases (the helper handleNodeAdd / handleNodeChange use).
import 'package:dify_sf_app/src/workflow_editor/node_insertion/node_insertion.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dify's fixtures `createNode`: a code node with empty handle id lists unless [data] says otherwise.
Map<String, Object?> _node(String id, String type, [Map<String, Object?> data = const {}]) => {
  'id': id,
  'type': 'custom',
  'position': {'x': 0, 'y': 0},
  'data': {
    'title': '',
    'desc': '',
    'type': type,
    '_connectedSourceHandleIds': <String>[],
    '_connectedTargetHandleIds': <String>[],
    ...data,
  },
};

Map<String, Object?> _edge(String source, String target, {String? sourceHandle, String? targetHandle}) => {
  'id': '$source-$target',
  'type': 'custom',
  'source': source,
  'target': target,
  'sourceHandle': ?sourceHandle,
  'targetHandle': ?targetHandle,
};

void main() {
  group('getNodesConnectedSourceOrTargetHandleIdsMap', () {
    test('should add handle ids when type is add', () {
      final edge = _edge('a', 'b', sourceHandle: 'src-handle', targetHandle: 'tgt-handle');
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [(type: 'add', edge: edge)],
        [_node('a', 'start'), _node('b', 'code')],
      );
      expect(result['a']!.source, contains('src-handle'));
      expect(result['b']!.target, contains('tgt-handle'));
    });

    test('should remove handle ids when type is remove', () {
      final edge = _edge('a', 'b', sourceHandle: 'src-handle', targetHandle: 'tgt-handle');
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [(type: 'remove', edge: edge)],
        [
          _node('a', 'start', {
            '_connectedSourceHandleIds': ['src-handle'],
          }),
          _node('b', 'code', {
            '_connectedTargetHandleIds': ['tgt-handle'],
          }),
        ],
      );
      expect(result['a']!.source, isNot(contains('src-handle')));
      expect(result['b']!.target, isNot(contains('tgt-handle')));
    });

    test('should use default handle ids when sourceHandle/targetHandle are missing', () {
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [(type: 'add', edge: _edge('a', 'b'))],
        [_node('a', 'start'), _node('b', 'code')],
      );
      expect(result['a']!.source, contains('source'));
      expect(result['b']!.target, contains('target'));
    });

    test('should skip when source node is not found', () {
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [(type: 'add', edge: _edge('missing', 'b', sourceHandle: 'src'))],
        [_node('b', 'code')],
      );
      expect(result['missing'], isNull);
      expect(result['b']!.target, isNotNull);
    });

    test('should skip when target node is not found', () {
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [(type: 'add', edge: _edge('a', 'missing', targetHandle: 'tgt'))],
        [_node('a', 'start')],
      );
      expect(result['a']!.source, isNotNull);
      expect(result['missing'], isNull);
    });

    test('should reuse existing map entry for same node across multiple changes', () {
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [
          (type: 'add', edge: _edge('a', 'b', sourceHandle: 'h1')),
          (type: 'add', edge: _edge('a', 'c', sourceHandle: 'h2')),
        ],
        [_node('a', 'start'), _node('b', 'code'), _node('c', 'code')],
      );
      expect(result['a']!.source, containsAll(['h1', 'h2']));
    });

    test('should fallback to empty arrays when node data has no handle id arrays', () {
      Map<String, Object?> bare(String id, String type) =>
          _node(id, type)..['data'] = {'title': '', 'desc': '', 'type': type};
      final result = getNodesConnectedSourceOrTargetHandleIdsMap(
        [(type: 'add', edge: _edge('a', 'b', sourceHandle: 'h1', targetHandle: 'h2'))],
        [bare('a', 'start'), bare('b', 'code')],
      );
      expect(result['a']!.source, contains('h1'));
      expect(result['b']!.target, contains('h2'));
    });
  });
}
