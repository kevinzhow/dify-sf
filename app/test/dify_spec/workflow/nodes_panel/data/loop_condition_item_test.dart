// dify-spec: web/app/components/workflow/nodes/loop/__tests__/condition-item.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_conditions.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../panel_fields/harness.dart';

const _flag = PickerVar('flag', 'boolean');
const _vars = ConditionVars(
  availableVars: [
    VarGroup(nodeId: 'source', title: 'Source', vars: [_flag]),
  ],
);

Future<List<(String, Json)>> renderConditionItem(WidgetTester t, Json condition) async {
  final updates = <(String, Json)>[];
  await render(
    t,
    ConditionItem(
      conditionId: '${condition['id']}',
      condition: condition,
      handlers: ConditionHandlers(onUpdate: (id, c) => updates.add((id, c))),
      vars: _vars,
    ),
    width: 800,
  );
  return updates;
}

void main() {
  group('ConditionItem', () {
    testWidgets('should render legacy boolean string \$value as \$expected', (t) async {
      for (final (value, expected) in const [('false', false), ('true', true)]) {
        await renderConditionItem(t, {
          'id': 'condition-1',
          'varType': 'boolean',
          'variable_selector': ['source', 'flag'],
          'comparison_operator': 'is',
          'value': value,
        });
        expect(t.widget<BoolValue>(find.byType(BoolValue)).value, expected);
      }
    });

    testWidgets('should reset the value to boolean false when selecting a boolean variable', (t) async {
      final updates = await renderConditionItem(t, {
        'id': 'condition-1',
        'varType': 'string',
        'variable_selector': ['source', 'text'],
        'comparison_operator': 'contains',
        'value': '',
      });

      await t.tap(find.text('text'));
      await t.pumpAndSettle();
      await t.tap(find.text('flag'));
      await t.pumpAndSettle();

      expect(updates.single.$1, 'condition-1');
      expect(updates.single.$2, {
        'id': 'condition-1',
        'varType': 'boolean',
        'variable_selector': ['source', 'flag'],
        'comparison_operator': 'is',
        'value': false,
      });
    });
  });
}
