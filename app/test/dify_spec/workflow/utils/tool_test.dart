// dify-spec: web/app/components/workflow/utils/__tests__/tool.spec.ts
//
// Dify mocks toolParametersToFormSchemas (keeping the parameter type) and canFindTool (equality); these cases run the
// real ones, whose `toType` maps `string` to `text-input` and whose canFindTool also accepts equal ids.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _toolData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Tool',
  'desc': '',
  'type': 'tool',
  'provider_id': 'builtin-search',
  'provider_type': CollectionType.builtIn,
  'tool_name': 'google_search',
  'tool_parameters': <String, Object?>{},
  'tool_configurations': <String, Object?>{},
  ...overrides,
};

Map<String, Object?> _collection([Map<String, Object?> overrides = const {}]) => {
  'id': 'builtin-search',
  'name': 'Search',
  'tools': [
    {
      'name': 'google_search',
      'parameters': [
        {
          'name': 'query',
          'label': {'en_US': 'Query', 'zh_Hans': '查询'},
          'type': 'string',
          'required': true,
          'form': 'llm',
        },
        {
          'name': 'api_key',
          'label': {'en_US': 'API Key'},
          'type': 'string',
          'required': true,
          'form': 'credential',
        },
      ],
    },
  ],
  'allow_delete': true,
  'is_team_authorization': false,
  ...overrides,
};

Map<String, Object?> _check(
  Map<String, Object?> data, {
  List<Map<String, Object?>> builtIn = const [],
  List<Map<String, Object?>> custom = const [],
  List<Map<String, Object?>> workflow = const [],
  String language = 'en_US',
}) => toolCheckParams(data, ToolCollections(builtIn: builtIn, custom: custom, workflow: workflow), language);

void main() {
  group('getToolCheckParams', () {
    test('should separate llm inputs from settings', () {
      final result = _check(_toolData(), builtIn: [_collection()]);
      expect(result['toolInputsSchema'], [
        {'label': 'Query', 'variable': 'query', 'type': 'text-input', 'required': true},
      ]);
      final settings = result['toolSettingSchema'] as List;
      expect(settings, hasLength(1));
      expect((settings[0] as Map)['variable'], 'api_key');
    });

    test('should mark notAuthed for builtin tools without team auth', () {
      expect(_check(_toolData(), builtIn: [_collection()])['notAuthed'], isTrue);
    });

    test('should mark authed when is_team_authorization is true', () {
      final result = _check(
        _toolData(),
        builtIn: [
          _collection({'is_team_authorization': true}),
        ],
      );
      expect(result['notAuthed'], isFalse);
    });

    test('should use custom tools when provider_type is custom', () {
      final result = _check(
        _toolData({'provider_id': 'custom-tool', 'provider_type': CollectionType.custom}),
        custom: [
          _collection({'id': 'custom-tool'}),
        ],
      );
      expect(result['toolInputsSchema'], hasLength(1));
    });

    test('should return empty schemas when tool is not found', () {
      final result = _check(_toolData({'provider_id': 'non-existent'}));
      expect(result['toolInputsSchema'], isEmpty);
      expect(result['toolSettingSchema'], isEmpty);
    });

    test('should include language in result', () {
      expect(_check(_toolData(), builtIn: [_collection()], language: 'zh_Hans')['language'], 'zh_Hans');
    });

    test('should use workflowTools when provider_type is workflow', () {
      final result = _check(
        _toolData({'provider_id': 'wf-tool', 'provider_type': CollectionType.workflow}),
        workflow: [
          _collection({'id': 'wf-tool'}),
        ],
      );
      expect(result['toolInputsSchema'], hasLength(1));
    });

    test('should fallback to en_US label when language key is missing', () {
      final tool = _collection({
        'tools': [
          {
            'name': 'google_search',
            'parameters': [
              {
                'name': 'query',
                'label': {'en_US': 'Query'},
                'type': 'string',
                'required': true,
                'form': 'llm',
              },
            ],
          },
        ],
      });
      final result = _check(_toolData(), builtIn: [tool], language: 'ja_JP');
      expect(((result['toolInputsSchema'] as List)[0] as Map)['label'], 'Query');
    });
  });

  group('wrapStructuredVarItem', () {
    test('should wrap an output item into StructuredOutput format', () {
      const ToolOutputItem item = (
        name: 'result',
        type: null,
        description: null,
        value: {'type': 'string', 'description': 'test'},
      );
      final schema = wrapStructuredVarItem(item, 'json_schema')['schema'] as Map;
      expect(schema['type'], 'object');
      expect(schema['additionalProperties'], false);
      expect((schema['properties'] as Map)['result'], {
        'type': 'string',
        'description': 'test',
        'schemaType': 'json_schema',
      });
    });
  });
}
