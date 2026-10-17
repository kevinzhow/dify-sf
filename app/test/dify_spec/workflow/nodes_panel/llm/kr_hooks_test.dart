// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/hooks/__tests__/use-knowledge-dataset-selection.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/hooks/__tests__/use-knowledge-metadata-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/hooks/__tests__/use-knowledge-model-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/__tests__/use-config.spec.ts
//
// The hooks are classes over the node data and a setInputs callback (kr_config.dart); the spec's recording setInputs
// moves inputRef. use-config's composition is the panel itself: its cases run on the panel over a document, with the
// services standing for the model lists, the default models and fetchDatasets, and read the node's data.
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_datasets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_metadata.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_retrieval_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'kr_fixtures.dart';

Map<String, Object?> _payload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Knowledge Retrieval',
  'desc': '',
  'type': 'knowledge-retrieval',
  'query_variable_selector': <String>[],
  'query_attachment_selector': ['start-node', 'files'],
  'dataset_ids': ['dataset-1'],
  'retrieval_mode': 'multiple',
  'multiple_retrieval_config': {'top_k': 5, 'score_threshold': 0.2},
  'single_retrieval_config': {
    'model': {'provider': '', 'name': '', 'mode': '', 'completion_params': <String, Object?>{}},
  },
  ...overrides,
};

/// inputRef and a recording setInputs.
class _State {
  _State(this.inputs);
  Map<String, Object?> inputs;
  final calls = <Map<String, Object?>>[];
  void setInputs(Map<String, Object?> next) {
    calls.add(next);
    inputs = next;
  }
}

PickerVar _v(String type) => PickerVar('v', type);

