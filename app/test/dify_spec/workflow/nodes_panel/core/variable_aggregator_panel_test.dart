// dify-spec: web/app/components/workflow/nodes/variable-assigner/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/variable-assigner/__tests__/node.spec.tsx
//
// The panel over a document in an in-memory session (Dify mocks use-config; here its effects are read back from the
// document). The node case renders the canvas card (cards/bodies VariableAggregatorBody).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/data_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/variable_aggregator_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'variable_aggregator_helpers.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

typedef Json = Map<String, Object?>;

Json createData([Json overrides = const {}]) => {
  'output_type': 'string',
  'variables': [
    ['source-node', 'rootVar'],
  ],
  'advanced_settings': {
    'group_enabled': true,
    'groups': [
      {
        'groupId': 'group-1',
        'group_name': 'Group1',
        'output_type': 'string',
        'variables': [
          ['source-node', 'groupVar'],
        ],
      },
      {'groupId': 'group-2', 'group_name': 'Group2', 'output_type': 'number', 'variables': <Object?>[]},
    ],
  },
  ...overrides,
};

List<Node> nodesWith(Json data) => difyNodes([
  difyNode('source-node', 'start', {
    'variables': [
      {'variable': 'rootVar', 'label': 'rootVar', 'type': 'text-input', 'required': true},
      {'variable': 'groupVar', 'label': 'groupVar', 'type': 'text-input', 'required': true},
    ],
  }, 'Source'),
  difyNode('assigner-node', 'variable-assigner', data, 'Variable Assigner'),
  difyNode('end', 'end', {
    'outputs': [
      {
        'variable': 'out',
        'value_selector': ['assigner-node', 'Group2', 'output'],
      },
    ],
  }),
]);

/// Dify's test translator, with the confirm dialog's buttons named as the spec's mock names them (the keys are
/// wider than the dialog in the test font).
class _ConfirmNames extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => switch ('$ns.$key') {
    'common.operation.cancel' => 'cancel-remove',
    'common.operation.confirm' => 'confirm-remove',
    _ => super.t(ns, key, params),
  };
}

String items(VarGroupItem w) => '${w.payload['group_name'] ?? 'root'}:${w.payload['output_type']}:${w.groupEnabled}';

void main() {
  group('variable-assigner/panel', () {
    testWidgets('renders grouped panels, output vars, and confirm actions when aggregation is enabled', (t) async {
      final p = await openAggregatorPanel(
        t,
        nodesWith(createData()),
        'assigner-node',
        edges: chain(['source-node', 'assigner-node', 'end']),
      );
      DifyI18n.current = _ConfirmNames();
      expect(
        [for (final w in t.widgetList<VarGroupItem>(find.byType(VarGroupItem))) items(w)],
        [
          'Group1:string:true',
          'Group2:number:true',
        ],
      );
      // The output variables section opens on a click (FieldCollapse starts collapsed).
      await t.tap(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().toLowerCase() == 'workflow.nodes.common.outputvars',
        ),
      );
      await settle(t);
      for (final (name, type) in [('Group1', 'string'), ('Group2', 'number')]) {
        final v = t.widget<VarItem>(find.byWidgetPredicate((w) => w is VarItem && w.name == '$name.output'));
        expect(v.type, type);
        expect(v.description, startsWith('workflow.nodes.variableAssigner.outputVars.varDescribe'));
      }

      await t.tap(find.text('workflow.nodes.variableAssigner.addGroup'));
      await settle(t);
      expect(
        [for (final g in (p.data['advanced_settings']! as Map)['groups'] as List) (g as Map)['group_name']],
        [
          'Group1',
          'Group2',
          'Group3',
        ],
      );

      // Group2's output is used downstream: turning grouping off asks first.
      await t.tap(find.byType(DifySwitch));
      await settle(t);
      await t.tap(find.text('cancel-remove'));
      await settle(t);
      expect((p.data['advanced_settings']! as Map)['group_enabled'], isTrue);

      await t.tap(find.byType(DifySwitch));
      await settle(t);
      await t.tap(find.text('confirm-remove'));
      await settle(t);
      expect((p.data['advanced_settings']! as Map)['group_enabled'], isFalse);
      expect(p.data['variables'].toString(), '[[source-node, groupVar]]');
      expect(((difyDataOf(p.h['end']!)['outputs']! as List).single as Map)['value_selector'], isEmpty);
      await p.dispose(t);
    });

    testWidgets('renders a single root group and hides output vars when aggregation is disabled', (t) async {
      final p = await openAggregatorPanel(
        t,
        nodesWith(
          createData({
            'advanced_settings': {'group_enabled': false, 'groups': <Object?>[]},
          }),
        ),
        'assigner-node',
      );
      expect([for (final w in t.widgetList<VarGroupItem>(find.byType(VarGroupItem))) items(w)], ['root:string:false']);
      expect(findTitle('workflow.nodes.variableAssigner.aggregationGroup'), findsOneWidget);
      expect(find.text('Group1.output'), findsNothing);
      await p.dispose(t);
    });
  });

  group('variable-assigner/node', () {
    testWidgets('renders grouped node cards when aggregation is enabled', (t) async {
      final nodes = nodesWith(createData());
      final byId = {for (final n in nodes) n.id: n};
      final ctx = BodyContext(byId['assigner-node']!, (id) => byId[id], start: byId['source-node']);
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                child: Builder(builder: (c) => const VariableAggregatorBody().build(c, ctx)),
              ),
            ),
          ),
        ),
      );
      expect(find.text('GROUP1'), findsOneWidget);
      expect(find.text('GROUP2'), findsOneWidget);
      expect(find.text('string'), findsOneWidget);
      expect(find.text('number'), findsOneWidget);
      expect(find.text('groupVar'), findsOneWidget);
      expect(find.text('rootVar'), findsNothing);
    });
  });
}
