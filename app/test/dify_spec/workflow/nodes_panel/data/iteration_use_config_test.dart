// dify-spec: web/app/components/workflow/nodes/iteration/__tests__/use-config.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/iteration_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Iteration',
  'desc': '',
  'type': 'iteration',
  'iterator_selector': ['start', 'items'],
  'iterator_input_type': 'array[string]',
  'output_selector': ['child', 'result'],
  'output_type': 'array[string]',
  'is_parallel': false,
  'parallel_nums': 3,
  'error_handle_mode': 'terminated',
  'flatten_output': false,
  'start_node_id': 'start-node',
  ...overrides,
};

PickerVar createVar(String type, [String variable = 'test.variable']) => PickerVar(variable, type);

void main() {
  group('iteration/use-config', () {
    late List<Map<String, Object?>> setInputs;
    late List<String> deleted;
    late IterationConfig config;

    setUp(() {
      setInputs = [];
      deleted = [];
      config = IterationConfig(
        id: 'iteration-node',
        inputs: createPayload(),
        setInputs: setInputs.add,
        deleteNodeInspectorVars: deleted.add,
      );
    });

    testWidgets('should expose iteration children vars and filter only array-like iterator inputs', (t) async {
      final h = await Harness.start(t, [
        difyNode('start', {'type': 'start', 'variables': <Object?>[]}),
        difyNode('iteration-node', createPayload(), x: 300),
        difyNode('child-node', {
          'type': 'code',
          'outputs': {
            'result': {'type': 'string', 'children': null},
          },
        }, parent: 'iteration-node'),
      ]);
      h.store.environmentVariables.value = [
        {'name': 'api', 'value_type': 'string'},
      ];
      final c = IterationConfig.of(
        NodePanelProps(node: h['iteration-node']!, controller: h.controller, actions: h.actions()),
      );

      expect(c.readOnly, isFalse);
      // Dify's toNodeOutputVars(children, isChatMode, undefined, [], [], []): no environment / conversation groups.
      expect([for (final g in c.childrenNodeVars.vars) g.nodeId], ['child-node', 'global']);
      expect([for (final n in c.iterationChildrenNodes) n.id], ['child-node']);
      expect(c.filterInputVar(createVar('array[file]', 'files')), isTrue);
      expect(c.filterInputVar(createVar('string', 'text')), isFalse);
      await h.dispose(t);
    });

    test('should update iterator input and output selectors and reset inspector vars on output changes', () {
      config.handleInputChange(['start', 'documents'], createVar('array[object]', 'start.documents'));
      expect(setInputs.last, containsPair('iterator_selector', ['start', 'documents']));
      expect(setInputs.last, containsPair('iterator_input_type', 'array[object]'));

      setInputs.clear();
      config.handleOutputVarChange(['child', 'score'], createVar('number', 'child.score'));
      expect(setInputs.last, containsPair('output_selector', ['child', 'score']));
      expect(setInputs.last, containsPair('output_type', 'array[number]'));
      expect(deleted, ['iteration-node']);

      setInputs.clear();
      config.handleOutputVarChange(['child', 'result'], createVar('string', 'child.result'));
      expect(setInputs, isEmpty);
    });

    test('should update parallel, error-mode, and flatten options', () {
      config
        ..changeParallel(true)
        ..changeErrorResponseMode('continue-on-error')
        ..changeParallelNums(6)
        ..changeFlattenOutput(true);

      expect(setInputs[0], containsPair('is_parallel', true));
      expect(setInputs[1], containsPair('error_handle_mode', 'continue-on-error'));
      expect(setInputs[2], containsPair('parallel_nums', 6));
      expect(setInputs[3], containsPair('flatten_output', true));
    });

    test('should fall back to empty selectors and empty plugin lists when metadata is missing', () {
      // The children's variables are computed without environment or conversation variables (see the first case).
      config.handleInputChange(const []);
      expect(setInputs.last, containsPair('iterator_selector', <String>[]));
      expect(setInputs.last, containsPair('iterator_input_type', 'array[string]'));

      setInputs.clear();
      deleted.clear();
      config.handleOutputVarChange(const [], createVar('boolean', 'child.flag'));
      expect(setInputs.last, containsPair('output_selector', <String>[]));
      expect(setInputs.last, containsPair('output_type', 'array[string]'));
      expect(deleted, ['iteration-node']);
    });
  });
}
