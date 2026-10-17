// dify-spec: web/app/components/workflow/nodes/data-source/hooks/__tests__/use-config.spec.ts
//
// useConfig's mount effect runs in the panel; its handlers are the panel's `setInputs` writes; the output schema
// helpers are pure.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/entry_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:flutter_test/flutter_test.dart';

import '../trigger_plugin/panel_harness.dart';

Map<String, Object?> createNodeData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Datasource',
  'desc': '',
  'plugin_id': 'plugin-1',
  'provider_type': 'local_file',
  'provider_name': 'provider',
  'datasource_name': 'source-a',
  'datasource_label': 'Source A',
  'datasource_parameters': <String, Object?>{},
  'datasource_configurations': <String, Object?>{},
  '_dataSourceStartToAdd': true,
  ...overrides,
};

void main() {
  setUp(useDifyTestTranslator);

  group('data-source/hooks/use-config', () {
    testWidgets('should clear the local-file auto-add flag on mount and update datasource payloads', (t) async {
      final h = await Harness.start(t, [difyNode('data-source-node', 'datasource', createNodeData())]);
      await pumpBody(t, h, 'data-source-node', dataSourcePanelBody);

      expect(plainOf(h['data-source-node']!.config['_dataSourceStartToAdd']), isFalse);

      NodePanelProps props() =>
          NodePanelProps(node: h['data-source-node']!, controller: h.controller, actions: h.actions());
      setInputs(props(), {
        ...props().data,
        'fileExtensions': ['pdf', 'csv'],
      });
      setInputs(props(), {
        ...props().data,
        'datasource_parameters': {
          'dataset': {'type': 'constant', 'value': 'docs'},
        },
      });
      await Harness.settle(t);

      final config = h['data-source-node']!.config;
      expect(plainOf(config['fileExtensions']), ['pdf', 'csv']);
      expect(plainOf(config['datasource_parameters']), {
        'dataset': {'type': 'constant', 'value': 'docs'},
      });
      await h.dispose(t);
    });

    test('should derive output schema metadata and detect object outputs', () {
      final dataSourceList = [
        {
          'plugin_id': 'plugin-1',
          'tools': [
            {
              'name': 'source-a',
              'output_schema': {
                'properties': {
                  'items': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description': 'List of items',
                  },
                  'metadata': {'type': 'object', 'description': 'Object field'},
                  'count': {'type': 'number', 'description': 'Total count'},
                },
              },
            },
          ],
        },
      ];
      final data = createNodeData();

      // The entries as Dify's objects (keys left out where Dify sets none).
      final schema = [
        for (final o in dataSourceOutputSchema(dataSourceList, data))
          {
            'name': o.name,
            if (o.value != null) 'value': o.value,
            if (o.type != null) 'type': o.type,
            if (o.value == null) 'description': o.description,
          },
      ];
      expect(schema, [
        {'name': 'items', 'type': 'Array[String]', 'description': 'List of items'},
        {
          'name': 'metadata',
          'value': {'type': 'object', 'description': 'Object field'},
        },
        {'name': 'count', 'type': 'Number', 'description': 'Total count'},
      ]);
      expect(dataSourceHasObjectOutput(dataSourceList, data), isTrue);
    });
  });
}
