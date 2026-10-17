// The Loop panel on a document: loop variables, termination conditions and the maximum loop count write the
// node's data.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_conditions.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> loop([Map<String, Object?> overrides = const {}]) => {
  'type': 'loop',
  'title': 'Loop',
  'start_node_id': 'loop-nodestart',
  'break_conditions': <Object?>[],
  'loop_count': 10,
  'logical_operator': 'and',
  ...overrides,
};

Future<Harness> start(WidgetTester t, [Map<String, Object?> data = const {}]) =>
    Harness.start(t, [difyNode('loop-node', loop(data))]);

Finder labelled(String label) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label, description: label);

void main() {
  testWidgets('adds a loop variable from the empty state', (t) async {
    final h = await start(t);
    await renderBody(t, h, 'loop-node', loopPanelBody, width: 900);
    expect(find.text('workflow.nodes.loop.setLoopVariables'), findsOneWidget);

    await t.tap(labelled('common.operation.add'));
    await Harness.settle(t);

    final vars = dataOf(h, 'loop-node')['loop_variables']! as List;
    expect(vars.single, allOf(containsPair('label', ''), containsPair('var_type', 'string')));
    expect(find.text('workflow.nodes.loop.setLoopVariables'), findsNothing);
    await h.dispose(t);
  });

  testWidgets('refuses an invalid variable name with a toast', (t) async {
    final toasts = Toasts();
    final h = await start(t, {
      'loop_variables': [
        {'id': 'v1', 'label': 'count', 'var_type': 'number', 'value_type': 'constant', 'value': '1'},
      ],
    });
    await renderBody(t, h, 'loop-node', loopPanelBody, width: 900, toast: toasts.call);

    await t.enterText(find.widgetWithText(TextField, 'count'), '1count');
    await Harness.settle(t);

    expect(toasts.messages, ['app-debug.varKeyError.notStartWithNumber:{"key":"workflow.env.modal.name"}']);
    expect(((dataOf(h, 'loop-node')['loop_variables']! as List).single as Map)['label'], 'count');
    await h.dispose(t);
  });

  testWidgets('adds a termination condition on a loop variable', (t) async {
    final h = await start(t, {
      'loop_variables': [
        {'id': 'v1', 'label': 'count', 'var_type': 'number', 'value_type': 'constant', 'value': '1'},
      ],
    });
    await renderBody(t, h, 'loop-node', loopPanelBody, width: 900);

    await t.tap(find.text('workflow.nodes.ifElse.addCondition'));
    await Harness.settle(t);
    await t.tap(find.descendant(of: find.byType(VarReferenceVars), matching: find.text('count')).first);
    await Harness.settle(t);

    final conditions = dataOf(h, 'loop-node')['break_conditions']! as List;
    expect(
      conditions.single,
      allOf(
        containsPair('variable_selector', ['loop-node', 'count']),
        containsPair('varType', 'number'),
        containsPair('comparison_operator', '='),
        containsPair('value', ''),
      ),
    );
    expect(find.byType(ConditionNumberInput), findsOneWidget);
    await h.dispose(t);
  });

  testWidgets('rounds the maximum loop count and falls back to 1', (t) async {
    final h = await start(t);
    await renderBody(t, h, 'loop-node', loopPanelBody, width: 900);
    final input = find.descendant(of: labelled('workflow.nodes.loop.loopMaxCount'), matching: find.byType(TextField));

    await t.enterText(input, '7.4');
    await Harness.settle(t);
    expect(dataOf(h, 'loop-node')['loop_count'], 7);

    await t.enterText(input, '');
    await Harness.settle(t);
    expect(dataOf(h, 'loop-node')['loop_count'], 1);
    await h.dispose(t);
  });
}
