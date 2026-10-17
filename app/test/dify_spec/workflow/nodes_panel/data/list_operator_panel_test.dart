// dify-spec: web/app/components/workflow/nodes/list-operator/__tests__/panel.spec.tsx
//
// The panel over a document instead of a mocked use-config: a Code node ("Answer") outputs the arrays the list
// operator reads (`items` is a file array, so the filter and the order offer file attributes).
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final source = difyNode('answer-node', {
  'type': 'code',
  'title': 'Answer',
  'code': '',
  'code_language': 'python3',
  'variables': <Object?>[],
  'outputs': {
    'items': {'type': 'array[file]', 'children': null},
    'numbers': {'type': 'array[number]', 'children': null},
    'names': {'type': 'array[string]', 'children': null},
  },
});

Map<String, Object?> listData([Map<String, Object?> overrides = const {}]) => {
  'type': 'list-operator',
  'title': 'List Operator',
  'variable': ['answer-node', 'items'],
  'var_type': 'array[file]',
  'item_var_type': 'file',
  'filter_by': {
    'enabled': true,
    'conditions': [
      {'key': 'name', 'comparison_operator': 'contains', 'value': ''},
    ],
  },
  'extract_by': {'enabled': true, 'serial': '1'},
  'order_by': {'enabled': true, 'key': 'size', 'value': 'asc'},
  'limit': {'enabled': true, 'size': 10},
  ...overrides,
};

Future<Harness> renderListPanel(
  WidgetTester t, {
  Map<String, Object?> overrides = const {},
  bool readOnly = false,
  double width = 420,
}) async {
  final h = await Harness.start(
    t,
    [
      source,
      difyNode('list-node', listData(overrides), others: [source], x: 300),
    ],
    edges: [edge('answer-node', 'list-node')],
  );
  if (width > 800) t.view.physicalSize = Size(width + 100, 900);
  await renderBody(
    t,
    h,
    'list-node',
    listOperatorPanelBody,
    width: width,
    options: WorkflowMenuOptions(canEdit: !readOnly),
  );
  return h;
}

/// Opens the (collapsed) output variables section.
Future<void> openOutputs(WidgetTester t) async {
  await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
  await Harness.settle(t);
}

/// The panel's switches, in order: filter, extract, limit, order.
List<DifySwitch> switches(WidgetTester t) => t.widgetList<DifySwitch>(find.byType(DifySwitch)).toList();

Future<void> toggle(WidgetTester t, int index) async {
  await t.tap(find.byType(DifySwitch).at(index));
  await Harness.settle(t);
}

/// Picks [variable] in the input variable picker.
Future<void> pickInput(WidgetTester t, String variable) async {
  await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
  await Harness.settle(t);
  await t.tap(find.descendant(of: find.byType(VarReferenceVars), matching: find.text(variable)));
  await Harness.settle(t);
}

void main() {
  group('list-operator/panel', () {
    testWidgets('renders enabled sections and forwards all main interactions', (t) async {
      final h = await renderListPanel(t);

      expect(find.text('WORKFLOW.NODES.LISTFILTER.INPUTVAR *'), findsOneWidget);
      expect(find.text('items'), findsOneWidget);
      expect(find.byType(FilterCondition), findsOneWidget);
      expect(t.widget<ExtractInput>(find.byType(ExtractInput)).value, '1');
      expect(t.widget<InputNumberWithSlider>(find.byType(InputNumberWithSlider)).value, 10);
      expect(t.widgetList<SubVariablePicker>(find.byType(SubVariablePicker)).last.value, 'size');
      await openOutputs(t);
      expect(find.text('Array[File]'), findsOneWidget);
      expect(find.text('workflow.nodes.listFilter.outputVars.result'), findsOneWidget);
      expect(find.text('File'), findsNWidgets(2));
      expect(find.text('workflow.nodes.listFilter.outputVars.first_record'), findsOneWidget);
      expect(find.text('workflow.nodes.listFilter.outputVars.last_record'), findsOneWidget);

      // The order key, then DESC.
      await t.tap(find.text('size'));
      await Harness.settle(t);
      await t.tap(find.widgetWithText(DifyMenuItem, 'name'));
      await Harness.settle(t);
      expect((dataOf(h, 'list-node')['order_by']! as Map)['key'], 'name');
      await t.tap(find.text('workflow.nodes.listFilter.desc'));
      await Harness.settle(t);
      expect((dataOf(h, 'list-node')['order_by']! as Map)['value'], 'desc');

      // Top N typed.
      final limit = find.descendant(of: find.byType(InputNumberWithSlider), matching: find.byType(TextField));
      await t.enterText(limit, '11');
      await blur(t);
      expect(dataOf(h, 'list-node')['limit'], {'enabled': true, 'size': 11});

      // The filter and extract switches.
      await toggle(t, 0);
      expect((dataOf(h, 'list-node')['filter_by']! as Map)['enabled'], false);
      await toggle(t, 1);
      expect((dataOf(h, 'list-node')['extract_by']! as Map)['enabled'], false);
      await toggle(t, 3);
      expect((dataOf(h, 'list-node')['order_by']! as Map)['enabled'], false);

      // A new input variable resets the condition for its item type.
      await pickInput(t, 'numbers');
      final data = dataOf(h, 'list-node');
      expect(data['variable'], ['answer-node', 'numbers']);
      expect(data['var_type'], 'array[number]');
      expect(data['item_var_type'], 'number');
      expect((data['filter_by']! as Map)['conditions'], [
        {'key': '', 'comparison_operator': '=', 'value': ''},
      ]);
      await h.dispose(t);
    });

    testWidgets('hides disabled sections and forwards readonly state to child controls', (t) async {
      final h = await renderListPanel(
        t,
        readOnly: true,
        overrides: {
          'variable': ['answer-node', 'names'],
          'filter_by': {'enabled': false, 'conditions': <Object?>[]},
          'extract_by': {'enabled': false, 'serial': ''},
          'order_by': {'enabled': false, 'key': '', 'value': 'desc'},
        },
      );

      expect(t.widget<VarReferencePicker>(find.byType(VarReferencePicker)).readonly, true);
      expect(t.widget<InputNumberWithSlider>(find.byType(InputNumberWithSlider)).readonly, true);
      expect(find.byType(FilterCondition), findsNothing);
      expect(find.byType(ExtractInput), findsNothing);
      expect(find.byType(SubVariablePicker), findsNothing);
      expect(find.text('workflow.nodes.listFilter.asc'), findsNothing);
      // Filter, extract, Top N (Dify's mocked LimitConfig has none) and order.
      expect(switches(t), hasLength(4));
      expect(switches(t).every((s) => s.disabled), true);
      await h.dispose(t);
    });
  });
}
