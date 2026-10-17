// dify-spec: web/app/components/workflow/nodes/loop/__tests__/use-single-run-form-params.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_single_run.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> createLoopNode([Map<String, Object?> overrides = const {}]) => {
  'title': 'Loop',
  'type': 'loop',
  'start_node_id': 'start-node',
  'loop_count': 3,
  'error_handle_mode': 'terminated',
  'break_conditions': <Object?>[],
  'loop_variables': <Object?>[],
  ...overrides,
};

RfNode createVariableNode(String id, String title, [String type = 'tool']) => {
  'id': id,
  'position': {'x': 0, 'y': 0},
  'data': {'title': title, 'type': type, 'desc': ''},
};

RunVar createInputVar(String variable) => {
  'type': 'text-input',
  'label': variable,
  'variable': variable,
  'required': false,
};

Map<String, Object?> createRunTrace() => {
  'id': 'trace-1',
  'node_id': 'loop-node',
  'node_type': 'loop',
  'title': 'Loop',
  'status': 'succeeded',
  'metadata': {'iterator_length': 0, 'iterator_index': 0, 'loop_length': 2, 'loop_index': 1},
};

LoopSingleRunParams params({
  required Map<String, Object?> payload,
  required Map<String, Object?> runInputData,
  void Function(Map<String, Object?>)? setRunInputData,
  List<RunVar> Function(List<RunVar>)? toVarInputs,
  List<RunVar> Function(List<List<String>>)? varSelectorsToVarInputs,
  Map<String, Object?>? runResult,
  List<Object?> loopRunResult = const [],
  List<Object?>? traced,
}) => LoopSingleRunParams(
  id: 'loop-node',
  payload: payload,
  runInputData: runInputData,
  setRunInputData: setRunInputData ?? (_) {},
  toVarInputs: toVarInputs ?? (_) => const [],
  varSelectorsToVarInputs: varSelectorsToVarInputs ?? (_) => const [],
  childrenNodes: [
    createVariableNode('tool-a', 'Tool A'),
    createVariableNode('loop-node', 'Loop Node'),
    createVariableNode('inner-node', 'Inner Node'),
  ],
  beforeNodes: [createVariableNode('start-node', 'Start Node', 'start')],
  isNodeInLoop: (id) => id == 'inner-node',
  usedVars: (node) => switch (node['id']) {
    'tool-a' => [
      ['start-node', 'answer'],
    ],
    'loop-node' => [
      ['loop-node', 'item'],
    ],
    'inner-node' => [
      ['inner-node', 'secret'],
    ],
    _ => const [],
  },
  passToServerKey: (_, _) => 'passed_key',
  isSystemVar: (_) => false,
  formatTracing: (result) {
    traced?.add(result);
    return [
      {
        'id': 'formatted-node',
        'execution_metadata': {'loop_index': 9},
      },
    ];
  },
  runResult: runResult,
  loopRunResult: loopRunResult,
);

void main() {
  group('useSingleRunFormParams', () {
    test('should build single-run forms and filter out loop-local variables', () {
      final calls = <List<RunVar>>[];
      final result = params(
        payload: createLoopNode({
          'break_conditions': [
            {
              'id': 'condition-1',
              'varType': 'string',
              'variable_selector': ['tool-a', 'result'],
              'comparison_operator': '=',
              'value': '',
              'sub_variable_condition': {'logical_operator': 'and', 'conditions': <Object?>[]},
            },
          ],
          'loop_variables': [
            {
              'id': 'loop-variable-1',
              'label': 'Loop Value',
              'var_type': 'string',
              'value_type': 'variable',
              'value': ['start-node', 'answer'],
            },
          ],
        }),
        runInputData: {'question': 'hello'},
        toVarInputs: (vars) {
          calls.add(vars);
          return [for (final v in vars) createInputVar('${v['variable']}')];
        },
        varSelectorsToVarInputs: (_) => [
          createInputVar('tool-a.result'),
          createInputVar('tool-a.result'),
          createInputVar('start-node.answer'),
        ],
      );

      expect(calls.single, [containsPair('variable', 'start-node.answer')]);
      expect(result.forms, hasLength(1));
      expect(result.forms[0].inputs, [
        createInputVar('start-node.answer'),
        createInputVar('tool-a.result'),
        createInputVar('start-node.answer'),
      ]);
      expect(result.forms[0].values, {'question': 'hello'});
      expect(result.allVarObject, {
        'start-node.answer@@@tool-a@@@0': {'inSingleRunPassedKey': 'passed_key'},
      });
      expect(result.getDependentVars(), [
        ['start-node', 'answer'],
        ['tool-a', 'result'],
        ['start-node', 'answer'],
      ]);
    });

    test('should forward onChange and merge tracing metadata into node info', () {
      final calls = <Map<String, Object?>>[];
      final traced = <Object?>[];
      final runResult = createRunTrace();
      final result = params(
        payload: createLoopNode(),
        runInputData: const {},
        setRunInputData: calls.add,
        runResult: runResult,
        loopRunResult: [runResult],
        traced: traced,
      );

      result.forms[0].onChange({'retry': true});

      expect(calls.single, {'retry': true});
      final info = result.nodeInfo;
      expect(traced.single, [runResult]);
      expect(info, containsPair('id', 'formatted-node'));
      expect((info! as Map)['execution_metadata'], containsPair('loop_index', 9));
    });
  });
}
