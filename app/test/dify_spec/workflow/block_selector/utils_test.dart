// dify-spec: web/app/components/workflow/block-selector/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _text(String s) => {'en_US': s, 'zh_Hans': s};

Map<String, Object?> _item({Map<String, Object?>? declaration}) => {
  'plugin_id': 'plugin-1',
  'plugin_unique_identifier': 'plugin-1@provider',
  'provider': 'provider-a',
  'declaration':
      declaration ??
      {
        'credentials_schema': [
          {'name': 'api_key'},
        ],
        'provider_type': 'local_file',
        'identity': {
          'author': 'Dify',
          'description': _text('Datasource provider'),
          'icon': 'provider-icon',
          'label': _text('Provider A'),
          'name': 'provider-a',
          'tags': ['retrieval', 'storage'],
        },
        'datasources': [
          {
            'description': _text('Search in documents'),
            'identity': {
              'author': 'Dify',
              'label': _text('Document Search'),
              'name': 'document_search',
              'provider': 'provider-a',
            },
            'parameters': [
              {'name': 'query', 'type': 'string'},
            ],
            'output_schema': {
              'type': 'object',
              'properties': {
                'result': {'type': 'string'},
              },
            },
          },
        ],
      },
  'is_authorized': true,
};

void main() {
  group('transformDataSourceToTool', () {
    test('should map datasource provider fields to tool shape', () {
      final r = transformDataSourceToTool(_item());
      expect(r, containsPair('id', 'plugin-1'));
      expect(r, containsPair('provider', 'provider-a'));
      expect(r, containsPair('name', 'provider-a'));
      expect(r, containsPair('author', 'Dify'));
      expect(r['description'], _text('Datasource provider'));
      expect(r, containsPair('icon', 'provider-icon'));
      expect(r['label'], _text('Provider A'));
      expect(r, containsPair('type', 'local_file'));
      expect(r, containsPair('allow_delete', true));
      expect(r, containsPair('is_authorized', true));
      expect(r, containsPair('is_team_authorization', true));
      expect(r['labels'], ['retrieval', 'storage']);
      expect(r, containsPair('plugin_id', 'plugin-1'));
      expect(r, containsPair('plugin_unique_identifier', 'plugin-1@provider'));
      expect(r['credentialsSchema'], [
        {'name': 'api_key'},
      ]);
      expect(r['meta'], {'version': ''});
      expect(r['team_credentials'], <String, Object?>{});
      expect(r['tools'], [
        {
          'name': 'document_search',
          'author': 'Dify',
          'label': _text('Document Search'),
          'description': _text('Search in documents'),
          'parameters': [
            {'name': 'query', 'type': 'string'},
          ],
          'labels': <Object?>[],
          'output_schema': {
            'type': 'object',
            'properties': {
              'result': {'type': 'string'},
            },
          },
        },
      ]);
      // The provider JSON reads back as a data source provider.
      final p = ToolProvider.fromJson(r);
      expect(p.tools.single.name, 'document_search');
      expect(p.isTeamAuthorization, isTrue);
    });

    test('should fallback to empty arrays when tags and credentials schema are missing', () {
      final base = _item()['declaration']! as Map<String, Object?>;
      final identity = {...base['identity']! as Map<String, Object?>}..remove('tags');
      final r = transformDataSourceToTool(
        _item(declaration: {...base, 'identity': identity}..remove('credentials_schema')),
      );
      expect(r['labels'], isEmpty);
      expect(r['credentialsSchema'], isEmpty);
    });
  });
}
