// dify-spec: web/app/components/workflow/nodes/knowledge-base/__tests__/utils.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-base/__tests__/default.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-base/hooks/__tests__/use-config.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/hooks/__tests__/use-embedding-model-status.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-base/hooks/__tests__/use-settings-display.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-base/__tests__/use-single-run-form-params.spec.ts
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/chunk-structure/__tests__/hooks.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/retrieval-setting/__tests__/hooks.spec.tsx
//
// The pure logic of the Knowledge Base node: use-config's handlers return the partial data Dify hands to
// handleNodeDataUpdateWithSyncDraft (each call reads the node's unchanged data, as the mocked update leaves it).
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/kb_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_logic.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kb_harness.dart';

/// `withSelectorKey((key) => key)`: the key alone.
String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;

List<Map<String, Object?>> _embeddingModelList(String status, {String model = 'gpt-4o'}) => [
  {
    'tenant_id': 'test-workspace',
    'provider': 'openai',
    'icon_small': {'en_US': '', 'zh_Hans': ''},
    'label': {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
    'models': [_providerModel(status, model: model)],
    'status': 'active',
  },
];

Map<String, Object?> _providerModel(String status, {String model = 'gpt-4o'}) => {
  'model': model,
  'label': {'en_US': 'GPT-4o', 'zh_Hans': 'GPT-4o'},
  'model_type': ModelTypeEnum.textEmbedding,
  'fetch_from': 'predefined-model',
  'status': status,
  'model_properties': <String, Object?>{},
  'load_balancing_enabled': false,
};

Map<String, Object?> makePayload([Map<String, Object?> overrides = const {}]) => {
  'index_chunk_variable_selector': ['general_chunks', 'results'],
  'chunk_structure': ChunkStructure.general,
  'indexing_technique': IndexMethod.qualified,
  'embedding_model': 'gpt-4o',
  'embedding_model_provider': 'openai',
  'keyword_number': 10,
  'retrieval_model': {
    'top_k': 3,
    'score_threshold_enabled': false,
    'score_threshold': 0.5,
    'search_method': SearchMethod.semantic,
  },
  '_embeddingModelList': _embeddingModelList(ModelStatusEnum.active),
  '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.active)],
  '_rerankModelList': <Object?>[],
  ...overrides,
};

/// use-config.spec's createNodeData.
Map<String, Object?> createNodeData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Knowledge Base',
  'desc': '',
  'type': 'knowledge-base',
  'index_chunk_variable_selector': ['chunks', 'results'],
  'chunk_structure': ChunkStructure.general,
  'indexing_technique': IndexMethod.qualified,
  'embedding_model': 'text-embedding-3-large',
  'embedding_model_provider': 'openai',
  'keyword_number': 3,
  'retrieval_model': {
    'search_method': SearchMethod.semantic,
    'reranking_enable': false,
    'reranking_mode': HybridSearchMode.rerankingModel,
    'reranking_model': {'reranking_provider_name': '', 'reranking_model_name': ''},
    'top_k': 3,
    'score_threshold_enabled': false,
    'score_threshold': 0.5,
  },
  'summary_index_setting': {'enable': false, 'summary_prompt': 'existing prompt'},
  ...overrides,
};

/// `expect.objectContaining`: every entry of [expected] is in the map (recursively for maps).
Matcher containing(Map<String, Object?> expected) => predicate<Object?>((actual) {
  if (actual is! Map) return false;
  for (final e in expected.entries) {
    if (!actual.containsKey(e.key)) return false;
    final v = e.value;
    if (v is Matcher) {
      if (!v.matches(actual[e.key], {})) return false;
    } else if (!equals(v).matches(actual[e.key], {})) {
      return false;
    }
  }
  return true;
}, 'contains $expected');

