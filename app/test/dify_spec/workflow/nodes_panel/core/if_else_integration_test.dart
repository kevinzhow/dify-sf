// dify-spec: web/app/components/workflow/nodes/if-else/__tests__/integration.spec.tsx
//
// The condition controls are rendered as Dify's tests render them, with the real variable list instead of the
// mocked one. The panel runs over a document in an in-memory session; the node is the canvas card (IfElseBody), whose
// texts are not translated.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/basic_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/if_else_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'if_else_test_kit.dart';

const _start = VarGroup(nodeId: 'node-1', title: 'Start Node', vars: [PickerVar('score', 'number')]);

Map<String, Object?> _cond(String id, String op, String value) => {
  'id': id,
  'varType': 'string',
  'variable_selector': ['node-1', 'answer'],
  'comparison_operator': op,
  'value': value,
};

void main() {
  group('if-else path', () {
    group('Condition controls', () {
      testWidgets('should add a condition variable from the selector', (t) async {
        final calls = <List<Object?>>[];
        await renderIfElse(
          t,
          IfElseConditionAdd(
            caseId: 'case-1',
            variables: const [_start],
            onSelectVariable: (c, s, v) => calls.add([c, s, v.type]),
          ),
        );
        await t.tap(buttonNamed('workflow.nodes.ifElse.addCondition'));
        await settle(t);
        await t.tap(find.text('score'));
        await settle(t);
        expect(calls, [
          [
            'case-1',
            ['node-1', 'score'],
            'number',
          ],
        ]);
      });

      testWidgets('should switch operators and number input modes', (t) async {
        final selected = <String>[], kinds = <VarKindType>[], values = <String>[];
        await renderIfElse(
          t,
          Column(
            children: [
              IfElseConditionOperator(varType: 'string', value: 'contains', onSelect: selected.add),
              IfElseConditionNumberInput(
                value: '12',
                onNumberVarTypeChange: kinds.add,
                onValueChange: values.add,
                variables: const [],
                unit: '%',
              ),
            ],
          ),
        );
        await t.tap(buttonNamed('workflow.nodes.ifElse.comparisonOperator.contains'));
        await settle(t);
        await t.tap(find.text('workflow.nodes.ifElse.comparisonOperator.is'));
        await settle(t);
        await t.tap(buttonNamed('Constant'));
        await settle(t);
        await t.tap(find.text('Variable'));
        await settle(t);
        await t.enterText(find.widgetWithText(TextField, '12'), '42');
        expect(selected.first, 'is');
        expect(kinds.first, VarKindType.variable);
        expect(values, contains('42'));
      });

      testWidgets('should toggle logical operators for a case list with multiple conditions', (t) async {
        final toggles = <String>[];
        await renderIfElse(
          t,
          IfElseConditionList(
            caseId: 'case-1',
            caseItem: {
              'case_id': 'case-1',
              'logical_operator': 'and',
              'conditions': [_cond('condition-1', 'contains', 'hello'), _cond('condition-2', 'is', 'world')],
            },
            env: IfElseEnv(onToggleConditionLogicalOperator: toggles.add),
          ),
        );
        await t.tap(find.text('AND'));
        expect(toggles, ['case-1']);
      });
    });

    group('Display rendering', () {
      testWidgets('should render node cases, missing setup state, and else handles', (t) async {
        final node = difyNodes([
          difyNode('if-else-node', 'if-else', {
            'cases': [
              {
                'case_id': 'case-1',
                'logical_operator': 'and',
                'conditions': [
                  {
                    'id': 'condition-empty',
                    'varType': 'string',
                    'variable_selector': <Object?>[],
                    'comparison_operator': 'contains',
                    'value': '',
                  },
                ],
              },
              {
                'case_id': 'case-2',
                'logical_operator': 'or',
                'conditions': [
                  {
                    'id': 'condition-ready',
                    'varType': 'boolean',
                    'variable_selector': ['node-1', 'passed'],
                    'comparison_operator': 'is',
                    'value': false,
                  },
                ],
              },
            ],
          }),
        ]).single;
        final ctx = BodyContext(node, (_) => null);
        await renderIfElse(t, Builder(builder: (c) => const IfElseBody().build(c, ctx)));
        expect(find.text('IF'), findsOneWidget);
        expect(find.text('ELIF'), findsOneWidget);
        expect(find.text('Condition NOT setup'), findsOneWidget);
        expect(find.text('False'), findsOneWidget);
        expect(find.text('ELSE'), findsOneWidget);
        expect(const IfElseBody().sources(ctx).keys, ['case-1', 'case-2', 'false']);
      });
    });

    group('Panel integration', () {
      testWidgets('should add a case from the panel action and render else description', (t) async {
        final p = await openIfElsePanel(
          t,
          difyNodes([
            difyNode('if-else-node', 'if-else', {'cases': <Object?>[]}),
          ]),
          'if-else-node',
        );
        await t.tap(buttonNamed('ELIF'));
        await settle(t);
        expect(p.data['cases'], [
          {'case_id': isA<String>(), 'logical_operator': 'and', 'conditions': <Object?>[]},
        ]);
        expect(find.text('workflow.nodes.ifElse.elseDescription'), findsOneWidget);
        await p.dispose(t);
      });
    });
  });

  group('if-else panel over the document', () {
    final start = difyNode('start', 'start', {
      'variables': [
        {'variable': 'answer', 'type': 'text-input', 'label': 'Answer', 'required': true},
        {'variable': 'score', 'type': 'number', 'label': 'Score', 'required': true},
      ],
    });
    Map<String, Object?> ifElse(List<Object?> cases) => difyNode('if', 'if-else', {'cases': cases});

    testWidgets('adds a condition with the first operator of its type, then removes a case with its edges', (t) async {
      final nodes = difyNodes([
        start,
        ifElse([
          {'case_id': 'true', 'logical_operator': 'and', 'conditions': <Object?>[]},
          {'case_id': 'c2', 'logical_operator': 'and', 'conditions': <Object?>[]},
        ]),
        difyNode('end', 'end', {'outputs': <Object?>[]}),
      ]);
      final p = await openIfElsePanel(
        t,
        nodes,
        'if',
        edges: [
          const Edge(id: 'e0', source: 'start', target: 'if'),
          const Edge(id: 'e1', source: 'if', sourceHandle: 'c2', target: 'end'),
        ],
      );
      expect(find.text('ELIF'), findsWidgets);
      expect(find.text('CASE2'), findsOneWidget);
      await t.tap(buttonNamed('workflow.nodes.ifElse.addCondition').first);
      await settle(t);
      await t.tap(find.text('score').last);
      await settle(t);
      final cond = ((p.data['cases']! as List).first as Map)['conditions'] as List;
      expect(cond.single, allOf(containsPair('comparison_operator', '='), containsPair('varType', 'number')));
      expect(find.text('Constant'), findsOneWidget);

      await t.tap(find.text('common.operation.remove').last);
      await settle(t);
      expect([for (final c in p.data['cases']! as List) (c as Map)['case_id']], ['true']);
      expect(p.h.doc.edges.containsKey('e1'), isFalse);
      await p.dispose(t);
    });

    testWidgets('a boolean value is chosen with True / False and an empty-related operator hides the value', (t) async {
      final nodes = difyNodes([
        start,
        ifElse([
          {
            'case_id': 'true',
            'logical_operator': 'and',
            'conditions': [
              {
                'id': 'b',
                'varType': 'boolean',
                'variable_selector': ['start', 'flag'],
                'comparison_operator': 'is',
                'value': false,
              },
              {
                'id': 's',
                'varType': 'string',
                'variable_selector': ['start', 'answer'],
                'comparison_operator': 'empty',
                'value': '',
              },
            ],
          },
        ]),
      ]);
      final p = await openIfElsePanel(t, nodes, 'if', edges: chain(['start', 'if']));
      expect(find.text('workflow.nodes.ifElse.enterValue'), findsNothing);
      await t.tap(find.text('True'));
      await settle(t);
      final conds = ((p.data['cases']! as List).first as Map)['conditions'] as List;
      expect((conds.first as Map)['value'], isTrue);
      await t.tap(find.text('AND'));
      await settle(t);
      expect(((p.data['cases']! as List).first as Map)['logical_operator'], 'or');
      await p.dispose(t);
    });
  });
}
