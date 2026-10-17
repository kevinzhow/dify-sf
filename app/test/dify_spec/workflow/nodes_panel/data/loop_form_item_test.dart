// dify-spec: web/app/components/workflow/nodes/loop/components/loop-variables/__tests__/form-item.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_variables.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../panel_fields/harness.dart';

/// The text field named [label] (Dify's `getByRole(role, { name })`).
Finder named(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label),
  matching: find.byType(TextField),
);

void main() {
  group('Loop variable constant input', () {
    testWidgets('reports numeric edits and clearing as strings to the loop draft', (t) async {
      final changes = <Object?>[];
      var value = '12';
      await render(
        t,
        StatefulBuilder(
          builder: (context, setState) => LoopVariableFormItem(
            item: {'id': 'count', 'label': 'count', 'var_type': 'number', 'value_type': 'constant', 'value': value},
            onChange: (v) {
              setState(() => value = '$v');
              changes.add(v);
            },
          ),
        ),
      );

      await t.enterText(named('count'), '');
      await t.pump();
      expect(changes.last, '');
      await t.enterText(named('count'), '-3.5');
      await t.pump();
      expect(t.widget<TextField>(named('count')).controller!.text, '-3.5');
      expect(changes.last, '-3.5');
    });

    testWidgets('names an unnamed %s constant until its variable is named', (t) async {
      for (final varType in const ['number', 'string']) {
        Json item(String label) => {
          'id': 'new-variable',
          'label': label,
          'var_type': varType,
          'value_type': 'constant',
          'value': '',
        };
        await render(t, LoopVariableFormItem(item: item(''), onChange: (_) {}));
        expect(named('workflow.errorMsg.fields.variableValue'), findsOneWidget, reason: varType);

        await render(t, LoopVariableFormItem(item: item('counter'), onChange: (_) {}));
        expect(named('counter'), findsOneWidget, reason: varType);
      }
    });
  });
}