void main() {
  group('knowledge-base validation issue', () {
    test('identifies high quality retrieval methods', () {
      expect(isHighQualitySearchMethod(SearchMethod.semantic), isTrue);
      expect(isHighQualitySearchMethod(SearchMethod.hybrid), isTrue);
      expect(isHighQualitySearchMethod(SearchMethod.fullText), isTrue);
      expect(isHighQualitySearchMethod('unknown-method'), isFalse);
    });

    test('returns chunk structure issue when chunk structure is missing', () {
      expect(
        knowledgeBaseValidationIssue(makePayload({'chunk_structure': null}))?.code,
        KnowledgeBaseIssue.chunkStructureRequired.code,
      );
    });

    test('returns chunks variable issue when chunks selector is empty', () {
      expect(
        knowledgeBaseValidationIssue(makePayload({'index_chunk_variable_selector': <Object?>[]})),
        KnowledgeBaseIssue.chunksVariableRequired,
      );
    });

    test('maps no-configure to configure required', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.noConfigure)],
        }),
      );
      expect(issue, KnowledgeBaseIssue.embeddingModelConfigureRequired);
    });

    test('maps credential-removed to API key unavailable', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.credentialRemoved)],
        }),
      );
      expect(issue, KnowledgeBaseIssue.embeddingModelApiKeyUnavailable);
    });

    test('maps quota-exceeded to credits exhausted', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.quotaExceeded)],
        }),
      );
      expect(issue, KnowledgeBaseIssue.embeddingModelCreditsExhausted);
    });

    test('maps disabled to disabled', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.disabled)],
        }),
      );
      expect(issue, KnowledgeBaseIssue.embeddingModelDisabled);
    });

    test('maps missing provider plugin to incompatible when embedding model is already configured', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({'embedding_model_provider': 'missing-provider', '_embeddingProviderModelList': null}),
      );
      expect(issue, KnowledgeBaseIssue.embeddingModelIncompatible);
    });

    test('falls back to provider model list when provider scoped model list is empty', () {
      expect(knowledgeBaseValidationIssue(makePayload({'_embeddingProviderModelList': <Object?>[]})), isNull);
    });

    test('returns embedding-model-not-configured when the qualified index is missing provider details', () {
      expect(
        knowledgeBaseValidationIssue(makePayload({'embedding_model': null})),
        KnowledgeBaseIssue.embeddingModelNotConfigured,
      );
    });

    test('maps no-permission embedding models to incompatible', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.noPermission)],
        }),
      );
      expect(issue, KnowledgeBaseIssue.embeddingModelIncompatible);
    });

    test('returns retrieval-setting-required when retrieval search method is missing', () {
      expect(
        knowledgeBaseValidationIssue(makePayload({'retrieval_model': null})),
        KnowledgeBaseIssue.retrievalSettingRequired,
      );
    });

    test('returns reranking-model-required when reranking is enabled without a model', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          'retrieval_model': {...makePayload()['retrieval_model']! as Map, 'reranking_enable': true},
        }),
      );
      expect(issue, KnowledgeBaseIssue.rerankingModelRequired);
    });

    test('returns reranking-model-invalid when the configured reranking model is unavailable', () {
      final issue = knowledgeBaseValidationIssue(
        makePayload({
          'retrieval_model': {
            ...makePayload()['retrieval_model']! as Map,
            'reranking_enable': true,
            'reranking_model': {'reranking_provider_name': 'missing-provider', 'reranking_model_name': 'missing-model'},
          },
        }),
      );
      expect(issue, KnowledgeBaseIssue.rerankingModelInvalid);
    });
  });

  group('knowledge-base validation messaging', () {
    test('maps %s to the expected translation key', () {
      const cases = {
        KnowledgeBaseIssue.chunkStructureRequired: 'nodes.knowledgeBase.chunkIsRequired',
        KnowledgeBaseIssue.chunksVariableRequired: 'nodes.knowledgeBase.chunksVariableIsRequired',
        KnowledgeBaseIssue.indexMethodRequired: 'nodes.knowledgeBase.indexMethodIsRequired',
        KnowledgeBaseIssue.embeddingModelNotConfigured: 'nodes.knowledgeBase.embeddingModelNotConfigured',
        KnowledgeBaseIssue.embeddingModelConfigureRequired: 'modelProvider.selector.configureRequired',
        KnowledgeBaseIssue.embeddingModelApiKeyUnavailable: 'modelProvider.selector.apiKeyUnavailable',
        KnowledgeBaseIssue.embeddingModelCreditsExhausted: 'modelProvider.selector.creditsExhausted',
        KnowledgeBaseIssue.embeddingModelDisabled: 'modelProvider.selector.disabled',
        KnowledgeBaseIssue.embeddingModelIncompatible: 'modelProvider.selector.incompatible',
        KnowledgeBaseIssue.retrievalSettingRequired: 'nodes.knowledgeBase.retrievalSettingIsRequired',
        KnowledgeBaseIssue.rerankingModelRequired: 'nodes.knowledgeBase.rerankingModelIsRequired',
        KnowledgeBaseIssue.rerankingModelInvalid: 'nodes.knowledgeBase.rerankingModelIsInvalid',
      };
      for (final MapEntry(key: code, value: expectedKey) in cases.entries) {
        expect(knowledgeBaseValidationMessage(code, t), expectedKey, reason: code.code);
      }
    });

    test('returns an empty string when there is no issue', () {
      expect(knowledgeBaseValidationMessage(null, t), '');
    });
  });

  group('knowledge-base default node validation', () {
    Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
      ...knowledgeBaseDefaultValue,
      'index_chunk_variable_selector': ['chunks', 'results'],
      'chunk_structure': ChunkStructure.general,
      'indexing_technique': IndexMethod.qualified,
      'embedding_model': 'text-embedding-3-large',
      'embedding_model_provider': 'openai',
      'retrieval_model': {
        ...knowledgeBaseDefaultValue['retrieval_model']! as Map,
        'search_method': SearchMethod.semantic,
      },
      '_embeddingModelList': _embeddingModelList(ModelStatusEnum.active, model: 'text-embedding-3-large'),
      '_embeddingProviderModelList': [_providerModel(ModelStatusEnum.active, model: 'text-embedding-3-large')],
      '_rerankModelList': <Object?>[],
      ...overrides,
    };

    test('should return an invalid result when the payload has a validation issue', () {
      expect(
        checkValidKnowledgeBase(createPayload({'chunk_structure': null}), t, null),
        'nodes.knowledgeBase.chunkIsRequired',
      );
    });

    test('should return a valid result when the payload is complete', () {
      expect(checkValidKnowledgeBase(createPayload(), t, null), '');
    });
  });

  group('useConfig', () {
    test('should preserve the current chunk variable selector when the chunk structure does not change', () {
      expect(
        KnowledgeBaseConfig(createNodeData()).chunkStructureChange(ChunkStructure.general),
        containing({
          'chunk_structure': ChunkStructure.general,
          'index_chunk_variable_selector': ['chunks', 'results'],
        }),
      );
    });

    test('should reset chunk variables and keep a high-quality search method when switching chunk structures', () {
      final data = createNodeData({
        'retrieval_model': {
          'search_method': SearchMethod.keywordSearch,
          'reranking_enable': false,
          'top_k': 3,
          'score_threshold_enabled': false,
          'score_threshold': 0.5,
        },
      });
      expect(
        KnowledgeBaseConfig(data).chunkStructureChange(ChunkStructure.parentChild),
        containing({
          'chunk_structure': ChunkStructure.parentChild,
          'indexing_technique': IndexMethod.qualified,
          'index_chunk_variable_selector': <Object?>[],
          'retrieval_model': containing({'search_method': SearchMethod.keywordSearch}),
        }),
      );
    });

    test(
      'should preserve semantic search when switching to a structured chunk mode from a high-quality search method',
      () {
        final data = createNodeData({
          'retrieval_model': {
            'search_method': SearchMethod.semantic,
            'reranking_enable': false,
            'top_k': 3,
            'score_threshold_enabled': false,
            'score_threshold': 0.5,
          },
        });
        expect(
          KnowledgeBaseConfig(data).chunkStructureChange(ChunkStructure.questionAnswer),
          containing({
            'chunk_structure': ChunkStructure.questionAnswer,
            'retrieval_model': containing({'search_method': SearchMethod.semantic}),
          }),
        );
      },
    );

    test('should update the index method and keyword number', () {
      final config = KnowledgeBaseConfig(createNodeData());
      expect(
        config.indexMethodChange(IndexMethod.economical),
        containing({
          'indexing_technique': IndexMethod.economical,
          'retrieval_model': containing({'search_method': SearchMethod.keywordSearch}),
        }),
      );
      expect(
        config.indexMethodChange(IndexMethod.qualified),
        containing({
          'indexing_technique': IndexMethod.qualified,
          'retrieval_model': containing({'search_method': SearchMethod.semantic}),
        }),
      );
      expect(config.keywordNumberChange(9), {'keyword_number': 9});
    });

    test(
      'should create default weights when embedding weights are missing and default reranking mode when switching away from hybrid',
      () {
        final config = KnowledgeBaseConfig(
          createNodeData({
            'retrieval_model': {
              'search_method': SearchMethod.semantic,
              'reranking_enable': false,
              'top_k': 3,
              'score_threshold_enabled': false,
              'score_threshold': 0.5,
            },
          }),
        );
        expect(
          config.embeddingModelChange(embeddingModel: 'text-embedding-3-small', embeddingModelProvider: 'openai'),
          containing({
            'retrieval_model': containing({
              'weights': containing({
                'vector_setting': containing({
                  'embedding_provider_name': 'openai',
                  'embedding_model_name': 'text-embedding-3-small',
                }),
                'keyword_setting': containing({'keyword_weight': 0.3}),
              }),
            }),
          }),
        );
        expect(
          config.retrievalSearchMethodChange(SearchMethod.fullText),
          containing({
            'retrieval_model': containing({
              'search_method': SearchMethod.fullText,
              'reranking_mode': HybridSearchMode.rerankingModel,
            }),
          }),
        );
      },
    );

    test('should update embedding model weights and retrieval search method defaults', () {
      final config = KnowledgeBaseConfig(
        createNodeData({
          'retrieval_model': {
            'search_method': SearchMethod.semantic,
            'reranking_enable': false,
            'reranking_mode': HybridSearchMode.rerankingModel,
            'reranking_model': {'reranking_provider_name': '', 'reranking_model_name': ''},
            'weights': {
              'weight_type': WeightedScoreType.customized,
              'vector_setting': {
                'vector_weight': 0.8,
                'embedding_provider_name': 'openai',
                'embedding_model_name': 'text-embedding-3-large',
              },
              'keyword_setting': {'keyword_weight': 0.2},
            },
            'top_k': 3,
            'score_threshold_enabled': false,
            'score_threshold': 0.5,
          },
        }),
      );
      expect(
        config.embeddingModelChange(embeddingModel: 'text-embedding-3-small', embeddingModelProvider: 'openai'),
        containing({
          'embedding_model': 'text-embedding-3-small',
          'embedding_model_provider': 'openai',
          'retrieval_model': containing({
            'weights': containing({
              'vector_setting': containing({
                'embedding_provider_name': 'openai',
                'embedding_model_name': 'text-embedding-3-small',
              }),
            }),
          }),
        }),
      );
      expect(
        config.retrievalSearchMethodChange(SearchMethod.hybrid),
        containing({
          'retrieval_model': containing({
            'search_method': SearchMethod.hybrid,
            'reranking_mode': HybridSearchMode.rerankingModel,
            'reranking_enable': true,
          }),
        }),
      );
    });

    test('should seed hybrid weights and propagate retrieval tuning updates', () {
      final config = KnowledgeBaseConfig(
        createNodeData({
          'retrieval_model': {
            'search_method': SearchMethod.hybrid,
            'reranking_enable': false,
            'top_k': 3,
            'score_threshold_enabled': false,
            'score_threshold': 0.5,
          },
        }),
      );
      expect(
        config.hybridSearchModeChange(HybridSearchMode.weightedScore),
        containing({
          'retrieval_model': containing({
            'reranking_mode': HybridSearchMode.weightedScore,
            'reranking_enable': false,
            'weights': containing({
              'vector_setting': containing({
                'embedding_provider_name': 'openai',
                'embedding_model_name': 'text-embedding-3-large',
              }),
            }),
          }),
        }),
      );
      expect(
        config.rerankingModelEnabledChange(true),
        containing({
          'retrieval_model': containing({'reranking_enable': true}),
        }),
      );
      expect(
        config.weightedScoreChange([0.6, 0.4]),
        containing({
          'retrieval_model': containing({
            'weights': containing({
              'weight_type': WeightedScoreType.customized,
              'vector_setting': containing({'vector_weight': 0.6}),
              'keyword_setting': containing({'keyword_weight': 0.4}),
            }),
          }),
        }),
      );
      expect(
        config.rerankingModelChange(providerName: 'cohere', modelName: 'rerank-v3'),
        containing({
          'retrieval_model': containing({
            'reranking_model': {'reranking_provider_name': 'cohere', 'reranking_model_name': 'rerank-v3'},
          }),
        }),
      );
      expect(
        config.topKChange(8),
        containing({
          'retrieval_model': containing({'top_k': 8}),
        }),
      );
      expect(
        config.scoreThresholdChange(0.75),
        containing({
          'retrieval_model': containing({'score_threshold': 0.75}),
        }),
      );
      expect(
        config.scoreThresholdEnabledChange(true),
        containing({
          'retrieval_model': containing({'score_threshold_enabled': true}),
        }),
      );
    });

    test('should reuse existing hybrid weights and allow empty embedding defaults', () {
      final config = KnowledgeBaseConfig(
        createNodeData({
          'embedding_model': null,
          'embedding_model_provider': null,
          'retrieval_model': {
            'search_method': SearchMethod.hybrid,
            'reranking_enable': false,
            'reranking_mode': HybridSearchMode.weightedScore,
            'weights': {
              'weight_type': WeightedScoreType.customized,
              'vector_setting': {
                'vector_weight': 0.9,
                'embedding_provider_name': 'existing-provider',
                'embedding_model_name': 'existing-model',
              },
              'keyword_setting': {'keyword_weight': 0.1},
            },
            'top_k': 3,
            'score_threshold_enabled': false,
            'score_threshold': 0.5,
          },
        }),
      );
      expect(
        config.hybridSearchModeChange(HybridSearchMode.rerankingModel),
        containing({
          'retrieval_model': containing({
            'reranking_mode': HybridSearchMode.rerankingModel,
            'reranking_enable': true,
            'weights': containing({
              'vector_setting': containing({
                'embedding_provider_name': 'existing-provider',
                'embedding_model_name': 'existing-model',
              }),
            }),
          }),
        }),
      );
      expect(
        config.embeddingModelChange(embeddingModel: 'fallback-model', embeddingModelProvider: ''),
        containing({
          'embedding_model': 'fallback-model',
          'embedding_model_provider': '',
          'retrieval_model': containing({
            'weights': containing({
              'vector_setting': containing({'embedding_provider_name': '', 'embedding_model_name': 'fallback-model'}),
            }),
          }),
        }),
      );
    });

    test('should normalize input variables and merge summary index settings', () {
      final config = KnowledgeBaseConfig(createNodeData());
      expect(config.inputVariableChange('chunks'), {'index_chunk_variable_selector': <Object?>[]});
      expect(config.inputVariableChange(['payload', 'chunks']), {
        'index_chunk_variable_selector': ['payload', 'chunks'],
      });
      expect(config.summaryIndexSettingChange({'enable': true}), {
        'summary_index_setting': {'enable': true, 'summary_prompt': 'existing prompt'},
      });
    });
  });

  group('useEmbeddingModelStatus', () {
    // providerSummaryFixture with text-embedding support.
    const providers = [
      ModelProvider(provider: 'openai', supportedModelTypes: [ModelTypeEnum.textEmbedding]),
    ];

    group('Resolution', () {
      test('should return the matched provider, current model, and active status', () {
        final r = embeddingModelStatus(
          embeddingModel: 'text-embedding-3-large',
          embeddingModelProvider: 'openai',
          embeddingModelList: [createModel()],
          providers: providers,
          credentialPanelOf: (_) => createCredentialState(),
        );
        expect(r.providerMeta?.provider, 'openai');
        expect(r.modelProvider?.provider, 'openai');
        expect(r.currentModel?.model, 'text-embedding-3-large');
        expect(r.status, DerivedModelStatus.active);
      });

      test('should return incompatible when the provider exists but the selected model is missing', () {
        final r = embeddingModelStatus(
          embeddingModel: 'text-embedding-3-large',
          embeddingModelProvider: 'openai',
          embeddingModelList: [
            createModel({
              'models': [
                createModelItemJson({'model': 'another-model'}),
              ],
            }),
          ],
          providers: providers,
          credentialPanelOf: (_) => createCredentialState(),
        );
        expect(r.providerMeta?.provider, 'openai');
        expect(r.currentModel, isNull);
        expect(r.status, DerivedModelStatus.incompatible);
      });

      test('should return empty when no embedding model is configured', () {
        final r = embeddingModelStatus(
          embeddingModelList: const [],
          providers: providers,
          credentialPanelOf: (_) => createCredentialState(),
        );
        expect(r.providerMeta, isNull);
        expect(r.modelProvider, isNull);
        expect(r.currentModel, isNull);
        expect(r.status, DerivedModelStatus.empty);
      });
    });
  });

  group('useSettingsDisplay', () {
    setUp(useKbTestTranslator);

    group('Translations', () {
      test('should return translated labels for each supported setting key', () {
        final display = knowledgeBaseSettingsDisplay();
        expect(display[IndexMethod.qualified], 'datasetCreation.stepTwo.qualified');
        expect(display[IndexMethod.economical], 'datasetSettings.form.indexMethodEconomy');
        expect(display[SearchMethod.semantic], 'dataset.retrieval.semantic_search.title');
        expect(display[SearchMethod.fullText], 'dataset.retrieval.full_text_search.title');
        expect(display[SearchMethod.hybrid], 'dataset.retrieval.hybrid_search.title');
        expect(display[SearchMethod.keywordSearch], 'dataset.retrieval.keyword_search.title');
      });
    });
  });

  group('useSingleRunFormParams', () {
    setUp(useKbTestTranslator);

    Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
      'title': 'Knowledge Base',
      'desc': '',
      'type': 'knowledge-index',
      'index_chunk_variable_selector': ['chunks', 'results'],
      'chunk_structure': ChunkStructure.general,
      'indexing_technique': IndexMethod.qualified,
      'embedding_model': 'text-embedding-3-large',
      'embedding_model_provider': 'openai',
      'keyword_number': 10,
      'retrieval_model': {
        'search_method': SearchMethod.semantic,
        'reranking_enable': false,
        'top_k': 3,
        'score_threshold_enabled': false,
        'score_threshold': 0.5,
      },
      ...overrides,
    };

    group('Forms', () {
      test('should build the query form with the current run input value', () {
        final r = knowledgeBaseSingleRunFormParams(
          payload: createPayload(),
          runInputData: {'query': 'what is dify'},
          setRunInputData: (_) {},
        );
        expect(r.forms, hasLength(1));
        expect(r.forms[0].inputs, [
          {'label': 'workflow.nodes.common.inputVars', 'variable': 'query', 'type': 'paragraph', 'required': true},
        ]);
        expect(r.forms[0].values, {'query': 'what is dify'});
      });

      test('should update run input data when the query changes', () {
        final calls = <Map<String, Object?>>[];
        final r = knowledgeBaseSingleRunFormParams(
          payload: createPayload(),
          runInputData: {'query': 'old query'},
          setRunInputData: calls.add,
        );
        r.forms[0].onChange({'query': 'new query'});
        expect(calls, [
          {'query': 'new query'},
        ]);
      });
    });

    group('Dependencies', () {
      test('should expose the chunk selector as the only dependent variable', () {
        final r = knowledgeBaseSingleRunFormParams(
          payload: createPayload({
            'index_chunk_variable_selector': ['node-1', 'chunks'],
          }),
          runInputData: const {},
          setRunInputData: (_) {},
        );
        expect(r.getDependentVars(), [
          ['node-1', 'chunks'],
        ]);
        expect(r.getDependentVar('query'), ['node-1', 'chunks']);
        expect(r.getDependentVar('other'), isNull);
      });
    });
  });

  group('useChunkStructure', () {
    setUp(useKbTestTranslator);

    group('Options', () {
      test('should return all chunk structure options and map them by id', () {
        final options = chunkStructureOptions();
        expect(options, hasLength(3));
        expect(
          [for (final o in options) o.id],
          [
            ChunkStructure.general,
            ChunkStructure.parentChild,
            ChunkStructure.questionAnswer,
          ],
        );
        final byId = {for (final o in options) o.id: o};
        expect(byId[ChunkStructure.general]!.title, 'datasetCreation.stepTwo.general');
        expect(byId[ChunkStructure.parentChild]!.title, 'datasetCreation.stepTwo.parentChild');
        expect(byId[ChunkStructure.questionAnswer]!.title, 'Q&A');
      });

      test('should expose active and inactive icon renderers for every option', () {
        final byId = {for (final o in chunkStructureOptions()) o.id: o};
        Color color(String id, bool active) =>
            KbOptionIcon(icon: byId[id]!.icon, activeColor: Color(byId[id]!.activeColor), highlighted: active).color;
        expect(color(ChunkStructure.general, false), DifyColors.textTertiary);
        expect(color(ChunkStructure.general, true), DifyColors.utilColorsIndigoIndigo600);
        expect(color(ChunkStructure.parentChild, true), DifyColors.utilColorsBlueLightBlueLight500);
        expect(color(ChunkStructure.questionAnswer, true), DifyColors.utilColorsTealTeal600);
      });
    });
  });

  group('useRetrievalSetting', () {
    group('Options', () {
      test('should return semantic, full-text, and hybrid options for qualified indexing', () {
        expect(
          [for (final o in retrievalOptions(IndexMethod.qualified)) o.id],
          [
            SearchMethod.semantic,
            SearchMethod.fullText,
            SearchMethod.hybrid,
          ],
        );
        expect(
          [for (final o in hybridSearchModeOptions()) o.id],
          [
            HybridSearchMode.weightedScore,
            HybridSearchMode.rerankingModel,
          ],
        );
      });

      test('should return only keyword search for economical indexing', () {
        expect([for (final o in retrievalOptions(IndexMethod.economical)) o.id], [SearchMethod.keywordSearch]);
      });
    });
  });
}
