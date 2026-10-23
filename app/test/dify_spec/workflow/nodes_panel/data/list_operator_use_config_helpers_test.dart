// dify-spec: web/app/components/workflow/nodes/list-operator/__tests__/use-config.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_model.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> createInputs() => {
  'title': 'List Filter',
  'desc': '',
  'type': 'list-operator',
  'variable': ['node', 'list'],
  'var_type': 'array[string]',
  'item_var_type': 'string',
  'filter_by': {
    'enabled': false,
    'conditions': [
      {'key': '', 'comparison_operator': 'contains', 'value': ''},
    ],
  },
  'extract_by': {'enabled': false, 'serial': ''},
  'order_by': {'enabled': false, 'key': '', 'value': OrderBy.desc},
  'limit': {'enabled': false, 'size': 20},
};

void main() {
  group('list operator use-config helpers', () {
    test('maps item var types, labels and filter support', () {
      expect(getItemVarType('array[number]'), 'number');
      expect(getItemVarType('array[boolean]'), 'boolean');
      expect(getItemVarType(null), 'string');
      expect(getItemVarTypeShowName(null, false), '?');
      expect(getItemVarTypeShowName('number', true), 'Number');
      expect(supportsSubVariable('array[file]'), true);
      expect(supportsSubVariable('array[string]'), false);
      expect(canFilterVariable('array[file]'), true);
      expect(canFilterVariable('string'), false);
    });

    test('builds default conditions and updates selected variable metadata', () {
      expect(buildFilterCondition(itemVarType: 'boolean', isFileArray: false), {
        'key': '',
        'comparison_operator': 'is',
        'value': false,
      });
      expect(buildFilterCondition(itemVarType: 'string', isFileArray: true), {
        'key': 'name',
        'comparison_operator': 'contains',
        'value': '',
      });

      final next = updateListFilterVariable(
        {
          ...createInputs(),
          'order_by': {'enabled': true, 'key': '', 'value': OrderBy.desc},
        },
        variable: const ['node', 'files'],
        varType: 'array[file]',
        itemVarType: 'file',
      );
      expect(next['var_type'], 'array[file]');
      expect(((next['filter_by']! as Map)['conditions'] as List)[0], containsPair('key', 'name'));
      expect((next['order_by']! as Map)['key'], 'name');
    });

    test('updates filter, extract, limit and order by sections', () {
      final condition = {'key': 'size', 'comparison_operator': '>', 'value': '10'};
      expect((updateFilterEnabled(createInputs(), true)['filter_by']! as Map)['enabled'], true);
      expect(
        ((updateFilterCondition(createInputs(), condition)['filter_by']! as Map)['conditions'] as List)[0],
        condition,
      );
      expect(updateLimit(createInputs(), const {'enabled': true, 'size': 10})['limit'], {'enabled': true, 'size': 10});
      expect(updateExtractEnabled(createInputs(), true)['extract_by'], {'enabled': true, 'serial': '1'});
      expect((updateExtractSerial(createInputs(), '2')['extract_by']! as Map)['serial'], '2');

      final orderEnabled = updateOrderByEnabled(createInputs(), true, true)['order_by']! as Map;
      expect(orderEnabled, {'enabled': true, 'key': 'name', 'value': OrderBy.asc});
      expect((updateOrderByKey(createInputs(), 'created_at')['order_by']! as Map)['key'], 'created_at');
      expect((updateOrderByType(createInputs(), OrderBy.desc)['order_by']! as Map)['value'], OrderBy.desc);
      // produce: the input is left alone.
      final inputs = createInputs();
      updateExtractEnabled(inputs, true);
      expect(inputs['extract_by'], {'enabled': false, 'serial': ''});
    });
  });
}
