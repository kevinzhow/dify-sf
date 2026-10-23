// dify-spec: web/app/components/workflow/store/workflow/debug/__tests__/inspect-vars-slice.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

DifyJson createInspectVar([DifyJson overrides = const {}]) => {
  'id': 'var-1',
  'type': 'node',
  'name': 'answer',
  'description': 'Inspect variable',
  'selector': ['node-1', 'answer'],
  'value_type': 'string',
  'value': 'initial',
  'edited': false,
  'visible': true,
  'is_truncated': false,
  'full_content': {'size_bytes': 7, 'download_url': 'https://example.com/inspect-var.txt'},
  ...overrides,
};

DifyJson startNode(String nodeId, List<DifyJson> vars) => {
  'nodeId': nodeId,
  'nodePayload': {'type': 'start', 'title': 'Start', 'desc': ''},
  'nodeType': 'start',
  'title': 'Start',
  'vars': vars,
};

/// toMatchObject: [actual] has every entry of [expected].
Matcher matchesObject(DifyJson expected) =>
    allOf([for (final e in expected.entries) containsPair(e.key, equals(e.value))]);

void main() {
  group('createInspectVarsSlice', () {
    test('updates focus state and replaces node inspect variables', () {
      final store = WorkflowStore();
      final vars = [createInspectVar()];

      store.setCurrentFocusNodeId('node-1');
      store.setNodesWithInspectVars([startNode('node-1', [])]);
      store.setNodeInspectVars('node-1', vars);

      expect(store.currentFocusNodeId.value, 'node-1');
      expect(
        store.nodesWithInspectVars.value[0],
        matchesObject({'nodeId': 'node-1', 'isValueFetched': true, 'vars': vars}),
      );
      store.dispose();
    });

    test('edits, renames, resets, and deletes inspect vars', () {
      final store = WorkflowStore();
      DifyJson firstVar() => (store.nodesWithInspectVars.value[0]['vars'] as List)[0] as DifyJson;

      store.setNodesWithInspectVars([
        startNode('node-1', [createInspectVar()]),
      ]);

      store.setInspectVarValue('node-1', 'var-1', 'edited');
      expect(firstVar(), matchesObject({'value': 'edited', 'edited': true}));

      store.renameInspectVarName('node-1', 'var-1', ['node-1', 'renamed']);
      expect(
        firstVar(),
        matchesObject({
          'name': 'renamed',
          'selector': ['node-1', 'renamed'],
        }),
      );

      store.resetToLastRunVar('node-1', 'var-1', 'restored');
      expect(firstVar(), matchesObject({'value': 'restored', 'edited': false}));

      store.deleteInspectVar('node-1', 'var-1');
      expect(store.nodesWithInspectVars.value[0]['vars'], isEmpty);

      store.deleteNodeInspectVars('node-1');
      expect(store.nodesWithInspectVars.value, isEmpty);

      store.setNodesWithInspectVars([
        startNode('node-2', [
          createInspectVar({'id': 'var-2'}),
        ]),
      ]);
      store.deleteAllInspectVars();

      expect(store.nodesWithInspectVars.value, isEmpty);
      store.dispose();
    });
  });
}
