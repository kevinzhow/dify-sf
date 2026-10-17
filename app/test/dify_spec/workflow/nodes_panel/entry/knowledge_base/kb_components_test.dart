// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/__tests__/option-card.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/__tests__/index-method.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/__tests__/embedding-model.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/chunk-structure/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/chunk-structure/__tests__/selector.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/chunk-structure/instruction/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/chunk-structure/instruction/__tests__/line.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/retrieval-setting/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/retrieval-setting/__tests__/reranking-model-selector.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/retrieval-setting/__tests__/search-method-option.spec.tsx
// dify-spec: web/app/components/workflow/nodes/knowledge-base/components/retrieval-setting/__tests__/top-k-and-score-threshold.spec.tsx
//
// The panel's components rendered on their own (Dify mocks the model selector; here it is the real one over the
// given model lists).
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/kb_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart' hide Json;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kb_harness.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The control whose accessible name is [label] (`getByRole('button', { name })`).
Finder buttonNamed(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

/// The text field inside the [KbNumberField] labelled [label] (`getByRole('textbox', { name })`).
Finder numberInput([String? label]) => find.descendant(
  of: label == null
      ? find.byType(KbNumberField)
      : find.byWidgetPredicate((w) => w is KbNumberField && w.semanticLabel == label),
  matching: find.byType(EditableText),
);

String inputText(WidgetTester t, Finder f) => t.widget<EditableText>(f).controller.text;

/// Types [text] into [f] and leaves the field (Enter commits, like a blur).
Future<void> typeAndCommit(WidgetTester t, Finder f, String text) async {
  await t.tap(f);
  await t.pump();
  await t.enterText(f, text);
  await t.testTextInput.receiveAction(TextInputAction.done);
  await t.pump();
}

void main() {
  setUp(useKbTestTranslator);

  group('OptionCard', () {
    group('Interaction', () {
      testWidgets('should call onClick with the card id and render active children', (t) async {
        final clicks = <String>[];
        await t.pumpWidget(
          kbApp(
            KbOptionCard(
              id: 'qualified',
              selectedId: 'qualified',
              title: 'High Quality',
              description: 'Use embedding retrieval.',
              isRecommended: true,
              enableRadio: true,
              onClick: clicks.add,
              child: const Text('Advanced controls'),
            ),
          ),
        );
        expect(textOf('datasetCreation.stepTwo.recommend'), findsOneWidget);
        expect(find.text('Advanced controls'), findsOneWidget);
        await t.tap(find.text('High Quality'));
        expect(clicks, ['qualified']);
      });

      testWidgets('should not trigger selection when the card is readonly', (t) async {
        final clicks = <String>[];
        await t.pumpWidget(
          kbApp(KbOptionCard(id: 'economical', title: 'Economical', readonly: true, onClick: clicks.add)),
        );
        await t.tap(find.text('Economical'));
        expect(clicks, isEmpty);
      });

      // Flutter has no class names: the icon builder's state and the disabled selection are what is checked.
      testWidgets('should support function-based wrapper, class, and icon props without enabling selection', (t) async {
        final clicks = <String>[];
        await t.pumpWidget(
          kbApp(
            KbOptionCard(
              id: 'inactive',
              selectedId: 'qualified',
              title: 'Inactive card',
              enableSelect: false,
              onClick: clicks.add,
              icon: (active) => Text(active ? 'active' : 'inactive', key: const Key('option-icon')),
            ),
          ),
        );
        expect(t.widget<Text>(find.byKey(const Key('option-icon'))).data, 'inactive');
        await t.tap(find.text('Inactive card'));
        expect(clicks, isEmpty);
      });
    });
  });

  group('IndexMethod', () {
    testWidgets('should render both index method options for general chunks and notify option changes', (t) async {
      final changes = <String>[];
      await t.pumpWidget(
        kbApp(
          KbIndexMethod(
            chunkStructure: ChunkStructure.general,
            indexMethod: IndexMethod.qualified,
            keywordNumber: 5,
            onIndexMethodChange: changes.add,
            onKeywordNumberChange: (_) {},
          ),
        ),
      );
      expect(textOf('datasetCreation.stepTwo.qualified'), findsOneWidget);
      expect(textOf('datasetSettings.form.indexMethodEconomy'), findsOneWidget);
      expect(textOf('datasetCreation.stepTwo.recommend'), findsOneWidget);
      await t.tap(textOf('datasetSettings.form.indexMethodEconomy'));
      expect(changes, [IndexMethod.economical]);
    });

    testWidgets('shares integer keyword edits with the slider and retains the value when cleared', (t) async {
      final changes = <num>[];
      var value = 5 as num;
      await t.pumpWidget(
        kbApp(
          StatefulBuilder(
            builder: (context, setState) => KbIndexMethod(
              chunkStructure: ChunkStructure.general,
              indexMethod: IndexMethod.economical,
              keywordNumber: value,
              onIndexMethodChange: (_) {},
              onKeywordNumberChange: (v) {
                setState(() => value = v);
                changes.add(v);
              },
            ),
          ),
        ),
      );
      const label = 'datasetSettings.form.numberOfKeywords';
      final input = numberInput(label);
      await typeAndCommit(t, input, '');
      expect(changes, isEmpty);
      expect(inputText(t, input), '5');
      await typeAndCommit(t, input, '7.8');
      expect(inputText(t, input), '8');
      expect(changes.last, 8);
      expect(t.widget<DifySlider>(find.byType(DifySlider)).value, 8);
      await t.tap(buttonNamed('Increment value'));
      await t.pump();
      expect(inputText(t, input), '9');
    });

    testWidgets('should disable keyword controls when readonly is enabled', (t) async {
      await t.pumpWidget(
        kbApp(
          KbIndexMethod(
            chunkStructure: ChunkStructure.general,
            indexMethod: IndexMethod.economical,
            keywordNumber: 5,
            onIndexMethodChange: (_) {},
            onKeywordNumberChange: (_) {},
            readonly: true,
          ),
        ),
      );
      expect(t.widget<DifyNumberField>(find.byType(DifyNumberField)).disabled, isTrue);
      expect(t.widget<DifyPressable>(buttonNamed('Increment value')).disabled, isTrue);
    });

    testWidgets('should hide the economical option for non-general chunk structures', (t) async {
      await t.pumpWidget(
        kbApp(
          KbIndexMethod(
            chunkStructure: ChunkStructure.parentChild,
            indexMethod: IndexMethod.qualified,
            keywordNumber: 5,
            onIndexMethodChange: (_) {},
            onKeywordNumberChange: (_) {},
          ),
        ),
      );
      expect(textOf('datasetCreation.stepTwo.qualified'), findsOneWidget);
      expect(textOf('datasetSettings.form.indexMethodEconomy'), findsNothing);
    });
  });

  group('EmbeddingModel', () {
    final models = [createModel()];

    testWidgets('should pass the selected model configuration and warning state to the selector field', (t) async {
      await t.pumpWidget(
        kbApp(
          KbEmbeddingModel(
            embeddingModel: 'text-embedding-3-large',
            embeddingModelProvider: 'openai',
            embeddingModelList: models,
            catalog: ModelCatalog.empty,
            dismissed: ValueNotifier(false),
            warningDot: true,
            onChange: (_) {},
            onOpenLink: () {},
          ),
        ),
      );
      expect(find.byKey(const Key('warning-dot')), findsOneWidget);
      final selector = t.widget<KbModelSelector>(find.byType(KbModelSelector));
      expect(selector.value, (provider: 'openai', model: 'text-embedding-3-large'));
      expect(selector.models, same(models));
      expect(selector.disabled, isFalse);
      expect(selector.showDeprecatedWarnIcon, isTrue);
    });

    testWidgets('should pass an undefined value when the embedding model is incomplete', (t) async {
      await t.pumpWidget(
        kbApp(
          KbEmbeddingModel(
            embeddingModel: 'text-embedding-3-large',
            embeddingModelList: models,
            catalog: ModelCatalog.empty,
            dismissed: ValueNotifier(false),
            onChange: (_) {},
            onOpenLink: () {},
          ),
        ),
      );
      expect(t.widget<KbModelSelector>(find.byType(KbModelSelector)).value, isNull);
    });
  });

  group('ChunkStructure', () {
    testWidgets('should render the selected option and warning dot metadata when a chunk structure is chosen', (
      t,
    ) async {
      await t.pumpWidget(
        kbApp(
          KbChunkStructure(
            chunkStructure: ChunkStructure.general,
            warningDot: true,
            onChange: (_) {},
            learnMoreLink: '',
            onOpenLink: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('warning-dot')), findsOneWidget);
      expect(t.widget<KbChunkStructureSelector>(find.byType(KbChunkStructureSelector)).value, ChunkStructure.general);
      expect(
        find.descendant(of: find.byType(KbOptionCard), matching: find.text('datasetCreation.stepTwo.general')),
        findsOneWidget,
      );
      expect(find.byType(KbInstruction), findsNothing);
    });

    testWidgets('should render the add trigger and instruction when no chunk structure is selected', (t) async {
      await t.pumpWidget(
        kbApp(KbChunkStructure(chunkStructure: null, onChange: (_) {}, learnMoreLink: '', onOpenLink: (_) {})),
      );
      expect(
        find.descendant(
          of: find.byType(DifyButton),
          matching: find.text('workflow.nodes.knowledgeBase.chooseChunkStructure'),
        ),
        findsOneWidget,
      );
      expect(find.byType(KbInstruction), findsOneWidget);
    });
  });

  group('ChunkStructureSelector', () {
    final options = [
      (
        id: ChunkStructure.general,
        icon: 'vender/knowledge/general-chunk',
        activeColor: 0xFF444CE7,
        title: 'General',
        description: 'General description',
        effect: 'blue',
      ),
      (
        id: ChunkStructure.parentChild,
        icon: 'vender/knowledge/parent-child-chunk',
        activeColor: 0xFF0BA5EC,
        title: 'Parent child',
        description: 'Parent child description',
        effect: 'purple',
      ),
    ];

    testWidgets('should open the selector panel and close it after selecting an option', (t) async {
      final changes = <String>[];
      await t.pumpWidget(
        kbApp(KbChunkStructureSelector(options: options, value: ChunkStructure.general, onChange: changes.add)),
      );
      await t.tap(find.text('workflow.panel.change'));
      await settle(t);
      expect(find.text('workflow.nodes.knowledgeBase.changeChunkStructure'), findsOneWidget);
      await t.tap(find.text('Parent child'));
      await settle(t);
      expect(changes, [ChunkStructure.parentChild]);
      expect(find.text('workflow.nodes.knowledgeBase.changeChunkStructure'), findsNothing);
    });

    testWidgets('should not open the selector when readonly is enabled', (t) async {
      await t.pumpWidget(
        kbApp(
          KbChunkStructureSelector(
            options: options,
            onChange: (_) {},
            readonly: true,
            trigger: (onTap) => GestureDetector(onTap: onTap, child: const Text('custom-trigger')),
          ),
        ),
      );
      await t.tap(find.text('custom-trigger'));
      await settle(t);
      expect(find.text('workflow.nodes.knowledgeBase.changeChunkStructure'), findsNothing);
    });
  });

  group('ChunkStructureInstruction', () {
    group('Rendering', () {
      testWidgets('should render the title, message, and learn-more link', (t) async {
        final opened = <String>[];
        await t.pumpWidget(
          kbApp(
            KbInstruction(
              link: 'https://docs.example.com/use-dify/knowledge/create-knowledge/chunking-and-cleaning-text',
              onOpen: opened.add,
            ),
          ),
        );
        expect(find.text('workflow.nodes.knowledgeBase.chunkStructureTip.title'), findsOneWidget);
        expect(find.text('workflow.nodes.knowledgeBase.chunkStructureTip.message'), findsOneWidget);
        await t.tap(find.bySemanticsLabel('workflow.nodes.knowledgeBase.chunkStructureTip.learnMore'));
        expect(opened, ['https://docs.example.com/use-dify/knowledge/create-knowledge/chunking-and-cleaning-text']);
      });
    });
  });

  group('ChunkStructureInstructionLine', () {
    group('Rendering', () {
      testWidgets('should render the vertical line by default', (t) async {
        await t.pumpWidget(kbApp(const Center(child: KbInstructionLine())));
        expect(t.getSize(find.byType(KbInstructionLine)), const Size(2, 132));
      });

      testWidgets('should render the horizontal line when requested', (t) async {
        await t.pumpWidget(kbApp(const Center(child: KbInstructionLine(vertical: false))));
        expect(t.getSize(find.byType(KbInstructionLine)), const Size(240, 2));
      });
    });
  });

  KbRetrievalSetting retrievalSetting(String indexMethod, {ValueChanged<String>? onOpenLink}) => KbRetrievalSetting(
    indexMethod: indexMethod,
    retrieval: const {'top_k': 3, 'score_threshold': 0.5, 'score_threshold_enabled': false},
    catalog: ModelCatalog.empty,
    rerankModelList: const [],
    onSearchMethodChange: (_) {},
    onHybridSearchModeChange: (_) {},
    onWeightedScoreChange: (_) {},
    onRerankingModelEnabledChange: (_) {},
    onRerankingModelChange: (_) {},
    onTopKChange: (_) {},
    onScoreThresholdChange: (_) {},
    onScoreThresholdEnabledChange: (_) {},
    learnMoreLink: 'https://docs.example.com/use-dify/knowledge/create-knowledge/setting-indexing-methods',
    onOpenLink: onOpenLink ?? (_) {},
  );

  group('RetrievalSetting', () {
    testWidgets('should render the learn-more link and qualified retrieval method options', (t) async {
      final opened = <String>[];
      await t.pumpWidget(kbApp(retrievalSetting(IndexMethod.qualified, onOpenLink: opened.add)));
      await t.tap(find.bySemanticsLabel('datasetSettings.form.retrievalSetting.learnMore'));
      expect(opened, ['https://docs.example.com/use-dify/knowledge/create-knowledge/setting-indexing-methods']);
      expect(find.text('dataset.retrieval.semantic_search.title'), findsOneWidget);
      expect(find.text('dataset.retrieval.full_text_search.title'), findsOneWidget);
      expect(find.text('dataset.retrieval.hybrid_search.title'), findsOneWidget);
    });

    testWidgets('should render only the economical retrieval method for economical indexing', (t) async {
      await t.pumpWidget(kbApp(retrievalSetting(IndexMethod.economical)));
      expect(find.text('dataset.retrieval.keyword_search.title'), findsOneWidget);
      expect(find.text('dataset.retrieval.semantic_search.title'), findsNothing);
      expect(find.text('dataset.retrieval.hybrid_search.title'), findsNothing);
    });
  });

  group('RerankingModelSelector', () {
    final rerankModels = [
      createModel({
        'provider': 'cohere',
        'label': {'en_US': 'Cohere', 'zh_Hans': 'Cohere'},
        'models': [
          createModelItemJson({
            'model': 'rerank-v3',
            'model_type': ModelTypeEnum.rerank,
            'label': {'en_US': 'Rerank V3', 'zh_Hans': 'Rerank V3'},
          }),
        ],
      }),
    ];

    group('Rendering', () {
      testWidgets('should not pass a value when reranking model fields are empty strings', (t) async {
        await t.pumpWidget(
          kbApp(
            KbRerankingModelSelector(
              rerankingModel: const {'reranking_provider_name': '', 'reranking_model_name': ''},
              models: rerankModels,
              catalog: ModelCatalog.empty,
            ),
          ),
        );
        final selector = t.widget<KbModelSelector>(find.byType(KbModelSelector));
        expect(selector.value, isNull);
        expect(selector.models, hasLength(1));
      });

      testWidgets('should map reranking model to the selector value when both fields exist', (t) async {
        await t.pumpWidget(
          kbApp(
            KbRerankingModelSelector(
              rerankingModel: const {'reranking_provider_name': 'cohere', 'reranking_model_name': 'rerank-v3'},
              models: rerankModels,
              catalog: ModelCatalog.empty,
            ),
          ),
        );
        expect(t.widget<KbModelSelector>(find.byType(KbModelSelector)).value, (
          provider: 'cohere',
          model: 'rerank-v3',
        ));
      });
    });

    group('Interactions', () {
      testWidgets('should map selected model back to reranking model fields', (t) async {
        final picked = <DefaultModel>[];
        await t.pumpWidget(
          kbApp(
            KbRerankingModelSelector(
              models: rerankModels,
              catalog: ModelCatalog.empty,
              onRerankingModelChange: picked.add,
            ),
          ),
        );
        await t.tap(buttonNamed(ModelSelectorTrigger.configureModel));
        await settle(t);
        await t.tap(buttonNamed('Rerank V3'));
        await settle(t);
        expect(picked, [(provider: 'cohere', model: 'rerank-v3')]);
        final next = KnowledgeBaseConfig(const {}).rerankingModelChange(
          providerName: picked.single.provider,
          modelName: picked.single.model,
        );
        expect((next['retrieval_model']! as Map)['reranking_model'], {
          'reranking_provider_name': 'cohere',
          'reranking_model_name': 'rerank-v3',
        });
      });
    });
  });

  group('SearchMethodOption', () {
    const hybridModes = [
      (id: HybridSearchMode.weightedScore, title: 'Weighted mode', description: 'Use weighted score'),
      (id: HybridSearchMode.rerankingModel, title: 'Rerank mode', description: 'Use reranking model'),
    ];
    const weights = {
      'weight_type': WeightedScoreType.customized,
      'vector_setting': {
        'vector_weight': 0.8,
        'embedding_provider_name': 'openai',
        'embedding_model_name': 'text-embedding-3-large',
      },
      'keyword_setting': {'keyword_weight': 0.2},
    };

    late List<String> selected, modes;
    late List<bool> rerankEnabled;
    late List<num> topK;

    KbOption option(String id, String title) => (
      id: id,
      icon: 'vender/knowledge/vector-search',
      activeColor: 0xFF6938EF,
      title: title,
      description: 'Semantic description',
      effect: 'purple',
    );

    Widget build({
      required KbOption option,
      String searchMethod = SearchMethod.semantic,
      String hybridMode = HybridSearchMode.weightedScore,
      bool showMultiModalTip = false,
    }) => kbApp(
      KbSearchMethodOption(
        option: option,
        searchMethod: searchMethod,
        onSelect: selected.add,
        hybridModes: hybridModes,
        hybridMode: hybridMode,
        onHybridModeChange: modes.add,
        weights: weights,
        onWeightedScoreChange: (_) {},
        rerankingEnabled: false,
        onRerankingEnabledChange: rerankEnabled.add,
        rerankingModel: const {'reranking_provider_name': '', 'reranking_model_name': ''},
        onRerankingModelChange: (_) {},
        rerankModelList: const [],
        catalog: ModelCatalog.empty,
        showMultiModalTip: showMultiModalTip,
        topK: 3,
        onTopKChange: topK.add,
        scoreThreshold: 0.5,
        onScoreThresholdChange: (_) {},
        scoreThresholdEnabled: true,
        onScoreThresholdEnabledChange: (_) {},
      ),
    );

    setUp(() {
      selected = [];
      modes = [];
      rerankEnabled = [];
      topK = [];
    });

    testWidgets('should render semantic search controls and notify retrieval and reranking changes', (t) async {
      await t.pumpWidget(build(option: option(SearchMethod.semantic, 'Semantic title')));
      expect(find.text('Semantic title'), findsOneWidget);
      expect(find.text('common.modelProvider.rerankModel.key'), findsOneWidget);
      expect(find.text(ModelSelectorTrigger.configureModel), findsOneWidget);
      expect(find.byType(DifySwitch), findsNWidgets(2));
      await t.tap(find.byType(DifySwitch).first);
      expect(rerankEnabled, [true]);
    });

    testWidgets('should notify retrieval changes when an inactive option is selected', (t) async {
      await t.pumpWidget(build(option: option(SearchMethod.fullText, 'Full-text title')));
      expect(find.text('Full-text title'), findsOneWidget);
      await t.tap(find.text('Full-text title'));
      expect(selected, [SearchMethod.fullText]);
    });

    testWidgets('should render hybrid weighted-score controls without reranking model selector', (t) async {
      await t.pumpWidget(
        build(
          option: option(SearchMethod.hybrid, 'Hybrid title'),
          searchMethod: SearchMethod.hybrid,
          showMultiModalTip: true,
        ),
      );
      expect(find.text('Weighted mode'), findsOneWidget);
      expect(find.text('Rerank mode'), findsOneWidget);
      expect(textOf('dataset.weightedScore.semantic'), findsOneWidget);
      expect(textOf('dataset.weightedScore.keyword'), findsOneWidget);
      expect(find.text('common.modelProvider.rerankModel.key'), findsNothing);
      expect(find.text('datasetSettings.form.retrievalSetting.multiModalTip'), findsNothing);
      await t.tap(find.text('Rerank mode'));
      expect(modes, [HybridSearchMode.rerankingModel]);
    });

    testWidgets('should render the hybrid reranking selector when reranking mode is selected', (t) async {
      await t.pumpWidget(
        build(
          option: option(SearchMethod.hybrid, 'Hybrid title'),
          searchMethod: SearchMethod.hybrid,
          hybridMode: HybridSearchMode.rerankingModel,
          showMultiModalTip: true,
        ),
      );
      expect(find.text(ModelSelectorTrigger.configureModel), findsOneWidget);
      expect(find.text('common.modelProvider.rerankModel.key'), findsNothing);
      expect(textOf('dataset.weightedScore.semantic'), findsNothing);
      expect(find.text('datasetSettings.form.retrievalSetting.multiModalTip'), findsOneWidget);
    });

    testWidgets('should hide the score-threshold control for keyword search', (t) async {
      await t.pumpWidget(
        build(option: option(SearchMethod.keywordSearch, 'Keyword title'), searchMethod: SearchMethod.keywordSearch),
      );
      expect(numberInput(), findsOneWidget);
      expect(find.byType(DifySwitch), findsNothing);
      await typeAndCommit(t, numberInput(), '9');
      expect(topK, contains(9));
    });
  });

  group('TopKAndScoreThreshold', () {
    const topKLabel = 'appDebug.datasetConfig.top_k', scoreLabel = 'appDebug.datasetConfig.score_threshold';

    testWidgets('should hide the score-threshold column when requested', (t) async {
      await t.pumpWidget(
        kbApp(
          KbTopKAndScoreThreshold(
            topK: 3,
            onTopKChange: (_) {},
            scoreThresholdHidden: true,
            onScoreThresholdChange: (_) {},
            onScoreThresholdEnabledChange: (_) {},
          ),
        ),
      );
      expect(numberInput(), findsOneWidget);
      expect(find.byType(DifySwitch), findsNothing);
    });

    // dify-sf's NumberField always shows a number: the cleared score threshold shows 0 (Dify: an empty field).
    testWidgets('should fall back to zero when the number fields are cleared', (t) async {
      final topK = <num>[];
      await t.pumpWidget(
        kbApp(
          KbTopKAndScoreThreshold(
            topK: 3,
            onTopKChange: topK.add,
            scoreThresholdEnabled: true,
            onScoreThresholdChange: (_) {},
            onScoreThresholdEnabledChange: (_) {},
          ),
        ),
      );
      await typeAndCommit(t, numberInput(topKLabel), '');
      expect(topK, [0]);
      expect(inputText(t, numberInput(scoreLabel)), '0');
    });

    testWidgets('should default the score-threshold switch to off when the flag is missing', (t) async {
      await t.pumpWidget(
        kbApp(
          KbTopKAndScoreThreshold(
            topK: 3,
            onTopKChange: (_) {},
            scoreThreshold: 0.4,
            onScoreThresholdChange: (_) {},
            onScoreThresholdEnabledChange: (_) {},
          ),
        ),
      );
      final s = t.widget<DifySwitch>(find.byWidgetPredicate((w) => w is DifySwitch && w.semanticLabel == scoreLabel));
      expect(s.checked, isFalse);
    });
  });
}
