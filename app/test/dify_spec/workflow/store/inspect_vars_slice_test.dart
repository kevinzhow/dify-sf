// dify-spec: web/app/components/workflow/store/__tests__/inspect-vars-slice.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

DifyJson makeVar([DifyJson overrides = const {}]) => {
  'id': 'var-1',
  'name': 'output',
  'type': 'node',
  'description': '',
  'selector': ['node-1', 'output'],
  'value_type': 'string',
  'value': 'hello',
  'edited': false,
  'visible': true,
  'is_truncated': false,
  'full_content': {'size_bytes': 0, 'download_url': ''},
  ...overrides,
};

DifyJson makeNodeWithVar(String nodeId, List<DifyJson> vars) => {
  'nodeId': nodeId,
  'nodePayload': {'title': 'Node $nodeId', 'desc': '', 'type': 'code'},
  'nodeType': 'code',
  'title': 'Node $nodeId',
  'vars': vars,
  'isValueFetched': false,
};

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  List<DifyJson> varsOf(int i) => (store.nodesWithInspectVars.value[i]['vars'] as List).cast<DifyJson>();

  group('Inspect Vars Slice', () {
    group('setNodesWithInspectVars', () {
      test('should replace the entire list', () {
        final nodes = [
          makeNodeWithVar('n1', [makeVar()]),
        ];
        store.setNodesWithInspectVars(nodes);
        expect(store.nodesWithInspectVars.value, nodes);
      });
    });

    group('deleteAllInspectVars', () {
      test('should clear all nodes', () {
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [makeVar()]),
        ]);
        store.deleteAllInspectVars();
        expect(store.nodesWithInspectVars.value, isEmpty);
      });
    });

    group('setNodeInspectVars', () {
      test('should update vars for a specific node and mark as fetched', () {
        final v1 = makeVar({'id': 'v1', 'name': 'a'});
        final v2 = makeVar({'id': 'v2', 'name': 'b'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v1]),
        ]);

        store.setNodeInspectVars('n1', [v2]);

        final node = store.nodesWithInspectVars.value[0];
        expect(node['vars'], [v2]);
        expect(node['isValueFetched'], true);
      });

      test('should not modify state when node is not found', () {
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [makeVar()]),
        ]);

        store.setNodeInspectVars('non-existent', []);

        expect(varsOf(0), hasLength(1));
      });
    });

    group('deleteNodeInspectVars', () {
      test('should remove the matching node', () {
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [makeVar()]),
          makeNodeWithVar('n2', [makeVar()]),
        ]);

        store.deleteNodeInspectVars('n1');

        expect(store.nodesWithInspectVars.value, hasLength(1));
        expect(store.nodesWithInspectVars.value[0]['nodeId'], 'n2');
      });
    });

    group('setInspectVarValue', () {
      test('should update the value and set edited=true', () {
        final v = makeVar({'id': 'v1', 'value': 'old', 'edited': false});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.setInspectVarValue('n1', 'v1', 'new');

        final updated = varsOf(0)[0];
        expect(updated['value'], 'new');
        expect(updated['edited'], true);
      });

      test('should not change state when var is not found', () {
        final v = makeVar({'id': 'v1', 'value': 'old'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.setInspectVarValue('n1', 'wrong-id', 'new');

        expect(varsOf(0)[0]['value'], 'old');
      });

      test('should not change state when node is not found', () {
        final v = makeVar({'id': 'v1', 'value': 'old'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.setInspectVarValue('wrong-node', 'v1', 'new');

        expect(varsOf(0)[0]['value'], 'old');
      });
    });

    group('resetToLastRunVar', () {
      test('should restore value and set edited=false', () {
        final v = makeVar({'id': 'v1', 'value': 'modified', 'edited': true});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.resetToLastRunVar('n1', 'v1', 'original');

        final updated = varsOf(0)[0];
        expect(updated['value'], 'original');
        expect(updated['edited'], false);
      });

      test('should not change state when node is not found', () {
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [makeVar()]),
        ]);

        store.resetToLastRunVar('wrong-node', 'v1', 'val');

        expect(varsOf(0)[0]['edited'], false);
      });

      test('should not change state when var is not found', () {
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [
            makeVar({'id': 'v1', 'edited': true}),
          ]),
        ]);

        store.resetToLastRunVar('n1', 'wrong-var', 'val');

        expect(varsOf(0)[0]['edited'], true);
      });
    });

    group('renameInspectVarName', () {
      test('should update name and selector', () {
        final v = makeVar({
          'id': 'v1',
          'name': 'old_name',
          'selector': ['n1', 'old_name'],
        });
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.renameInspectVarName('n1', 'v1', ['n1', 'new_name']);

        final updated = varsOf(0)[0];
        expect(updated['name'], 'new_name');
        expect(updated['selector'], ['n1', 'new_name']);
      });

      test('should not change state when node is not found', () {
        final v = makeVar({'id': 'v1', 'name': 'old'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.renameInspectVarName('wrong-node', 'v1', ['x', 'y']);

        expect(varsOf(0)[0]['name'], 'old');
      });

      test('should not change state when var is not found', () {
        final v = makeVar({'id': 'v1', 'name': 'old'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.renameInspectVarName('n1', 'wrong-var', ['x', 'y']);

        expect(varsOf(0)[0]['name'], 'old');
      });
    });

    group('deleteInspectVar', () {
      test('should remove the matching var from the node', () {
        final v1 = makeVar({'id': 'v1'});
        final v2 = makeVar({'id': 'v2'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v1, v2]),
        ]);

        store.deleteInspectVar('n1', 'v1');

        final vars = varsOf(0);
        expect(vars, hasLength(1));
        expect(vars[0]['id'], 'v2');
      });

      test('should not change state when var is not found', () {
        final v = makeVar({'id': 'v1'});
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [v]),
        ]);

        store.deleteInspectVar('n1', 'wrong-id');

        expect(varsOf(0), hasLength(1));
      });

      test('should not change state when node is not found', () {
        store.setNodesWithInspectVars([
          makeNodeWithVar('n1', [makeVar()]),
        ]);

        store.deleteInspectVar('wrong-node', 'v1');

        expect(varsOf(0), hasLength(1));
      });
    });

    group('currentFocusNodeId', () {
      test('should update and clear focus node', () {
        store.setCurrentFocusNodeId('n1');
        expect(store.currentFocusNodeId.value, 'n1');

        store.setCurrentFocusNodeId(null);
        expect(store.currentFocusNodeId.value, isNull);
      });
    });
  });
}
