// dify-spec: web/app/components/workflow/nodes/iteration/__tests__/use-single-run-form-params.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_single_run.dart';
import 'package:flutter_test/flutter_test.dart';

RunVar createInputVar(String variable) => {
  'type': 'text-input',
  'label': variable,
  'variable': variable,
  'required': false,
};

RfNode createNode(String id, String title, [String type = 'tool']) => {
  'id': id,
  'position': {'x': 0, 'y': 0},
  'data': {'title': title, 'type': type, 'desc': ''},
};

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Iteration',
  'type': 'iteration',
  'start_node_id': 'start-node',
  'iterator_selector': ['start-node', 'items'],
  'iterator_input_type': 'array[string]',
  'output_selector': ['child-node', 'text'],
  'output_type': 'array[string]',
  ...overrides,
};

IterationSingleRunParams params({
  Map<String, Object?>? payload,
  required Map<String, Object?> runInputData,
  void Function(Map<String, Object?>)? setRunInputData,
  List<RunVar> Function(List<RunVar>)? toVarInputs,
}) => IterationSingleRunParams(
  id: 'iteration-node',
  payload: payload ?? createPayload(),
  runInputData: runInputData,
  setRunInputData: setRunInputData ?? (_) {},
  toVarInputs: toVarInputs ?? (_) => const [],
  childrenNodes: [createNode('tool-a', 'Tool A'), createNode('inner-node', 'Inner Node')],
  beforeNodes: [createNode('start-node', 'Start Node', 'start')],
  isNodeInIteration: (id) => id == 'inner-node',
  usedVars: (node) => node['id'] == 'tool-a'
      ? [
          ['start-node', 'answer'],
          ['inner-node', 'secret'],
          ['iteration-node', 'item'],
        ]
      : const [],
  passToServerKey: (_, _) => 'passed_key',
  inputLabel: 'workflow.nodes.iteration.input',
  formatTracing: (_) => [
    {'id': 'formatted-node'},
  ],
);

void main() {
  group('iteration/use-single-run-form-params', () {
    test('should build single-run forms from external vars and keep iterator state in a dedicated form', () {
      final calls = <List<RunVar>>[];
      final result = params(
        runInputData: {
          'query': 'hello',
          'iteration-node.input_selector': ['start-node', 'items'],
        },
        toVarInputs: (vars) {
          calls.add(vars);
          return [createInputVar('#start-node.answer#')];
        },
      );

      expect(calls.single.single, containsPair('variable', 'start-node.answer'));
      expect(calls.single.single, containsPair('value_selector', ['start-node', 'answer']));
      expect(result.forms, hasLength(2));
      expect(result.forms[0].inputs, [createInputVar('#start-node.answer#')]);
      expect(result.forms[0].values, {
        'query': 'hello',
        'iteration-node.input_selector': ['start-node', 'items'],
      });
      expect(result.forms[1].values, {
        'iteration-node.input_selector': ['start-node', 'items'],
      });
      expect(result.allVarObject, {
        'start-node.answer@@@tool-a@@@0': {'inSingleRunPassedKey': 'passed_key'},
      });
      expect(result.nodeInfo, {'id': 'formatted-node'});
    });

    test('should forward form updates and expose iterator dependencies', () {
      final calls = <Map<String, Object?>>[];
      final result = params(
        payload: createPayload({
          'iterator_selector': ['source-node', 'records'],
        }),
        runInputData: {
          'query': 'old',
          'iteration-node.input_selector': ['source-node', 'records'],
        },
        setRunInputData: calls.add,
      );

      result.forms[0].onChange({'query': 'new'});
      result.forms[1].onChange({
        'iteration-node.input_selector': ['source-node', 'next'],
      });

      expect(calls[0], {'query': 'new'});
      expect(calls[1], {
        'query': 'old',
        'iteration-node.input_selector': ['source-node', 'next'],
      });
      expect(result.getDependentVars(), [
        ['source-node', 'records'],
      ]);
      expect(result.getDependentVar('iteration-node.input_selector'), ['source-node', 'records']);
    });
  });
}
