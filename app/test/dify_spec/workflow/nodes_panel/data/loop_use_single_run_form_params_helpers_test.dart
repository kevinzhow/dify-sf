// dify-spec: web/app/components/workflow/nodes/loop/__tests__/use-single-run-form-params.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_single_run.dart';
import 'package:flutter_test/flutter_test.dart';

RfNode createNode(String id, String title, [String type = 'tool']) => {
  'id': id,
  'position': {'x': 0, 'y': 0},
  'data': {'title': title, 'desc': '', 'type': type},
};

RunVar createInputVar(String variable, [Object? label]) => {
  'type': 'text-input',
  'label': label ?? variable,
  'variable': variable,
  'required': false,
};

Map<String, Object?> createCondition([Map<String, Object?> overrides = const {}]) => {
  'id': 'condition-1',
  'varType': 'string',
  'variable_selector': ['tool-node', 'value'],
  'comparison_operator': '=',
  'value': '',
  ...overrides,
};

void main() {
  group('use-single-run-form-params helpers', () {
    test('should collect var selectors from conditions and nested cases', () {
      final nested = createCondition({
        'variable_selector': ['tool-node', 'value'],
        'sub_variable_condition': {
          'logical_operator': 'and',
          'conditions': [
            createCondition({
              'id': 'sub-condition-1',
              'variable_selector': ['start-node', 'answer'],
            }),
          ],
        },
      });

      expect(getVarSelectorsFromCondition(nested), [
        ['tool-node', 'value'],
        ['start-node', 'answer'],
      ]);
      expect(
        getVarSelectorsFromCase({
          'logical_operator': 'or',
          'conditions': [
            nested,
            createCondition({
              'id': 'condition-2',
              'variable_selector': ['other-node', 'result'],
            }),
          ],
        }),
        [
          ['tool-node', 'value'],
          ['start-node', 'answer'],
          ['other-node', 'result'],
        ],
      );
    });

    test('should copy input values and dedupe duplicate or invalid input vars', () {
      final source = {'question': 'hello', 'retry': true};

      final values = createInputVarValues(source);
      final deduped = dedupeInputVars([
        createInputVar('tool-node.value'),
        createInputVar('tool-node.value'),
        null,
        createInputVar('start-node.answer'),
      ]);

      expect(values, source);
      expect(identical(values, source), isFalse);
      expect(deduped, [createInputVar('tool-node.value'), createInputVar('start-node.answer')]);
    });

    test('should build used output vars and pass-to-server keys while filtering loop-local selectors', () {
      final startNode = createNode('start-node', 'Start Node', 'start');
      final sysNode = createNode('sys', 'System', 'start');
      final children = [
        createNode('tool-a', 'Tool A'),
        createNode('tool-b', 'Tool B'),
        createNode('current-node', 'Current Node'),
        createNode('inner-node', 'Inner Node'),
      ];
      final calls = <List<RunVar>>[];

      final result = buildUsedOutVars(
        childrenNodes: children,
        currentNodeId: 'current-node',
        canChooseVarNodes: [startNode, sysNode, ...children],
        isNodeInContainer: (id) => id == 'inner-node',
        toVarInputs: (vars) {
          calls.add(vars);
          return [for (final v in vars) createInputVar('${v['variable']}', v['label'])];
        },
        usedVars: (node) => switch (node['id']) {
          'tool-a' => [
            ['sys', 'files'],
          ],
          'tool-b' => [
            ['start-node', 'answer'],
            ['current-node', 'self'],
            ['inner-node', 'secret'],
          ],
          _ => const [],
        },
        passToServerKey: (_, s) => s[0] == 'sys' ? ['sys_files', 'sys_files_backup'] : 'answer_key',
        isSystemVar: (s) => s[0] == 'sys',
      );

      final sysLabel = {'nodeType': 'start', 'nodeName': 'System', 'variable': 'sys.files'};
      final answerLabel = {'nodeType': 'start', 'nodeName': 'Start Node', 'variable': 'answer'};
      expect(calls.single, [
        allOf(containsPair('variable', 'sys.files'), containsPair('label', sysLabel)),
        allOf(containsPair('variable', 'start-node.answer'), containsPair('label', answerLabel)),
      ]);
      expect(result.usedOutVars, [
        createInputVar('sys.files', sysLabel),
        createInputVar('start-node.answer', answerLabel),
      ]);
      expect(result.allVarObject, {
        ['sys.files', 'tool-a', 0].join(valueSelectorDelimiter): {'inSingleRunPassedKey': 'sys_files'},
        ['sys.files', 'tool-a', 1].join(valueSelectorDelimiter): {'inSingleRunPassedKey': 'sys_files_backup'},
        ['start-node.answer', 'tool-b', 0].join(valueSelectorDelimiter): {'inSingleRunPassedKey': 'answer_key'},
      });
    });

    test('should derive dependent vars from payload and filter current node references', () {
      final dependentVars = getDependentVarsFromLoopPayload(
        nodeId: 'loop-node',
        usedOutVars: [createInputVar('start-node.answer'), createInputVar('loop-node.internal')],
        breakConditions: [
          createCondition({
            'variable_selector': ['tool-node', 'value'],
            'sub_variable_condition': {
              'logical_operator': 'and',
              'conditions': [
                createCondition({
                  'id': 'sub-condition-1',
                  'variable_selector': ['loop-node', 'ignored'],
                }),
              ],
            },
          }),
        ],
        loopVariables: [
          {
            'id': 'loop-variable-1',
            'label': 'Loop Input',
            'var_type': 'string',
            'value_type': 'variable',
            'value': ['tool-node', 'next'],
          },
          {
            'id': 'loop-variable-2',
            'label': 'Constant',
            'var_type': 'string',
            'value_type': 'constant',
            'value': 'plain-text',
          },
        ],
      );

      expect(dependentVars, [
        ['start-node', 'answer'],
        ['tool-node', 'value'],
        ['tool-node', 'next'],
      ]);
    });
  });
}
