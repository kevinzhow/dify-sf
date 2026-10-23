// dify-spec: web/app/components/workflow/nodes/loop/__tests__/use-config.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_utils.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Loop',
  'desc': '',
  'type': 'loop',
  'start_node_id': 'start-node',
  'loop_id': 'loop-node',
  'logical_operator': 'and',
  'break_conditions': [
    {
      'id': 'condition-1',
      'varType': 'string',
      'variable_selector': ['node-1', 'answer'],
      'comparison_operator': CmpOp.contains,
      'value': 'hello',
    },
  ],
  'loop_count': 3,
  'error_handle_mode': 'continue-on-error',
  'loop_variables': [
    {'id': 'loop-var-1', 'label': 'item', 'var_type': 'string', 'value_type': 'constant', 'value': 'value'},
  ],
  ...overrides,
};

void main() {
  group('useConfig', () {
    late List<Map<String, Object?>> setInputs;
    LoopConfig config(Map<String, Object?> payload) =>
        LoopConfig(id: 'loop-node', inputs: payload, setInputs: setInputs.add, uuid: () => 'generated-id');

    setUp(() => setInputs = []);

    testWidgets('should expose derived outputs and input variable filtering', (t) async {
      final h = await Harness.start(t, [difyNode('loop-node', createPayload())]);
      final c = LoopConfig.of(NodePanelProps(node: h['loop-node']!, controller: h.controller, actions: h.actions()));

      expect(c.readOnly, isFalse);
      // The loop's own variables (toNodeOutputVars([loop, ...children], …)).
      expect(c.childrenNodeVars.vars.first.nodeId, 'loop-node');
      expect(c.loopChildrenNodes, hasLength(1));
      expect(c.filterInputVar(const PickerVar('v', 'array[number]')), isTrue);
      expect(c.filterInputVar(const PickerVar('v', 'string')), isFalse);
      await h.dispose(t);
    });

    test('should update error mode, break conditions and logical operators', () {
      config(createPayload())
        ..changeErrorResponseMode('terminated')
        ..handleAddCondition(['node-1', 'score'], const PickerVar('score', 'number'))
        ..handleUpdateCondition('condition-1', {
          'id': 'condition-1',
          'varType': 'number',
          'variable_selector': ['node-1', 'score'],
          'comparison_operator': CmpOp.largerThan,
          'value': '3',
        })
        ..handleRemoveCondition('condition-1')
        ..handleToggleConditionLogicalOperator();

      List<Object?> conditionsOf(Map<String, Object?> i) => i['break_conditions']! as List;
      expect(setInputs, contains(containsPair('error_handle_mode', 'terminated')));
      expect(
        setInputs.any(
          (i) => conditionsOf(i).any(
            (c) =>
                (c as Map)['id'] == 'generated-id' &&
                c['varType'] == 'number' &&
                '${c['variable_selector']}' == '[node-1, score]',
          ),
        ),
        isTrue,
      );
      expect(
        setInputs.any(
          (i) => conditionsOf(i).any(
            (c) =>
                (c as Map)['varType'] == 'number' && c['comparison_operator'] == CmpOp.largerThan && c['value'] == '3',
          ),
        ),
        isTrue,
      );
      expect(setInputs, contains(containsPair('logical_operator', 'or')));
    });

    test('should manage sub-variable conditions and loop variables', () {
      config(
          createPayload({
            'break_conditions': [
              {
                'id': 'condition-1',
                'varType': 'file',
                'variable_selector': ['node-1', 'files'],
                'comparison_operator': CmpOp.contains,
                'value': '',
                'sub_variable_condition': {
                  'logical_operator': 'and',
                  'conditions': [
                    {
                      'id': 'sub-1',
                      'key': 'name',
                      'varType': 'string',
                      'comparison_operator': CmpOp.contains,
                      'value': '',
                    },
                  ],
                },
              },
            ],
          }),
        )
        ..handleAddSubVariableCondition('condition-1', 'name')
        ..handleUpdateSubVariableCondition('condition-1', 'sub-1', {
          'id': 'sub-1',
          'key': 'size',
          'varType': 'string',
          'comparison_operator': CmpOp.contains,
          'value': '2',
        })
        ..handleRemoveSubVariableCondition('condition-1', 'sub-1')
        ..handleToggleSubVariableConditionLogicalOperator('condition-1')
        ..handleUpdateLoopCount(5)
        ..handleAddLoopVariable()
        ..handleRemoveLoopVariable('loop-var-1')
        ..handleUpdateLoopVariable('loop-var-1', {'label': 'updated'});

      Map<String, Object?> subOf(Map<String, Object?> i) =>
          ((i['break_conditions']! as List).single as Map)['sub_variable_condition']! as Map<String, Object?>;
      expect(
        setInputs.any(
          (i) => (subOf(i)['conditions']! as List).any((s) => (s as Map)['id'] == 'generated-id' && s['key'] == 'name'),
        ),
        isTrue,
      );
      expect(setInputs.any((i) => subOf(i)['logical_operator'] == 'or'), isTrue);
      expect(setInputs, contains(containsPair('loop_count', 5)));
      List<Object?> varsOf(Map<String, Object?> i) => i['loop_variables']! as List;
      expect(
        setInputs.any(
          (i) => varsOf(i).any((v) => (v as Map)['id'] == 'generated-id' && v['value_type'] == 'constant'),
        ),
        isTrue,
      );
      expect(
        setInputs.any(
          (i) =>
              varsOf(i).length == 1 &&
              (varsOf(i).single as Map)['id'] == 'generated-id' &&
              (varsOf(i).single as Map)['value_type'] == 'constant',
        ),
        isTrue,
      );
    });
  });
}
