// dify-spec: web/app/components/workflow/nodes/if-else/__tests__/use-config.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/if_else_utils.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

Json createInputs() => {
  'title': 'If/Else',
  'desc': '',
  'type': 'if-else',
  'cases': [
    {
      'case_id': 'case-1',
      'logical_operator': 'and',
      'conditions': [
        {
          'id': 'condition-1',
          'varType': 'string',
          'variable_selector': ['node', 'value'],
          'comparison_operator': 'contains',
          'value': '',
        },
      ],
    },
  ],
  '_targetBranches': [
    {'id': 'case-1', 'name': 'Case 1'},
    {'id': 'false', 'name': 'Else'},
  ],
};

List<Json> _cases(Json x) => [for (final c in x['cases']! as List) c as Json];
List<Json> _conds(Json x, [int i = 0]) => [for (final c in _cases(x)[i]['conditions']! as List) c as Json];
Json _sub(Json x) => _conds(x).first['sub_variable_condition']! as Json;

void main() {
  group('if-else use-config helpers', () {
    test('filters vars and derives file attribute flags', () {
      expect(filterAllVars(), isTrue);
      expect(filterNumberVars(const PickerVar('a', 'number')), isTrue);
      expect(filterNumberVars(const PickerVar('a', 'string')), isFalse);
      expect(getVarsIsVarFileAttribute(createInputs()['cases'], (selector) => selector[1] == 'value'), {
        'condition-1': true,
      });
    });

    test('adds, removes and sorts cases while keeping target branches aligned', () {
      final added = addCase(createInputs());
      expect(_cases(added), hasLength(2));
      expect([for (final b in added['_targetBranches']! as List) (b as Map)['id']], contains('false'));

      final removed = removeCase(added, 'case-1');
      expect(_cases(removed).any((c) => c['case_id'] == 'case-1'), isFalse);

      final sorted = sortCases(createInputs(), [
        {'id': 'display-2', 'case_id': 'case-2', 'logical_operator': 'or', 'conditions': <Object?>[]},
        {'id': 'display-1', 'case_id': 'case-1', 'logical_operator': 'and', 'conditions': <Object?>[]},
      ]);
      expect([for (final c in _cases(sorted)) c['case_id']], ['case-2', 'case-1']);
      expect([for (final b in sorted['_targetBranches']! as List) (b as Map)['id']], ['case-2', 'case-1', 'false']);
    });

    test('adds, updates, toggles and removes conditions and sub-conditions', () {
      final withCondition = addCondition(
        inputs: createInputs(),
        caseId: 'case-1',
        valueSelector: ['node', 'flag'],
        varType: 'boolean',
        isVarFileAttribute: false,
      );
      expect(_conds(withCondition), hasLength(2));
      expect(_conds(withCondition)[1], containsPair('value', false));
      expect(_conds(withCondition)[1], containsPair('variable_selector', ['node', 'flag']));

      final updatedCondition = updateCondition(withCondition, 'case-1', 'condition-1', {
        'id': 'condition-1',
        'value': 'next',
        'comparison_operator': '=',
      });
      expect(
        _conds(updatedCondition)[0],
        allOf(containsPair('value', 'next'), containsPair('comparison_operator', '=')),
      );

      final toggled = toggleConditionLogicalOperator(updatedCondition, 'case-1');
      expect(_cases(toggled)[0]['logical_operator'], 'or');

      final withSubCondition = addSubVariableCondition(toggled, 'case-1', 'condition-1', 'name');
      final firstSub = (_sub(withSubCondition)['conditions']! as List).first as Json;
      expect(firstSub, allOf(containsPair('key', 'name'), containsPair('value', '')));

      final firstSubConditionId = firstSub['id']! as String;
      expect(firstSubConditionId, isNotEmpty);
      final updatedSubCondition = updateSubVariableCondition(
        withSubCondition,
        'case-1',
        'condition-1',
        firstSubConditionId,
        {'key': 'size', 'comparison_operator': '>', 'value': '10'},
      );
      expect(
        (_sub(updatedSubCondition)['conditions']! as List).first,
        allOf(containsPair('key', 'size'), containsPair('value', '10')),
      );

      final toggledSub = toggleSubVariableConditionLogicalOperator(updatedSubCondition, 'case-1', 'condition-1');
      expect(_sub(toggledSub)['logical_operator'], 'or');

      final removedSub = removeSubVariableCondition(toggledSub, 'case-1', 'condition-1', firstSubConditionId);
      expect(_sub(removedSub)['conditions'], isEmpty);

      final removedCondition = removeCondition(removedSub, 'case-1', 'condition-1');
      expect(_conds(removedCondition).any((c) => c['id'] == 'condition-1'), isFalse);
    });

    test('keeps inputs unchanged when guard branches short-circuit helper updates', () {
      final unchangedWithoutCases = addCase({...createInputs(), 'cases': null});
      expect(unchangedWithoutCases['cases'], isNull);

      final withoutTargetBranches = addCase({...createInputs(), '_targetBranches': null});
      expect(withoutTargetBranches['_targetBranches'], isNull);

      final withoutElseBranch = addCase({
        ...createInputs(),
        '_targetBranches': [
          {'id': 'case-1', 'name': 'Case 1'},
        ],
      });
      expect(withoutElseBranch['_targetBranches'], [
        {'id': 'case-1', 'name': 'Case 1'},
      ]);

      expect(addSubVariableCondition(createInputs(), 'case-1', 'missing-condition', 'name'), createInputs());
      expect(removeSubVariableCondition(createInputs(), 'case-1', 'condition-1', 'missing-sub'), createInputs());
      expect(
        addCondition(
          inputs: createInputs(),
          caseId: 'missing-case',
          valueSelector: ['node', 'value'],
          varType: 'string',
          isVarFileAttribute: false,
        ),
        createInputs(),
      );
      expect(toggleConditionLogicalOperator(createInputs(), 'missing-case'), createInputs());
      expect(toggleSubVariableConditionLogicalOperator(createInputs(), 'case-1', 'condition-1'), createInputs());
    });
  });
}
