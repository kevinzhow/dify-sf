// Knowledge Retrieval behaviour beyond Dify's specs: utils.ts's retrieval rules, the input normalisation, the
// metadata condition helpers and the retrieval settings popover driven through the panel.
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_retrieval_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'kr_fixtures.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('getSelectedDatasetsMode', () {
    test('classifies the datasets mix', () {
      expect(getSelectedDatasetsMode().allHighQuality, isFalse);
      final hq = getSelectedDatasetsMode([
        createDataset(),
        createDataset({'id': 'b'}),
      ]);
      expect(hq.allHighQuality && hq.allHighQualityVectorSearch && hq.allInternal, isTrue);
      expect(hq.inconsistentEmbeddingModel, isFalse);
      final mixed = getSelectedDatasetsMode([
        createDataset(),
        createDataset({'id': 'b', 'indexing_technique': 'economy'}),
      ]);
      expect(mixed.mixtureHighQualityAndEconomic, isTrue);
      final ext = getSelectedDatasetsMode([
        createDataset(),
        createDataset({'id': 'x', 'provider': 'external'}),
      ]);
      expect(ext.mixtureInternalAndExternal, isTrue);
      final embeddings = getSelectedDatasetsMode([
        createDataset(),
        createDataset({'id': 'b', 'embedding_model': 'other'}),
      ]);
      expect(embeddings.inconsistentEmbeddingModel, isTrue);
    });
  });

  group('getMultipleRetrievalConfig', () {
    test('all high quality without a rerank model falls back to weighted score with default weights', () {
      final c = getMultipleRetrievalConfig({'top_k': 4}, [createDataset()], [createDataset()]);
      expect(c['reranking_mode'], RerankingMode.weightedScore);
      expect(c['reranking_enable'], isFalse);
      expect(c['weights'], {
        'weight_type': 'customized',
        'vector_setting': {
          'vector_weight': 1.0,
          'embedding_provider_name': 'openai',
          'embedding_model_name': 'text-embedding-3',
        },
        'keyword_setting': {'keyword_weight': 0.0},
      });
    });

    test('weighted score switches to the rerank model when the datasets change and a model exists', () {
      final c = getMultipleRetrievalConfig(
        {
          'top_k': 4,
          'reranking_mode': RerankingMode.weightedScore,
          'weights': <String, Object?>{'a': 1},
        },
        [
          createDataset({'id': 'new'}),
        ],
        [createDataset()],
        (provider: 'p', model: 'm'),
      );
      expect(c['reranking_mode'], RerankingMode.rerankingModel);
      expect(c['reranking_enable'], isTrue);
      expect(c['reranking_model'], {'provider': 'p', 'model': 'm'});
    });

    test('all economic keeps the user rerank switch', () {
      final c = getMultipleRetrievalConfig(
        {'top_k': 2, 'reranking_enable': false},
        [
          createDataset({'indexing_technique': 'economy'}),
        ],
        const [],
        (provider: 'p', model: 'm'),
      );
      expect(c['reranking_mode'], RerankingMode.rerankingModel);
      expect(c['reranking_enable'], isFalse);
      expect(c['top_k'], 2);
    });
  });

  group('inputs and conditions', () {
    test('normalisation drops the inactive mode config', () {
      expect(
        normalizeKrInputs({'retrieval_mode': 'multiple', 'single_retrieval_config': 1, 'multiple_retrieval_config': 2}),
        {
          'retrieval_mode': 'multiple',
          'multiple_retrieval_config': 2,
        },
      );
      expect(
        normalizeKrInputs({'retrieval_mode': 'single', 'single_retrieval_config': 1, 'multiple_retrieval_config': 2}),
        {
          'retrieval_mode': 'single',
          'single_retrieval_config': 1,
        },
      );
    });

    test('a variable value is read back as its path, other values as constants', () {
      expect(conditionValueAndMethod('{{#node.var#}}', 'string'), (value: 'node.var', valueMethod: 'variable'));
      expect(conditionValueAndMethod('plain', 'string'), (value: 'plain', valueMethod: 'constant'));
      expect(conditionValueAndMethod(3, 'number'), (value: 3, valueMethod: 'constant'));
      expect(getMetadataOperators('number'), contains('≥'));
      expect(comparisonOperatorNotRequireValue('empty'), isTrue);
      expect(
        metadataIntersection([
          createDataset({
            'doc_metadata': [
              createMetadata(),
              createMetadata({'name': 'b'}),
            ],
          }),
          createDataset({
            'doc_metadata': [
              createMetadata({'name': 'b'}),
            ],
          }),
        ]).map((m) => m['name']),
        ['b'],
      );
    });

    test('retrieval settings map score threshold and rerank model', () {
      final configs = datasetConfigsOf('multiple', {'top_k': 0, 'score_threshold': null});
      expect(configs['top_k'], DatasetDefault.topK);
      expect(configs['score_threshold_enabled'], isFalse);
      final back = multipleConfigFromDatasetConfigs({...configs, 'score_threshold_enabled': true}, 'multiple');
      expect(back['score_threshold'], DatasetDefault.scoreThreshold);
      expect(back['reranking_model'], isNull);
    });
  });

  group('retrieval settings popover', () {
    testWidgets('top k and the score threshold switch write the multi-path config', (t) async {
      final h = await startKrPanel(
        t,
        createKrData({
          'multiple_retrieval_config': {'top_k': 4, 'score_threshold': null, 'reranking_enable': true},
        }),
        services: LlmGroupServices(
          fetchDatasets: (ids) async => [
            createDataset({'indexing_technique': 'economy'}),
          ],
          models: const ModelCatalog(),
        ),
      );
      await t.tap(find.text('dataset.retrievalSettings').first);
      await settle(t);
      expect(find.byType(ConfigRetrievalContent), findsOneWidget);
      t.widget<ScoreThresholdItem>(find.byType(ScoreThresholdItem).first).onSwitchChange!(true);
      await settle(t);
      expect(dataOf(h, 'kr')['multiple_retrieval_config'], containsPair('score_threshold', 0.8));
      t.widget<TopKItem>(find.byType(TopKItem)).onChange(7);
      await settle(t);
      expect(dataOf(h, 'kr')['multiple_retrieval_config'], containsPair('top_k', 7));
      await h.dispose(t);
    });
  });
}