void main() {
  setUp(useDifyTestTranslator);

  group('use-knowledge-dataset-selection', () {
    final fetched = <List<String>>[];
    Future<List<Map<String, Object?>>> fetch(List<String> ids) async {
      fetched.add(ids);
      return [
        createDataset({'id': 'dataset-1', 'name': 'Knowledge Base', 'is_multimodal': true}),
      ];
    }

    setUp(fetched.clear);

    test('loads dataset details on mount and exposes multimodal state', () async {
      final s = _State(_payload());
      final selection = KrDatasetSelection(
        inputsOf: () => s.inputs,
        setInputs: s.setInputs,
        payloadRetrievalMode: () => 'multiple',
        fetchDatasets: fetch,
        fallbackRerankModel: (provider: 'rerank-provider', model: 'rerank-model'),
      );
      await selection.load();
      expect(selection.selectedDatasetsLoaded, isTrue);
      expect(selection.selectedDatasets.single, containsPair('name', 'Knowledge Base'));
      expect(fetched, [
        ['dataset-1'],
      ]);
      expect(s.calls.single['dataset_ids'], ['dataset-1']);
      expect(selection.showImageQueryVarSelector, isTrue);
    });

    test('updates dataset ids, retrieval config, attachment selector, and rerank modal state', () async {
      final s = _State(_payload({'dataset_ids': <String>[]}));
      final updated = <List<Map<String, Object?>>>[];
      final selection = KrDatasetSelection(
        inputsOf: () => s.inputs,
        setInputs: s.setInputs,
        payloadRetrievalMode: () => 'multiple',
        fetchDatasets: fetch,
        updateDatasetsDetail: updated.add,
        fallbackRerankModel: (provider: 'rerank-provider', model: 'rerank-model'),
      );
      await selection.load();
      final next = [
        createDataset({'id': 'dataset-2', 'name': 'Economic Internal', 'indexing_technique': 'economy'}),
        createDataset({'id': 'dataset-3', 'name': 'High Quality Internal'}),
      ];
      selection.handleOnDatasetsChange(next);
      expect(updated.single, next);
      final last = s.calls.last;
      expect(last['dataset_ids'], ['dataset-2', 'dataset-3']);
      expect(last['query_attachment_selector'], <String>[]);
      expect(last['multiple_retrieval_config'], containsPair('reranking_enable', true));
      expect(
        last['multiple_retrieval_config'],
        containsPair('reranking_model', {'provider': 'rerank-provider', 'model': 'rerank-model'}),
      );
      expect(selection.rerankModelOpen, isTrue);
      expect(selection.showImageQueryVarSelector, isFalse);
    });

    test('keeps attachment selectors and skips multiple retrieval updates outside the multi-way flow', () async {
      final s = _State(_payload({'dataset_ids': <String>[], 'retrieval_mode': 'single'}));
      final selection = KrDatasetSelection(
        inputsOf: () => s.inputs,
        setInputs: s.setInputs,
        payloadRetrievalMode: () => 'single',
        fetchDatasets: fetch,
      );
      await selection.load();
      selection
        ..handleOnDatasetsChange([
          createDataset({'id': 'dataset-4', 'is_multimodal': true}),
        ])
        ..rerankModelOpen = false;
      final last = s.calls.last;
      expect(last['dataset_ids'], ['dataset-4']);
      expect(last['query_attachment_selector'], ['start-node', 'files']);
      expect(last['multiple_retrieval_config'], {'top_k': 5, 'score_threshold': 0.2});
      expect(selection.rerankModelOpen, isFalse);
      expect(selection.showImageQueryVarSelector, isTrue);
    });
  });

  group('use-knowledge-metadata-config', () {
    Map<String, Object?> payload([Map<String, Object?> o = const {}]) => {
      'title': 'Knowledge Retrieval',
      'type': 'knowledge-retrieval',
      'query_variable_selector': <String>[],
      'query_attachment_selector': <String>[],
      'dataset_ids': <String>[],
      'retrieval_mode': 'multiway',
      'metadata_filtering_mode': 'disabled',
      ...o,
    };
    KrMetadataConfig config(_State s) {
      var n = 0;
      return KrMetadataConfig(inputsOf: () => s.inputs, setInputs: s.setInputs, newId: () => 'condition-${++n}');
    }

    test('manages metadata filters, conditions, model state, and available vars', () {
      final s = _State(payload());
      final c = config(s)
        ..handleMetadataFilterModeChange('manual')
        ..handleAddCondition({'id': 'meta-1', 'name': 'topic', 'type': 'string', 'value': 'topic'})
        ..handleAddCondition({'id': 'meta-2', 'name': 'score', 'type': 'number', 'value': '10'});
      final first = jsMap(jsList(jsGet(s.calls[1]['metadata_filtering_conditions'], 'conditions'))[0]);
      final second = jsMap(jsList(jsGet(s.calls[2]['metadata_filtering_conditions'], 'conditions'))[1]);
      c
        ..handleUpdateCondition('${second['id']}', {...second, 'comparison_operator': '>', 'value': 0.8})
        ..handleToggleConditionLogicalOperator()
        ..handleRemoveCondition('${first['id']}')
        ..handleMetadataModelChange((provider: 'openai', modelId: 'gpt-4.1-mini', mode: 'chat'))
        ..handleMetadataCompletionParamsChange({'top_p': 0.3});
      expect(s.calls.last['metadata_model_config'], {
        'provider': 'openai',
        'name': 'gpt-4.1-mini',
        'mode': 'chat',
        'completion_params': {'top_p': 0.3},
      });
      expect(s.inputs['metadata_filtering_mode'], 'manual');
      expect(s.inputs['metadata_filtering_conditions'], {
        'logical_operator': 'or',
        'conditions': [
          {...second, 'comparison_operator': '>', 'value': 0.8},
        ],
      });
      // The string and number variable lists are the node's variables through these filters (NodeVars.filtered).
      expect(filterStringVar(_v(VarType.string), const []), isTrue);
      expect(filterStringVar(_v(VarType.number), const []), isFalse);
      expect(filterFileVar(_v(VarType.file), const []), isTrue);
      expect(filterFileVar(_v(VarType.arrayFile), const []), isTrue);
      expect(filterFileVar(_v(VarType.boolean), const []), isFalse);
    });

    test('keeps state unchanged when removing or updating a missing condition', () {
      final initial = payload({
        'metadata_filtering_conditions': {
          'logical_operator': 'and',
          'conditions': [
            {
              'id': 'condition-existing',
              'metadata_id': 'meta-1',
              'name': 'topic',
              'comparison_operator': 'is',
              'value': 'city',
            },
          ],
        },
        'metadata_model_config': {
          'provider': 'openai',
          'name': 'gpt-4.1-mini',
          'mode': 'chat',
          'completion_params': {'temperature': 0.7},
        },
      });
      final s = _State(initial);
      config(s)
        ..handleRemoveCondition('missing-condition')
        ..handleUpdateCondition('missing-condition', {
          'id': 'missing-condition',
          'metadata_id': 'meta-x',
          'name': 'missing',
          'comparison_operator': 'is not',
          'value': 'unused',
        });
      expect(s.calls[0], initial);
      expect(s.calls[1], initial);
    });

    test('falls back to chat mode, preserves completion params, and toggles or back to and', () {
      final s = _State(
        payload({
          'metadata_filtering_conditions': {
            'logical_operator': 'or',
            'conditions': [
              {
                'id': 'condition-existing',
                'metadata_id': 'meta-1',
                'name': 'topic',
                'comparison_operator': 'is',
                'value': 'city',
              },
            ],
          },
          'metadata_model_config': {
            'provider': 'openai',
            'name': 'gpt-4.1-mini',
            'mode': 'chat',
            'completion_params': {'temperature': 0.9},
          },
        }),
      );
      config(s)
        ..handleToggleConditionLogicalOperator()
        ..handleMetadataModelChange((provider: 'anthropic', modelId: 'claude-sonnet', mode: null));
      expect(jsGet(s.inputs['metadata_filtering_conditions'], 'logical_operator'), 'and');
      expect(s.inputs['metadata_model_config'], {
        'provider': 'anthropic',
        'name': 'claude-sonnet',
        'mode': 'chat',
        'completion_params': {'temperature': 0.9},
      });
    });

    test('handles missing metadata condition containers when removing or updating', () {
      final initial = payload();
      final s = _State(initial);
      config(s)
        ..handleRemoveCondition('missing-condition')
        ..handleUpdateCondition('missing-condition', {
          'id': 'missing-condition',
          'metadata_id': 'meta-x',
          'name': 'missing',
          'comparison_operator': 'is not',
          'value': 'unused',
        });
      expect(s.calls[0], initial);
      expect(s.calls[1], initial);
    });
  });

  group('use-knowledge-model-config', () {
    final selectedDatasets = [createDataset()];

    test('creates missing single retrieval config when the model or completion params change', () {
      final s = _State(_payload({'single_retrieval_config': null, 'multiple_retrieval_config': null}));
      final c = KrModelConfig(
        inputsOf: () => s.inputs,
        setInputs: s.setInputs,
        selectedDatasets: () => selectedDatasets,
      )..init();
      expect(s.calls.single['multiple_retrieval_config'], containsPair('top_k', DatasetDefault.topK));
      expect(s.calls.single['multiple_retrieval_config'], containsPair('reranking_enable', false));
      s.calls.clear();

      s.inputs = _payload({'retrieval_mode': 'single', 'single_retrieval_config': null});
      c.handleModelChanged((provider: 'anthropic', modelId: 'claude-sonnet', mode: null));
      expect(s.calls.single['single_retrieval_config'], {
        'model': {
          'provider': 'anthropic',
          'name': 'claude-sonnet',
          'mode': 'chat',
          'completion_params': <String, Object?>{},
        },
      });
      s.calls.clear();

      s.inputs = _payload({'retrieval_mode': 'single', 'single_retrieval_config': null});
      c
        ..handleCompletionParamsChange({'temperature': 0.2})
        ..handleCompletionParamsChange({'temperature': 0.2});
      expect(s.calls, hasLength(1));
      expect(s.calls.single['single_retrieval_config'], {
        'model': {
          'provider': '',
          'name': '',
          'mode': '',
          'completion_params': {'temperature': 0.2},
        },
      });
    });

    test('hydrates defaults, respects initialized rerank state, and updates retrieval config changes', () {
      const fallback = (provider: 'rerank-provider', model: 'rerank-model');
      const current = (provider: 'openai', model: 'gpt-4o-mini', mode: 'chat');
      final s = _State(
        _payload({'retrieval_mode': 'single', 'single_retrieval_config': null, 'multiple_retrieval_config': null}),
      );
      final c = KrModelConfig(
        inputsOf: () => s.inputs,
        setInputs: s.setInputs,
        selectedDatasets: () => selectedDatasets,
        currentModel: current,
        fallbackRerankModel: fallback,
        hasRerankDefaultModel: true,
      )..init();
      expect(s.calls.single['single_retrieval_config'], {
        'model': {
          'provider': 'openai',
          'name': 'gpt-4o-mini',
          'mode': 'chat',
          'completion_params': <String, Object?>{},
        },
      });
      expect(s.calls.single['multiple_retrieval_config'], containsPair('top_k', DatasetDefault.topK));
      expect(s.calls.single['multiple_retrieval_config'], containsPair('reranking_enable', true));
      s.calls.clear();

      c.handleRetrievalModeChange('multiple');
      final multiple = s.calls.single['multiple_retrieval_config'];
      expect(s.calls.single['retrieval_mode'], 'multiple');
      expect(multiple, containsPair('top_k', DatasetDefault.topK));
      expect(multiple, containsPair('reranking_enable', true));
      expect(multiple, containsPair('reranking_model', {'provider': 'rerank-provider', 'model': 'rerank-model'}));
      s.calls.clear();

      c.handleMultipleRetrievalConfigChange({'top_k': 8, 'score_threshold': 0.4});
      expect(s.calls.single['multiple_retrieval_config'], containsPair('top_k', 8));
      expect(s.calls.single['multiple_retrieval_config'], containsPair('score_threshold', 0.4));
      expect(s.calls.single['multiple_retrieval_config'], containsPair('reranking_enable', true));
      s.calls.clear();

      s.inputs = _payload({
        'single_retrieval_config': null,
        'multiple_retrieval_config': {'top_k': 5, 'score_threshold': 0.2},
      });
      c.handleRetrievalModeChange('single');
      expect(s.calls.single['retrieval_mode'], 'single');
      expect(s.calls.single['single_retrieval_config'], {
        'model': {
          'provider': 'openai',
          'name': 'gpt-4o-mini',
          'mode': 'chat',
          'completion_params': <String, Object?>{},
        },
      });

      final configured = _State(
        _payload({
          'retrieval_mode': 'single',
          'single_retrieval_config': {
            'model': {
              'provider': 'openai',
              'name': 'gpt-4o-mini',
              'mode': 'chat',
              'completion_params': <String, Object?>{},
            },
          },
          'multiple_retrieval_config': {
            'top_k': 6,
            'score_threshold': 0.1,
            'reranking_enable': true,
            'reranking_model': {'provider': 'rerank-provider', 'model': 'rerank-model'},
          },
        }),
      );
      KrModelConfig(
        inputsOf: () => configured.inputs,
        setInputs: configured.setInputs,
        selectedDatasets: () => selectedDatasets,
        currentModel: current,
        fallbackRerankModel: fallback,
        hasRerankDefaultModel: true,
      ).init();
      expect(configured.calls, isEmpty);
    });
  });

  group('knowledge-retrieval/use-config', () {
    final services = LlmGroupServices(
      models: const ModelCatalog(
        modelLists: {
          ModelTypeEnum.textGeneration: [
            ProviderWithModels(
              provider: 'openai',
              models: [
                ModelItem(model: 'gpt-4o-mini', modelProperties: {'mode': 'chat'}),
              ],
            ),
          ],
          ModelTypeEnum.rerank: [
            ProviderWithModels(
              provider: 'rerank-provider',
              models: [ModelItem(model: 'rerank-model', modelType: ModelTypeEnum.rerank)],
            ),
          ],
        },
      ),
      defaultModels: const {
        ModelTypeEnum.textGeneration: (provider: 'openai', model: 'gpt-4o-mini', mode: 'chat'),
        ModelTypeEnum.rerank: (provider: 'rerank-provider', model: 'rerank-model', mode: null),
      },
      fetchDatasets: (ids) async => [
        createDataset({'id': 'dataset-1', 'name': 'Knowledge Base', 'is_multimodal': true}),
      ],
    );
    Map<String, Object?> data([Map<String, Object?> o = const {}]) => {
      ..._payload({'multiple_retrieval_config': null, 'metadata_filtering_mode': 'disabled'}),
      'query_attachment_selector': ['start', 'files'],
      ...o,
    };
    Future<Harness> start(WidgetTester t, [Map<String, Object?> o = const {}]) =>
        startKrPanel(t, data(o), services: services, chatMode: true);
    RetrievalConfig retrieval(WidgetTester t) => t.widget<RetrievalConfig>(find.byType(RetrievalConfig));

    testWidgets('initializes defaults, loads dataset details, and exposes metadata variables', (t) async {
      final h = await start(t);
      expect(find.text('Knowledge Base'), findsOneWidget);
      final d = dataOf(h, 'kr');
      expect(d['query_variable_selector'], ['start', 'sys.query']);
      expect(d['multiple_retrieval_config'], containsPair('top_k', DatasetDefault.topK));
      expect(d['multiple_retrieval_config'], containsPair('reranking_enable', true));
      // The multimodal dataset shows the Query Images picker.
      expect(find.byType(VarReferencePicker), findsNWidgets(2));
      await h.dispose(t);
    });

    testWidgets('updates query and single retrieval model state through the real hook', (t) async {
      final h = await start(t);
      final pickers = t.widgetList<VarReferencePicker>(find.byType(VarReferencePicker)).toList();
      pickers[0].onChange(['start', 'question'], null);
      await settle(t);
      pickers[1].onChange(['start', 'files'], null);
      await settle(t);
      retrieval(t).onRetrievalModeChange('single');
      await settle(t);
      retrieval(t).onSingleRetrievalModelChange!((
        provider: 'anthropic',
        modelId: 'claude-sonnet',
        mode: 'chat',
        features: const [],
      ));
      await settle(t);
      retrieval(t).onSingleRetrievalModelParamsChange!({'temperature': 0.2});
      retrieval(t).onSingleRetrievalModelParamsChange!({'temperature': 0.2});
      await settle(t);
      final d = dataOf(h, 'kr');
      expect(d['query_variable_selector'], ['start', 'question']);
      expect(d['query_attachment_selector'], ['start', 'files']);
      expect(d['retrieval_mode'], 'single');
      expect(jsGet(d['single_retrieval_config'], 'model'), {
        'provider': 'anthropic',
        'name': 'claude-sonnet',
        'mode': 'chat',
        'completion_params': {'temperature': 0.2},
      });
      await h.dispose(t);
    });

    testWidgets('updates retrieval config and dataset state through the real hook', (t) async {
      final updated = <List<Map<String, Object?>>>[];
      final h = await startKrPanel(
        t,
        data(),
        services: LlmGroupServices(
          models: services.models,
          defaultModels: services.defaultModels,
          fetchDatasets: services.fetchDatasets,
          updateDatasetsDetail: updated.add,
        ),
        chatMode: true,
      );
      retrieval(t).onRetrievalModeChange('single');
      await settle(t);
      retrieval(t).onRetrievalModeChange('multiple');
      await settle(t);
      retrieval(t).onMultipleRetrievalConfigChange({'top_k': 8, 'score_threshold': 0.4});
      await settle(t);
      expect(dataOf(h, 'kr')['multiple_retrieval_config'], containsPair('top_k', 8));
      expect(dataOf(h, 'kr')['multiple_retrieval_config'], containsPair('score_threshold', 0.4));
      t.widget<DatasetList>(find.byType(DatasetList)).onChange([
        createDataset({'id': 'dataset-2', 'name': 'Economic', 'indexing_technique': 'economy'}),
        createDataset({'id': 'dataset-3', 'name': 'High Quality'}),
      ]);
      await settle(t);
      final d = dataOf(h, 'kr');
      expect(d['retrieval_mode'], 'multiple');
      expect(d['query_attachment_selector'], <String>[]);
      expect(d['dataset_ids'], ['dataset-2', 'dataset-3']);
      expect(d['multiple_retrieval_config'], containsPair('reranking_enable', true));
      expect(
        d['multiple_retrieval_config'],
        containsPair('reranking_model', {'provider': 'rerank-provider', 'model': 'rerank-model'}),
      );
      expect(retrieval(t).open, isTrue);
      expect([for (final d in updated.single) d['id']], ['dataset-2', 'dataset-3']);
      await h.dispose(t);
    });

    testWidgets('manages metadata conditions, metadata model config, and variable filters', (t) async {
      // MetadataTrigger drops conditions whose metadata the datasets lack: the dataset has both fields.
      final h = await startKrPanel(
        t,
        data(),
        services: LlmGroupServices(
          models: services.models,
          defaultModels: services.defaultModels,
          fetchDatasets: (ids) async => [
            createDataset({
              'doc_metadata': [
                createMetadata(),
                createMetadata({'id': 'meta-2', 'name': 'score', 'type': 'number'}),
              ],
            }),
          ],
        ),
        chatMode: true,
      );
      final filter = t.widget<MetadataFilter>(find.byType(MetadataFilter));
      filter.onModeChange('manual');
      await settle(t);
      var shape = t.widget<MetadataFilter>(find.byType(MetadataFilter)).shape;
      shape.onAddCondition(createMetadata());
      await settle(t);
      shape = t.widget<MetadataFilter>(find.byType(MetadataFilter)).shape;
      shape.onAddCondition(createMetadata({'id': 'meta-2', 'name': 'score', 'type': 'number'}));
      await settle(t);
      var d = dataOf(h, 'kr');
      expect(d['metadata_filtering_mode'], 'manual');
      final conditions = jsList(jsGet(d['metadata_filtering_conditions'], 'conditions'));
      expect(conditions, hasLength(2));
      final first = jsMap(conditions.first);
      shape = t.widget<MetadataFilter>(find.byType(MetadataFilter)).shape;
      shape.onUpdateCondition('${first['id']}', {...first, 'value': 'agent', 'comparison_operator': 'contains'});
      await settle(t);
      t.widget<MetadataFilter>(find.byType(MetadataFilter)).shape.onToggleLogicalOperator();
      await settle(t);
      t.widget<MetadataFilter>(find.byType(MetadataFilter)).shape.onRemoveCondition('${first['id']}');
      await settle(t);
      final f = t.widget<MetadataFilter>(find.byType(MetadataFilter));
      f.onModelChange!((provider: 'openai', modelId: 'gpt-4.1-mini', mode: 'chat', features: const []));
      await settle(t);
      t.widget<MetadataFilter>(find.byType(MetadataFilter)).onCompletionParamsChange!({'top_p': 0.3});
      await settle(t);
      d = dataOf(h, 'kr');
      expect(jsGet(d['metadata_filtering_conditions'], 'logical_operator'), 'or');
      expect(jsList(jsGet(d['metadata_filtering_conditions'], 'conditions')), hasLength(1));
      expect(d['metadata_model_config'], {
        'provider': 'openai',
        'name': 'gpt-4.1-mini',
        'mode': 'chat',
        'completion_params': {'top_p': 0.3},
      });
      expect(filterStringVar(_v(VarType.string), const []), isTrue);
      expect(filterStringVar(_v(VarType.number), const []), isFalse);
      expect(filterFileVar(_v(VarType.file), const []), isTrue);
      expect(filterFileVar(_v(VarType.arrayFile), const []), isTrue);
      expect(filterFileVar(_v(VarType.string), const []), isFalse);
      await h.dispose(t);
    });
  });
}
