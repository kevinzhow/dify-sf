// dify-spec: web/app/components/workflow/nodes/loop/__tests__/use-config.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_utils.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> createInputs([Map<String, Object?> overrides = const {}]) => {
  'title': 'Loop',
  'desc': '',
  'type': 'loop',
  'start_node_id': 'start-node',
  'loop_count': 3,
  'error_handle_mode': 'terminated',
  'logical_operator': 'and',
  'break_conditions': <Object?>[],
  'loop_variables': <Object?>[],
  ...overrides,
};

/// mockUuid.mockReturnValueOnce(...).
String Function() uuids(List<String> ids) {
  var i = 0;
  return () => ids[i++];
}

List<Map<String, Object?>> conditions(Map<String, Object?> inputs) =>
    (inputs['break_conditions']! as List).cast<Map<String, Object?>>();

Map<String, Object?> sub(Map<String, Object?> inputs) =>
    (conditions(inputs)[0]['sub_variable_condition']! as Map).cast<String, Object?>();

void main() {
  group('loop use-config helpers', () {
    group('canUseAsLoopInput', () {
      test('should accept %s loop inputs', () {
        for (final type in const ['array', 'array[string]', 'array[number]', 'array[object]', 'array[file]']) {
          expect(canUseAsLoopInput(type), isTrue, reason: type);
        }
      });

      test('should reject non-array loop inputs', () {
        expect(canUseAsLoopInput('string'), isFalse);
      });
    });

    test('should update error handling, loop count and logical operators immutably', () {
      final inputs = createInputs();

      final withMode = updateErrorHandleMode(inputs, 'continue-on-error');
      final withCount = updateLoopCount(withMode, 6);
      final toggled = toggleConditionOperator(withCount);
      final toggledBack = toggleConditionOperator(toggled);

      expect(withMode['error_handle_mode'], 'continue-on-error');
      expect(withCount['loop_count'], 6);
      expect(toggled['logical_operator'], 'or');
      expect(toggledBack['logical_operator'], 'and');
      expect(inputs['error_handle_mode'], 'terminated');
      expect(inputs['loop_count'], 3);
    });

    test('should add, update and remove break conditions for regular and file attributes', () {
      final uuid = uuids(['condition-1', 'condition-2']);
      final withBooleanCondition = addBreakCondition(
        inputs: createInputs({'break_conditions': null}),
        valueSelector: ['tool-node', 'enabled'],
        type: 'boolean',
        isVarFileAttribute: false,
        uuid: uuid,
      );
      final withFileCondition = addBreakCondition(
        inputs: withBooleanCondition,
        valueSelector: ['tool-node', 'file', 'transfer_method'],
        type: 'file',
        isVarFileAttribute: true,
        uuid: uuid,
      );
      final updated = updateBreakCondition(withFileCondition, 'condition-2', {
        'id': 'condition-2',
        'varType': 'file',
        'key': 'transfer_method',
        'variable_selector': ['tool-node', 'file', 'transfer_method'],
        'comparison_operator': CmpOp.notIn,
        'value': ['file'],
      });
      final removed = removeBreakCondition(updated, 'condition-1');

      expect(conditions(withBooleanCondition), [
        allOf(
          containsPair('id', 'condition-1'),
          containsPair('varType', 'boolean'),
          containsPair('comparison_operator', CmpOp.is_),
          containsPair('value', false),
        ),
      ]);
      expect(
        conditions(withFileCondition)[1],
        allOf(
          containsPair('id', 'condition-2'),
          containsPair('varType', 'file'),
          containsPair('comparison_operator', CmpOp.in_),
          containsPair('value', ''),
        ),
      );
      expect(
        conditions(updated)[1],
        allOf(containsPair('comparison_operator', CmpOp.notIn), containsPair('value', ['file'])),
      );
      expect(conditions(removed), [containsPair('id', 'condition-2')]);
    });

    test('should manage nested sub-variable conditions and ignore missing targets', () {
      final uuid = uuids(['sub-condition-1', 'sub-condition-2']);
      final inputs = createInputs({
        'break_conditions': [
          {
            'id': 'condition-1',
            'varType': 'file',
            'key': 'name',
            'variable_selector': ['tool-node', 'file'],
            'comparison_operator': CmpOp.contains,
            'value': '',
          },
        ],
      });

      final untouched = addSubVariableCondition(inputs, 'missing-condition', null, uuid);
      final withKeyed = addSubVariableCondition(inputs, 'condition-1', 'transfer_method', uuid);
      final withDefaultKey = addSubVariableCondition(withKeyed, 'condition-1', null, uuid);
      final updated = updateSubVariableCondition(withDefaultKey, 'condition-1', 'sub-condition-1', {
        'id': 'sub-condition-1',
        'key': 'transfer_method',
        'varType': 'string',
        'comparison_operator': CmpOp.notIn,
        'value': ['remote_url'],
      });
      final toggled = toggleSubVariableConditionOperator(updated, 'condition-1');
      final removed = removeSubVariableCondition(toggled, 'condition-1', 'sub-condition-1');
      final unchangedAfterMissingRemove = removeSubVariableCondition(removed, 'missing-condition', 'sub-condition-2');

      expect(untouched, inputs);
      expect(sub(withKeyed), {
        'logical_operator': 'and',
        'conditions': [
          {
            'id': 'sub-condition-1',
            'key': 'transfer_method',
            'varType': 'string',
            'comparison_operator': CmpOp.in_,
            'value': '',
          },
        ],
      });
      expect((sub(withDefaultKey)['conditions']! as List)[1], {
        'id': 'sub-condition-2',
        'key': '',
        'varType': 'string',
        'comparison_operator': null,
        'value': '',
      });
      expect(
        (sub(updated)['conditions']! as List)[0],
        allOf(containsPair('comparison_operator', CmpOp.notIn), containsPair('value', ['remote_url'])),
      );
      expect(sub(toggled)['logical_operator'], 'or');
      expect(sub(removed)['conditions'], [containsPair('id', 'sub-condition-2')]);
      expect(unchangedAfterMissingRemove, removed);
    });

    test('should add, update and remove loop variables without mutating the source inputs', () {
      final inputs = createInputs({'loop_variables': null});
      final added = addLoopVariable(inputs, uuids(['loop-variable-1']));
      final updated = updateLoopVariable(added, 'loop-variable-1', {
        'label': 'Loop Value',
        'value_type': 'variable',
        'value': ['tool-node', 'result'],
      });
      final unchanged = updateLoopVariable(updated, 'missing-loop-variable', {'label': 'ignored'});
      final removed = removeLoopVariable(unchanged, 'loop-variable-1');

      expect(added['loop_variables'], [
        {'id': 'loop-variable-1', 'label': '', 'var_type': 'string', 'value_type': 'constant', 'value': ''},
      ]);
      expect(updated['loop_variables'], [
        {
          'id': 'loop-variable-1',
          'label': 'Loop Value',
          'var_type': 'string',
          'value_type': 'variable',
          'value': ['tool-node', 'result'],
        },
      ]);
      expect(unchanged, updated);
      expect(removed['loop_variables'], isEmpty);
      expect(inputs['loop_variables'], isNull);
    });
  });
}
