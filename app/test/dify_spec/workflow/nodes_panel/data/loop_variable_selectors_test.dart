// dify-spec: web/app/components/workflow/nodes/loop/__tests__/variable-selectors.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_conditions.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../panel_fields/harness.dart';

const answer = PickerVar('answer', 'number');
const variables = [
  VarGroup(nodeId: 'source', title: 'Source', vars: [answer]),
];

/// The open popup's search box (`getByRole('searchbox')`).
Finder get searchbox => find.descendant(of: find.byType(VarReferenceVars), matching: find.byType(TextField));

Future<void> search(WidgetTester t, String text) async {
  await t.enterText(searchbox, text);
  await t.pump();
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('adds the variable selected through the search and closes the add popup', (t) async {
    final picked = <(List<String>, PickerVar)>[];
    await render(t, ConditionAdd(variables: variables, onSelectVariable: (s, v) => picked.add((s, v))));

    await t.tap(find.text('workflow.nodes.ifElse.addCondition'));
    await t.pumpAndSettle();
    await search(t, 'answer');

    expect(picked.single.$1, ['source', 'answer']);
    expect(picked.single.$2, same(answer));
    expect(searchbox, findsNothing);
  });

  testWidgets('writes a variable expression when selecting a numeric comparison value', (t) async {
    final values = <String>[];
    await render(
      t,
      ConditionNumberInput(
        numberVarType: 'variable',
        value: '',
        variables: variables,
        onNumberVarTypeChange: (_) {},
        onValueChange: values.add,
      ),
    );

    await t.tap(find.text('workflow.nodes.ifElse.selectVariable'));
    await t.pumpAndSettle();
    await search(t, 'answer');

    expect(values, ['{{#source.answer#}}']);
    expect(searchbox, findsNothing);
  });

  testWidgets('updates the selected condition variable through its controlled popup', (t) async {
    final changes = <(List<String>, PickerVar)>[];
    await render(
      t,
      ConditionVarSelector(
        valueSelector: const ['source', 'previous'],
        varType: 'number',
        vars: const ConditionVars(availableVars: variables),
        onChange: (s, v) => changes.add((s, v)),
      ),
    );

    await t.tap(find.text('previous'));
    await t.pumpAndSettle();
    await search(t, 'answer');

    expect(changes.single.$1, ['source', 'answer']);
    expect(changes.single.$2, same(answer));
  });
}
