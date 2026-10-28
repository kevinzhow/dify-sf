import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_model_inputs.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../dify_spec/dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);
  const scope = VarScope(
    vars: [
      VarGroup(
        nodeId: 'start',
        title: 'Start',
        isStartNode: true,
        vars: [
          PickerVar('model', 'string'),
          PickerVar('effort', 'string'),
          PickerVar('count', 'number'),
          PickerVar('token', 'secret'),
        ],
      ),
    ],
  );

  testWidgets(
    'binds a string dropdown through the shared picker and returns to fixed configuration',
    (t) async {
      var value = <String, Object?>{'model': '{{#start.model#}}'};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: StatefulBuilder(
                builder: (context, setState) => AgentModelInputFields(
                  value: value,
                  scope: scope,
                  onChange: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('agent-v-2.inline.fromConfiguration'), findsOneWidget);
      await t.tap(
        find.bySemanticsLabel('workflow.nodes.common.typeSwitch.variable').last,
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('agent-model-reasoning_effort')));
      await t.pumpAndSettle();
      expect(find.text('count'), findsNothing);
      expect(find.text('token'), findsNothing);
      await t.tap(find.text('effort').last);
      await t.pumpAndSettle();
      expect(value, {
        'model': '{{#start.model#}}',
        'reasoning_effort': '{{#start.effort#}}',
      });
      await t.tap(
        find.bySemanticsLabel('workflow.nodes.common.typeSwitch.input').last,
      );
      await t.pumpAndSettle();
      expect(value, {'model': '{{#start.model#}}'});
    },
  );

  testWidgets('read-only parameters cannot change their source', (t) async {
    var changed = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: AgentModelInputFields(
              value: const {},
              scope: scope,
              readOnly: true,
              onChange: (_) => changed = true,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(
      find.bySemanticsLabel('workflow.nodes.common.typeSwitch.variable').first,
    );
    await t.pumpAndSettle();
    expect(changed, false);
    expect(find.byType(VarReferencePicker), findsNothing);
  });
}
