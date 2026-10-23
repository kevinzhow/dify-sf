// dify-spec: web/app/components/workflow/nodes/tool/hooks/__tests__/use-config.spec.tsx
// dify-spec: web/app/components/workflow/nodes/tool/hooks/__tests__/use-current-tool-collection.spec.tsx
// dify-spec: web/app/components/workflow/nodes/tool/hooks/__tests__/use-get-data-for-check-more.spec.ts
// dify-spec: web/app/components/workflow/nodes/tool/hooks/__tests__/use-single-run-form-params.spec.ts
//
// The hooks are ToolConfig / currentToolCollection / ToolSingleRunParams over plain data: the specs' mocked
// node CRUD becomes the inputs passed in (and the returned "next inputs" what setInputs would get).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:flutter_test/flutter_test.dart';

JsonMap createNodeData([JsonMap overrides = const {}]) => {
  'title': 'Google Search',
  'desc': '',
  'type': 'tool',
  'provider_id': 'google_search',
  'provider_type': CollectionType.builtIn,
  'provider_name': 'Google Search',
  'tool_name': 'google_search',
  'tool_label': 'Google Search',
  'tool_parameters': <String, Object?>{},
  'tool_configurations': <String, Object?>{},
  ...overrides,
};

JsonMap param(String name, String form, {String? def}) => {
  'name': name,
  'form': form,
  'label': {'en_US': name},
  'type': 'string',
  'required': true,
  'default': ?def,
};

JsonMap collectionWith(List<JsonMap> params) => {
  'id': 'google_search',
  'name': 'google_search',
  'allow_delete': true,
  'is_team_authorization': false,
  'tools': [
    {'name': 'google_search', 'parameters': params},
  ],
};

JsonMap mixed(String v) => {'type': 'mixed', 'value': v};

JsonMap createToolCollection({String id = 'builtin-search', String type = CollectionType.builtIn}) => {
  'id': id,
  'name': 'Google Search',
  'type': type,
  'label': {'en_US': 'Google Search'},
  'tools': <Object?>[],
  'allow_delete': true,
  'is_team_authorization': false,
};

ToolInputVar createInputVar(String? variable) => {
  'type': 'text-input',
  'label': variable ?? 'invalid',
  'variable': variable,
  'required': false,
};

