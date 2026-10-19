// dify-spec: web/app/components/workflow/nodes/list-operator/__tests__/integration.spec.tsx
//
// The controls, the card and the panel over a document (fixtures in the node, panel and component tests).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'list_operator_extract_input_test.dart' show focusedLook, typeInto;
import 'list_operator_node_test.dart' as card;
import 'list_operator_panel_test.dart' as panel;
import 'list_operator_sub_variable_picker_test.dart' show pumpControl;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

void main() {
  group('list-operator path', () {
    group('Path Integration', () {
      testWidgets('should update the extract input', (t) async {
        final changes = <String>[];
        await pumpControl(t, ExtractInput(value: '1', onChange: (v, _) => changes.add(v)));

        await typeInto(t, find.byType(VarInput), '2');
        expect(focusedLook(t), true);
        await blur(t);
        expect(changes, ['2']);

        await pumpControl(t, ExtractInput(value: '', readOnly: true, onChange: (v, _) => changes.add(v)));
        expect(t.widget<VarInput>(find.byType(VarInput)).placeholder, '');
      });

      testWidgets('should change the selected sub variable', (t) async {
        final changes = <String>[];
        await pumpControl(t, SubVariablePicker(value: 'size', onChange: changes.add));
        await t.tap(find.text('size'));
        await Harness.settle(t);
        await t.tap(find.text('name'));
        await Harness.settle(t);
        expect(changes, ['name']);

        await pumpControl(t, SubVariablePicker(value: '', onChange: changes.add));
        expect(find.text('common.placeholder.select'), findsOneWidget);
      });

      testWidgets('should toggle limit and update the size slider', (t) async {
        final changes = <Map<String, Object?>>[];
        await pumpControl(t, LimitConfig(config: const {'enabled': true, 'size': 10}, onChange: changes.add));

        final number = find.descendant(of: find.byType(InputNumberWithSlider), matching: find.byType(TextField));
        await t.enterText(number, '11');
        await blur(t);
        expect(changes, [
          {'enabled': true, 'size': 11},
        ]);

        await pumpControl(t, LimitConfig(config: const {'enabled': false, 'size': 10}, onChange: changes.add));
        expect(find.byType(InputNumberWithSlider), findsNothing);
        await t.tap(find.byType(DifySwitch));
        await Harness.settle(t);
        expect(changes.last, {'enabled': true, 'size': 10});
      });

      testWidgets('should render the selected input variable in the node preview', (t) async {
        await card.renderListCard(t, card.listNode(const ['answer-node', 'items']));
        expect(find.text('Answer'), findsOneWidget);
        expect(find.text('items'), findsOneWidget);
      });

      testWidgets('should resolve system variables through the start node and return null without a variable', (
        t,
      ) async {
        await card.renderListCard(t, card.listNode(const ['sys', 'files']));
        expect(find.text('Start'), findsOneWidget);

        await card.renderListCard(t, card.listNode(const []));
        expect(find.text('INPUT VARIABLE'), findsNothing);
        expect(find.text('Start'), findsNothing);
      });

      testWidgets('should render the panel controls and output vars', (t) async {
        // Wide enough for the ASC / DESC cards with the test translator's long labels.
        final h = await panel.renderListPanel(
          t,
          width: 1200,
          overrides: {
            'variable': ['answer-node', 'numbers'],
            'var_type': 'array[number]',
            'item_var_type': 'number',
            'filter_by': {
              'enabled': true,
              'conditions': [
                {'key': '', 'comparison_operator': '=', 'value': '1'},
              ],
            },
          },
        );

        await panel.pickInput(t, 'names');
        expect(dataOf(h, 'list-node')['variable'], ['answer-node', 'names']);
        await t.tap(find.text('workflow.nodes.listFilter.desc'));
        await Harness.settle(t);
        expect((dataOf(h, 'list-node')['order_by']! as Map)['value'], 'desc');
        await t.tap(find.text('workflow.nodes.listFilter.asc'));
        await Harness.settle(t);
        expect((dataOf(h, 'list-node')['order_by']! as Map)['value'], 'asc');

        await panel.openOutputs(t);
        // The output variable, and the input picker's type (`capitalize`: Chrome capitalises after `[` too).
        expect(find.text('Array[String]'), findsNWidgets(2));
        expect(find.text('String'), findsNWidgets(2));
        await h.dispose(t);
      });

      testWidgets('should hide disabled sections and render order controls without sub variables', (t) async {
        var h = await panel.renderListPanel(
          t,
          overrides: {
            'variable': ['answer-node', 'names'],
            'filter_by': {'enabled': false, 'conditions': <Object?>[]},
            'extract_by': {'enabled': false, 'serial': ''},
            'order_by': {'enabled': false, 'key': '', 'value': 'asc'},
          },
        );
        expect(find.byType(FilterCondition), findsNothing);
        expect(find.byType(ExtractInput), findsNothing);
        expect(find.text('workflow.nodes.listFilter.asc'), findsNothing);
        await h.dispose(t);

        h = await panel.renderListPanel(
          t,
          width: 1200,
          overrides: {
            'variable': ['answer-node', 'names'],
            'order_by': {'enabled': true, 'key': '', 'value': 'asc'},
          },
        );
        expect(find.text('workflow.nodes.listFilter.asc'), findsOneWidget);
        // No file attributes: the filter and the order offer no sub variable picker.
        expect(find.byType(SubVariablePicker), findsNothing);
        await h.dispose(t);
      });
    });
  });
}
