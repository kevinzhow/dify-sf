// dify-spec: web/app/components/workflow/nodes/list-operator/components/__tests__/filter-condition.spec.tsx
//
// The real ConditionOperator, BoolValue and SubVariablePicker stand in for Dify's mocks; typed values commit on
// blur.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'list_operator_extract_input_test.dart' show typeInto;
import 'list_operator_sub_variable_picker_test.dart' show pumpControl;

const scope = VarScope(
  vars: [
    VarGroup(nodeId: 'text-node', title: 'Texts', vars: [PickerVar('title', 'string')]),
    VarGroup(nodeId: 'number-node', title: 'Numbers', vars: [PickerVar('count', 'number')]),
  ],
);

Future<List<Map<String, Object?>>> renderCondition(
  WidgetTester t,
  Map<String, Object?> condition, {
  required String varType,
  bool hasSubVariable = false,
}) async {
  final changes = <Map<String, Object?>>[];
  await pumpControl(
    t,
    FilterCondition(
      condition: condition,
      varType: varType,
      hasSubVariable: hasSubVariable,
      scope: scope,
      onChange: (c, _) => changes.add(c),
    ),
  );
  return changes;
}

void main() {
  group('FilterCondition', () {
    testWidgets('should render a select input for array-backed file conditions and update array values', (t) async {
      final changes = await renderCondition(
        t,
        const {
          'key': 'type',
          'comparison_operator': Op.in_,
          'value': ['document'],
        },
        varType: 'file',
        hasSubVariable: true,
      );

      expect(find.text('workflow.nodes.ifElse.comparisonOperator.in'), findsOneWidget);
      expect(find.byType(SubVariablePicker), findsOneWidget);

      await t.tap(find.text('workflow.nodes.ifElse.optionName.doc'));
      await Harness.settle(t);
      await t.tap(find.text('workflow.nodes.ifElse.optionName.image'));
      await Harness.settle(t);

      expect(changes, [
        {
          'key': 'type',
          'comparison_operator': Op.in_,
          'value': ['image'],
        },
      ]);
    });

    testWidgets('should render a boolean value control for boolean variables', (t) async {
      final changes = await renderCondition(t, const {
        'key': 'enabled',
        'comparison_operator': Op.equal,
        'value': false,
      }, varType: 'boolean');

      await t.tap(find.text('True'));
      await Harness.settle(t);

      expect(changes, [
        {'key': 'enabled', 'comparison_operator': Op.equal, 'value': true},
      ]);
    });

    testWidgets('should render a supported variable input, apply focus styles, and filter vars by expected type', (
      t,
    ) async {
      final changes = await renderCondition(t, const {
        'key': 'name',
        'comparison_operator': Op.equal,
        'value': 'draft',
      }, varType: 'file');

      final input = t.widget<VarInput>(find.byType(VarInput));
      expect(input.placeholder, 'workflow.nodes.http.insertVarPlaceholder');
      expect([for (final g in input.vars) g.nodeId], ['text-node']);

      await typeInto(t, find.byType(VarInput), 'draft next');
      await blur(t);

      expect(changes.last, {'key': 'name', 'comparison_operator': Op.equal, 'value': 'draft next'});
    });

    testWidgets('should reset operator and value when the sub variable changes', (t) async {
      final changes = await renderCondition(
        t,
        const {'key': '', 'comparison_operator': Op.equal, 'value': ''},
        varType: 'file',
        hasSubVariable: true,
      );

      await t.tap(find.text('common.placeholder.select'));
      await Harness.settle(t);
      await t.tap(find.text('size'));
      await Harness.settle(t);

      expect(changes, [
        {'key': 'size', 'comparison_operator': Op.largerThan, 'value': ''},
      ]);
    });

    testWidgets('should render fallback inputs for unsupported keys and hide value inputs for no-value operators', (
      t,
    ) async {
      final changes = await renderCondition(t, const {
        'key': 'custom_field',
        'comparison_operator': Op.equal,
        'value': '',
      }, varType: 'number');

      final plain = find.byType(PlainConditionInput);
      expect(t.widget<PlainConditionInput>(plain).number, true);
      await t.enterText(find.descendant(of: plain, matching: find.byType(TextField)), '42');
      await blur(t);
      expect(changes.last, {'key': 'custom_field', 'comparison_operator': Op.equal, 'value': '42'});

      await renderCondition(t, const {
        'key': 'custom_field',
        'comparison_operator': Op.empty,
        'value': '',
      }, varType: 'file');
      expect(find.byType(VarInput), findsNothing);
      expect(find.byType(PlainConditionInput), findsNothing);
    });

    testWidgets(
      'should build transfer-method options and keep empty select option lists stable for unsupported keys',
      (t) async {
        final changes = await renderCondition(t, const {
          'key': 'transfer_method',
          'comparison_operator': Op.in_,
          'value': ['local_file'],
        }, varType: 'file');

        await t.tap(find.text('workflow.nodes.ifElse.optionName.localUpload'));
        await Harness.settle(t);
        await t.tap(find.text('workflow.nodes.ifElse.optionName.url'));
        await Harness.settle(t);
        expect(changes, [
          {
            'key': 'transfer_method',
            'comparison_operator': Op.in_,
            'value': ['remote_url'],
          },
        ]);

        await renderCondition(t, const {
          'key': 'custom_field',
          'comparison_operator': Op.in_,
          'value': '',
        }, varType: 'file');
        expect(find.text('Select value'), findsOneWidget);
      },
    );
  });
}