void main() {
  group('useConfig', () {
    group('Default Value Sync', () {
      final withDefaults = ToolCollections(
        builtIn: [
          collectionWith([
            param('query', 'llm', def: 'default query'),
            param('api_key', 'credential', def: 'default secret'),
          ]),
        ],
      );

      test('should apply default values only once when the current payload is initially empty', () {
        final next = ToolConfig.of(createNodeData(), withDefaults).formattingParameters();
        expect(next, isNotNull);
        expect(next!['tool_parameters'], {'query': mixed('default query')});
        expect(next['tool_configurations'], {'api_key': mixed('default secret')});

        final synced = createNodeData({
          'tool_parameters': {'query': mixed('default query')},
          'tool_configurations': {'api_key': mixed('default secret')},
        });
        expect(ToolConfig.of(synced, withDefaults).formattingParameters(), isNull);
      });

      test('should not update inputs when tool values are already populated on first render', () {
        final populated = createNodeData({
          'tool_parameters': {'query': mixed('existing query')},
          'tool_configurations': {'api_key': mixed('existing secret')},
        });
        expect(ToolConfig.of(populated, withDefaults).formattingParameters(), isNull);
      });

      test('should not update inputs when empty schemas do not provide any default values', () {
        final noDefaults = ToolCollections(
          builtIn: [
            collectionWith([param('query', 'llm'), param('api_key', 'credential')]),
          ],
        );
        expect(ToolConfig.of(createNodeData(), noDefaults).formattingParameters(), isNull);
      });
    });
  });

  group('useCurrentToolCollection', () {
    test('should return the built-in collection list and matched provider for built-in tools', () {
      final builtIn = createToolCollection();
      final r = currentToolCollection(
        CollectionType.builtIn,
        'builtin-search',
        ToolCollections(builtIn: [builtIn], custom: const [], workflow: const [], mcp: const []),
      );
      expect(r.currentTools, [builtIn]);
      expect(identical(r.currCollection, builtIn), isTrue);
    });

    test('should select the custom tool collection when the provider type is custom', () {
      final custom = createToolCollection(id: 'custom-search', type: CollectionType.custom);
      final r = currentToolCollection(
        CollectionType.custom,
        'custom-search',
        ToolCollections(builtIn: const [], custom: [custom]),
      );
      expect(r.currentTools, [custom]);
      expect(identical(r.currCollection, custom), isTrue);
    });

    test('should return undefined when no collection matches the provider id', () {
      final r = currentToolCollection(
        CollectionType.builtIn,
        'builtin-search',
        ToolCollections(builtIn: [createToolCollection(id: 'another-tool')]),
      );
      expect(r.currentTools, hasLength(1));
      expect(r.currCollection, isNull);
    });
  });

  group('useGetDataForCheckMore', () {
    test('should expose the config hook validator as getData', () {
      final data = createNodeData();
      final tools = ToolCollections(
        builtIn: [
          collectionWith([param('query', 'llm'), param('api_key', 'credential')]),
        ],
      );
      // getData is useConfig's getMoreDataForCheckValid; the checklist's getToolCheckParams gives the same.
      final fromConfig = ToolConfig.of(data, tools).moreDataForCheckValid('en_US');
      expect(toolCheckParams(data, tools, 'en_US'), fromConfig);
      expect(fromConfig['notAuthed'], isTrue);
      expect((fromConfig['toolInputsSchema']! as List).single, {
        'label': 'query',
        'variable': 'query',
        'type': 'text-input',
        'required': true,
      });
    });
  });

  group('useSingleRunFormParams', () {
    group('Variable Extraction', () {
      test('should build form inputs from variable params and settings and expose dependent vars', () {
        final calls = <List<String>>[];
        final inputs = [createInputVar('#start.query#'), createInputVar(null), createInputVar('#legacy.answer#')];
        final params = ToolSingleRunParams(
          inputs: createNodeData({
            'tool_parameters': {
              'query': {
                'type': 'variable',
                'value': ['start', 'query'],
              },
              'legacy_query': {'type': 'variable', 'value': 'legacy.answer'},
              'constant_query': {'type': 'constant', 'value': 'fixed'},
            },
            'tool_configurations': {
              'prompt': {'type': 'mixed', 'value': 'prefix {{#tool.result#}}'},
              'api_key': {'type': 'constant', 'value': 'secret'},
              'plainText': 'ignored',
            },
          }),
          getInputVars: (texts) {
            calls.add(texts);
            return inputs;
          },
        );
        expect(calls.single, ['{{#start.query#}}', '{{#legacy.answer#}}', 'prefix {{#tool.result#}}']);
        expect(params.forms, hasLength(1));
        expect(params.forms.single.inputs, inputs);
        expect(params.forms.single.values, isEmpty);
        expect(params.getDependentVars(), [
          ['start', 'query'],
          ['legacy', 'answer'],
        ]);
        expect(params.nodeInfo, isNull);
      });
    });

    group('Form Updates', () {
      test('should update form values and forward run input data on change', () {
        final runData = <JsonMap>[];
        final params = ToolSingleRunParams(
          inputs: createNodeData({
            'tool_parameters': {
              'nullable_constant': {'type': 'constant', 'value': null},
              'query': {
                'type': 'variable',
                'value': ['start', 'query'],
              },
            },
          }),
          getInputVars: (_) => [createInputVar('#start.query#')],
          setRunInputData: runData.add,
        );
        final change = {
          'query': 'weather',
          'tool_parameters': {'nullable_constant': 'temp-value'},
        };
        params.forms.single.onChange(change);
        expect(runData.single, change);
        expect(params.forms.single.values, {...change, 'nullable_constant': null});
      });
    });

    group('Tracing Data', () {
      test('should format the latest run result into node info when a run result exists', () {
        final runResult = {'id': 'trace-1', 'node_id': 'tool-node-1', 'status': 'succeeded'};
        final formatted = <JsonMap>[];
        final params = ToolSingleRunParams(
          inputs: createNodeData(),
          getInputVars: (_) => const [],
          runResult: runResult,
          formatTracing: (r) {
            formatted.add(r);
            return {'id': 'formatted-node'};
          },
        );
        expect(params.nodeInfo, {'id': 'formatted-node'});
        expect(formatted.single, runResult);
      });
    });
  });
}
