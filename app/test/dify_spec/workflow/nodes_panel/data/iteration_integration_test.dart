// dify-spec: web/app/components/workflow/nodes/iteration/__tests__/integration.spec.tsx
//
// The panel on a real document (an upstream code node with an array output, a code node inside the iteration)
// instead of a mocked useConfig; the picks go through the real variable pickers.
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/iteration_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'type': 'iteration',
  'title': 'Iteration',
  'start_node_id': 'start-node',
  'iterator_selector': <Object?>[],
  'output_selector': <Object?>[],
  'is_parallel': false,
  'parallel_nums': 3,
  'error_handle_mode': 'terminated',
  'flatten_output': false,
  ...overrides,
};

Future<Harness> start(WidgetTester t, Map<String, Object?> data) async {
  final up = difyNode('node-1', {
    'type': 'code',
    'title': 'Code',
    'outputs': {
      'items': {'type': 'array[string]', 'children': null},
    },
  });
  final iteration = difyNode('iteration-node', createData(data), others: [up], x: 300);
  final child = difyNode('child-node', {
    'type': 'code',
    'title': 'Child',
    'outputs': {
      'text': {'type': 'string', 'children': null},
    },
  }, parent: 'iteration-node');
  return Harness.start(t, [up, iteration, child], edges: [edge('node-1', 'iteration-node')]);
}

Finder get parallelInput => find.descendant(of: find.byType(DifyNumberField), matching: find.byType(TextField));

void main() {
  group('iteration path', () {
    testWidgets('should wire panel input, output, parallel, numeric, error mode, and flatten actions', (t) async {
      final h = await start(t, {'is_parallel': true, 'flatten_output': false});
      await renderBody(t, h, 'iteration-node', iterationPanelBody);

      await t.tap(find.byType(VarReferencePicker).at(0));
      await Harness.settle(t);
      await t.tap(find.text('items').last);
      await Harness.settle(t);
      await t.tap(find.byType(VarReferencePicker).at(1));
      await Harness.settle(t);
      await t.tap(find.text('text').last);
      await Harness.settle(t);

      await t.enterText(parallelInput, '7');
      await blur(t);
      await t.tap(find.byType(DifySelect<String>));
      await Harness.settle(t);
      await t.tap(find.text('workflow.nodes.iteration.ErrorMethod.continueOnError').last);
      await Harness.settle(t);
      await t.tap(find.byType(DifySwitch).at(1));
      await Harness.settle(t);
      await t.tap(find.byType(DifySwitch).at(0));
      await Harness.settle(t);

      final data = dataOf(h, 'iteration-node');
      expect(data['iterator_selector'], ['node-1', 'items']);
      expect(data['iterator_input_type'], 'array[string]');
      expect(data['output_selector'], ['child-node', 'text']);
      expect(data['output_type'], 'array[string]');
      expect(data['is_parallel'], false);
      expect(data['parallel_nums'], 7);
      expect(data['error_handle_mode'], 'continue-on-error');
      expect(data['flatten_output'], true);
      await h.dispose(t);
    });

    testWidgets('should hide parallel controls when parallel mode is disabled', (t) async {
      final h = await start(t, {'is_parallel': false});
      await renderBody(t, h, 'iteration-node', iterationPanelBody);

      expect(find.byType(DifyNumberField), findsNothing);
      expect(find.byType(DifySlider), findsNothing);
      await h.dispose(t);
    });

    testWidgets('does not save an empty parallel count and restores the configured value on blur', (t) async {
      final h = await start(t, {'is_parallel': true});
      await renderBody(t, h, 'iteration-node', iterationPanelBody);

      await t.enterText(parallelInput, '');
      await blur(t);

      expect(dataOf(h, 'iteration-node')['parallel_nums'], 3);
      expect(t.widget<TextField>(parallelInput).controller!.text, '3');
      await h.dispose(t);
    });

    testWidgets('disables both parallel count controls in readonly mode', (t) async {
      final h = await start(t, {'is_parallel': true});
      await renderBody(t, h, 'iteration-node', iterationPanelBody, options: const WorkflowMenuOptions(canEdit: false));

      // DifyNumberField has no increment / decrement buttons (ArrowUp / ArrowDown step it, disabled here too).
      expect(t.widget<DifyNumberField>(find.byType(DifyNumberField)).disabled, isTrue);
      expect(t.widget<DifySlider>(find.byType(DifySlider)).disabled, isTrue);
      await h.dispose(t);
    });
  });
}
