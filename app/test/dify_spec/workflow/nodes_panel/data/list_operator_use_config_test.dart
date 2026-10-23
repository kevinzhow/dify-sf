// dify-spec: web/app/components/workflow/nodes/list-operator/__tests__/use-config.spec.tsx
//
// use-config.ts is listOperatorTypes (derived state) and the helpers its handlers call; the variable types come
// from a scope (Dify's mocked getCurrentVariableType). The container context is the scope of a node inside an
// iteration or loop in a document.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'List Filter',
  'desc': '',
  'type': 'list-operator',
  'variable': ['start', 'files'],
  'var_type': 'array[file]',
  'item_var_type': 'file',
  'filter_by': {
    'enabled': false,
    'conditions': [
      {'key': '', 'comparison_operator': Op.contains, 'value': ''},
    ],
  },
  'extract_by': {'enabled': false, 'serial': ''},
  'order_by': {'enabled': false, 'key': '', 'value': OrderBy.asc},
  'limit': {'enabled': false, 'size': 10},
  ...overrides,
};

final scope = VarScope(
  typeOf: (sel) => switch (sel.elementAtOrNull(1)) {
    'files' => 'array[file]',
    'numbers' => 'array[number]',
    _ => 'array[string]',
  },
);

void main() {
  group('list-operator/use-config', () {
    test('should expose derived state and update inputs through the helper pipeline', () {
      final inputs = createPayload();
      final types = listOperatorTypes(inputs, scope);
      expect(types.varType, 'array[file]');
      expect(types.itemVarType, 'file');
      expect(types.itemVarTypeShowName, 'File');
      expect(types.hasSubVariable, true);
      expect(canFilterVariable('array[string]'), true);
      expect(canFilterVariable('object'), false);

      final varType = scope.typeOf!(const ['node-2', 'numbers']);
      final changed = updateListFilterVariable(
        inputs,
        variable: const ['node-2', 'numbers'],
        varType: varType,
        itemVarType: getItemVarType(varType),
      );
      expect(changed['variable'], ['node-2', 'numbers']);
      expect(changed['var_type'], 'array[number]');
      expect(changed['item_var_type'], 'number');
      expect((updateFilterEnabled(inputs, true)['filter_by']! as Map)['enabled'], true);
      final condition = {'key': 'size', 'comparison_operator': Op.largerThan, 'value': '2'};
      expect((updateFilterCondition(inputs, condition)['filter_by']! as Map)['conditions'], [condition]);
      expect(updateLimit(inputs, const {'enabled': true, 'size': 3})['limit'], {'enabled': true, 'size': 3});
      expect(updateExtractEnabled(inputs, true)['extract_by'], {'enabled': true, 'serial': '1'});
      expect(updateExtractSerial(inputs, '5')['extract_by'], {'enabled': false, 'serial': '5'});
      expect(updateOrderByEnabled(inputs, true, types.hasSubVariable)['order_by'], {
        'enabled': true,
        'key': 'name',
        'value': OrderBy.asc,
      });
      expect((updateOrderByKey(inputs, 'size')['order_by']! as Map)['key'], 'size');
      expect((updateOrderByType(inputs, OrderBy.desc)['order_by']! as Map)['value'], OrderBy.desc);
    });

    testWidgets('should derive parent nodes from iteration and loop contexts', (t) async {
      final h = await Harness.start(t, [
        difyNode('iteration-parent', {'type': 'iteration', 'iterator_selector': <Object?>[]}),
        difyNode(
          'list-node',
          createPayload({
            'variable': const ['iteration', 'files'],
          }),
          parent: 'iteration-parent',
        ),
        difyNode('loop-parent', {'type': 'loop', 'loop_count': 10}, x: 600),
        difyNode(
          'loop-node',
          createPayload({
            'variable': const ['loop', 'names'],
          }),
          parent: 'loop-parent',
        ),
      ]);
      final actions = h.actions(const WorkflowMenuOptions(canEdit: false, isChatMode: true));
      NodePanelProps props(String id) => NodePanelProps(node: h[id]!, controller: h.controller, actions: actions);

      expect(props('list-node').readOnly, true);
      expect(props('list-node').chatMode, true);
      expect(NodeVars.of(props('list-node')).scope.parent?.id, 'iteration-parent');
      expect(NodeVars.of(props('loop-node')).scope.parent?.id, 'loop-parent');

      // array[string] (the loop node's names): no sub variable, so the order key stays empty.
      final loopData = createPayload({
        'variable': const ['loop', 'names'],
      });
      final hasSub = listOperatorTypes(loopData, scope).hasSubVariable;
      expect(updateOrderByEnabled(loopData, true, hasSub)['order_by'], {
        'enabled': true,
        'key': '',
        'value': OrderBy.asc,
      });
      await h.dispose(t);
    });
  });
}
