// dify-spec: web/app/components/workflow/utils/__tests__/data-source.spec.ts
//
// Dify mocks toolParametersToFormSchemas (its mock keeps the parameter type as is); these cases run the real one
// (tool_form_schema.dart), whose `toType` maps `string` / `number` to `text-input` / `number-input`.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_default.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _data([Map<String, Object?> overrides = const {}]) => {
  'title': 'DataSource',
  'desc': '',
  'type': 'datasource',
  'plugin_id': 'plugin-ds-1',
  'provider_type': 'local_file',
  'datasource_name': 'mysql_query',
  'datasource_parameters': <String, Object?>{},
  'datasource_configurations': <String, Object?>{},
  ...overrides,
};

Map<String, Object?> _collection([Map<String, Object?> overrides = const {}]) => {
  'id': 'ds-collection',
  'plugin_id': 'plugin-ds-1',
  'name': 'MySQL',
  'tools': [
    {
      'name': 'mysql_query',
      'parameters': [
        {
          'name': 'query',
          'label': {'en_US': 'SQL Query', 'zh_Hans': 'SQL 查询'},
          'type': 'string',
          'required': true,
          'hide': false, // Dify's mock defaults `hide` to false.
          'form': 'llm',
        },
        {
          'name': 'limit',
          'label': {'en_US': 'Limit'},
          'type': 'number',
          'required': false,
          'hide': true,
          'form': 'llm',
        },
      ],
    },
  ],
  'allow_delete': true,
  'is_authorized': false,
  ...overrides,
};

void main() {
  group('getDataSourceCheckParams', () {
    test('should extract input schema from matching data source', () {
      final result = getDataSourceCheckParams(_data(), [_collection()], 'en_US');
      expect(result['dataSourceInputsSchema'], [
        {'label': 'SQL Query', 'variable': 'query', 'type': 'text-input', 'required': true, 'hide': false},
        {'label': 'Limit', 'variable': 'limit', 'type': 'number-input', 'required': false, 'hide': true},
      ]);
    });

    test('should not require authorization for a local file datasource', () {
      final result = getDataSourceCheckParams(_data(), [_collection()], 'en_US');
      expect(result['notAuthed'], isFalse);
    });

    test('should mark an unauthorized online datasource as not authed', () {
      final result = getDataSourceCheckParams(_data({'provider_type': 'online_document'}), [_collection()], 'en_US');
      expect(result['notAuthed'], isTrue);
    });

    test('should mark as authed when is_authorized is true', () {
      final result = getDataSourceCheckParams(
        _data({'provider_type': 'online_document'}),
        [
          _collection({'is_authorized': true}),
        ],
        'en_US',
      );
      expect(result['notAuthed'], isFalse);
    });

    test('should return empty schemas when data source is not found', () {
      final result = getDataSourceCheckParams(_data({'plugin_id': 'non-existent'}), [_collection()], 'en_US');
      expect(result['dataSourceInputsSchema'], isEmpty);
    });

    test('should return empty schemas when datasource item is not found', () {
      final result = getDataSourceCheckParams(_data({'datasource_name': 'non_existent_ds'}), [_collection()], 'en_US');
      expect(result['dataSourceInputsSchema'], isEmpty);
    });

    test('should include language in result', () {
      final result = getDataSourceCheckParams(_data(), [_collection()], 'zh_Hans');
      expect(result['language'], 'zh_Hans');
    });
  });
}
