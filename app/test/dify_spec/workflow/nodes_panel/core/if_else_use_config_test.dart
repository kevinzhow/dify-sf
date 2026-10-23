// dify-spec: web/app/components/workflow/nodes/if-else/__tests__/use-config.spec.tsx
//
// use-config.ts is IfElseConfig: the mocked node CRUD, edge interactions, React Flow internals and file-attribute
// check are its constructor's callbacks; the available variables are the panel's scope (IfElseEnv).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/if_else_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

Json createPayload([Json overrides = const {}]) => {
  'title': 'If Else',
  'desc': '',
  'type': 'if-else',
  'isInIteration': false,
  'isInLoop': false,
  'cases': [
    {
      'case_id': 'case-1',
      'logical_operator': 'and',
      'conditions': [
        {
          'id': 'condition-1',
          'varType': 'string',
          'variable_selector': ['node-1', 'answer'],
          'comparison_operator': 'contains',
          'value': 'hello',
        },
      ],
    },
  ],
  '_targetBranches': [
    {'id': 'case-1', 'name': 'IF'},
    {'id': 'false', 'name': 'ELSE'},
  ],
  ...overrides,
};

/// The calls of the mocked `setInputs`, `handleEdgeDeleteByDeleteBranch` and `updateNodeInternals`; like the mocked
/// useNodeCrud, the inputs stay [payload].
({IfElseConfig config, List<Json> setInputs, List<List<String>> deletes, List<String> internals}) useConfig(
  String id,
  Json payload,
) {
  final setInputs = <Json>[];
  final deletes = <List<String>>[];
  final internals = <String>[];
  final config = IfElseConfig(
    nodeId: id,
    inputs: () => payload,
    setInputs: setInputs.add,
    readOnly: false,
    deleteBranch: (node, caseId) => deletes.add([node, caseId]),
    updateNodeInternals: internals.add,
    isVarFileAttribute: (_) => false,
    uuid: () => 'generated-id',
  );
  return (config: config, setInputs: setInputs, deletes: deletes, internals: internals);
}

List<Json> _cases(Json x) => [for (final c in x['cases']! as List) c as Json];
Iterable<Json> _conds(Json x) => _cases(x).expand((c) => [for (final x in c['conditions']! as List) x as Json]);
Iterable<Json> _subs(Json x) => _conds(x).expand(
  (c) => [for (final s in ((c['sub_variable_condition'] as Json?)?['conditions'] as List?) ?? const []) s as Json],
);

void main() {
  group('useConfig', () {
    test('should expose derived vars and file-attribute flags', () {
      final r = useConfig('if-node', createPayload());
      final scope = VarScope(
        vars: const [
          VarGroup(
            nodeId: 'node-1',
            title: 'Start',
            vars: [PickerVar('answer', 'string'), PickerVar('score', 'number')],
          ),
        ],
      );
      final env = IfElseEnv.of(r.config, scope);
      expect(r.config.readOnly, isFalse);
      expect(r.config.filterVar(), isTrue);
      expect(r.config.filterNumberVar(const PickerVar('a', 'number')), isTrue);
      expect(r.config.filterNumberVar(const PickerVar('a', 'string')), isFalse);
      expect(env.scope.vars, hasLength(1));
      expect(env.numberVars, hasLength(1));
      expect(env.numberVars.single.vars.single.variable, 'score');
      expect(r.config.varsIsVarFileAttribute, {'condition-1': false});
    });

    test('should manage cases and conditions', () {
      final r = useConfig('if-node', createPayload());
      final c = r.config;
      c.handleAddCase();
      c.handleRemoveCase('generated-id');
      c.handleAddCondition('case-1', ['node-1', 'score'], const PickerVar('score', 'number'));
      c.handleUpdateCondition('case-1', 'condition-1', {
        'id': 'condition-1',
        'varType': 'number',
        'variable_selector': ['node-1', 'score'],
        'comparison_operator': '>',
        'value': '3',
      });
      c.handleRemoveCondition('case-1', 'condition-1');
      c.handleToggleConditionLogicalOperator('case-1');
      c.handleSortCase([
        {'id': 'sortable-1', 'case_id': 'case-1', 'logical_operator': 'or', 'conditions': <Object?>[]},
      ]);

      expect(
        r.setInputs.any((x) => _cases(x).any((c) => c['case_id'] == 'generated-id' && c['logical_operator'] == 'and')),
        isTrue,
      );
      expect(
        r.setInputs.any(
          (x) =>
              _cases(x).length == 1 &&
              _cases(x).single['case_id'] == 'case-1' &&
              _cases(x).single['logical_operator'] == 'or' &&
              x['_targetBranches'].toString() ==
                  [
                    {'id': 'case-1', 'name': 'IF'},
                    {'id': 'false', 'name': 'ELSE'},
                  ].toString(),
        ),
        isTrue,
      );
      expect(
        r.setInputs.any(
          (x) =>
              _conds(x).any((c) => c['id'] == 'generated-id' && c['variable_selector'].toString() == '[node-1, score]'),
        ),
        isTrue,
      );
      expect(
        r.setInputs.any(
          (x) => _conds(x).any((c) => c['id'] == 'condition-1' && c['comparison_operator'] == '>' && c['value'] == '3'),
        ),
        isTrue,
      );
      expect(r.setInputs.any((x) => _cases(x).any((c) => c['logical_operator'] == 'or')), isTrue);
      expect(r.deletes, [
        ['if-node', 'generated-id'],
      ]);
      expect(r.internals, ['if-node']);
    });

    test('should manage sub-variable conditions', () {
      final payload = createPayload({
        'cases': [
          {
            'case_id': 'case-1',
            'logical_operator': 'and',
            'conditions': [
              {
                'id': 'condition-1',
                'varType': 'file',
                'variable_selector': ['node-1', 'files'],
                'comparison_operator': 'exists',
                'value': '',
                'sub_variable_condition': {
                  'case_id': 'sub-case-1',
                  'logical_operator': 'and',
                  'conditions': [
                    {'id': 'sub-1', 'key': 'name', 'varType': 'string', 'comparison_operator': 'contains', 'value': ''},
                  ],
                },
              },
            ],
          },
        ],
      });
      final r = useConfig('if-node', payload);
      r.config.handleAddSubVariableCondition('case-1', 'condition-1', 'name');
      r.config.handleUpdateSubVariableCondition('case-1', 'condition-1', 'sub-1', {
        'id': 'sub-1',
        'key': 'size',
        'varType': 'string',
        'comparison_operator': 'is',
        'value': '2',
      });
      r.config.handleRemoveSubVariableCondition('case-1', 'condition-1', 'sub-1');
      r.config.handleToggleSubVariableConditionLogicalOperator('case-1', 'condition-1');

      expect(r.setInputs.any((x) => _subs(x).any((s) => s['id'] == 'generated-id' && s['key'] == 'name')), isTrue);
      expect(
        r.setInputs.any((x) => _subs(x).any((s) => s['id'] == 'sub-1' && s['key'] == 'size' && s['value'] == '2')),
        isTrue,
      );
      expect(
        r.setInputs.any(
          (x) => _conds(x).any((c) => (c['sub_variable_condition'] as Json?)?['logical_operator'] == 'or'),
        ),
        isTrue,
      );
    });
  });
}
