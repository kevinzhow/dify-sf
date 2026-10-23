/// The Knowledge Base node's (`knowledge-index`, nodes/knowledge-base) data logic, ported as pure Dart over Dify's
/// node `data` (plain JSON): types.ts enums, default.ts (defaultValue, checkValid), utils.ts (the validation issue),
/// hooks/use-config.ts (each handler as the partial data it writes), use-embedding-model-status,
/// use-settings-display, use-single-run-form-params, the chunk-structure and retrieval-setting option hooks and
/// datasets/settings/utils checkShowMultiModalTip.
library;

import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/model_catalog.dart';
import '../../../../header/checklist/node_validators.dart' show ChecklistTranslate;

typedef Json = Map<String, Object?>;

// ---- types.ts ----------------------------------------------------------------------------------------------------

/// ChunkStructureEnum.
abstract final class ChunkStructure {
  static const general = 'text_model';
  static const parentChild = 'hierarchical_model';
  static const questionAnswer = 'qa_model';
}

/// IndexMethodEnum (IndexingType).
abstract final class IndexMethod {
  static const qualified = 'high_quality';
  static const economical = 'economy';
}

/// RetrievalSearchMethodEnum (RETRIEVE_METHOD).
abstract final class SearchMethod {
  static const semantic = 'semantic_search';
  static const fullText = 'full_text_search';
  static const hybrid = 'hybrid_search';
  static const invertedIndex = 'invertedIndex';
  static const keywordSearch = 'keyword_search';
}

/// HybridSearchModeEnum (RerankingModeEnum).
abstract final class HybridSearchMode {
  static const rerankingModel = 'reranking_model';
  static const weightedScore = 'weighted_score';
}

/// WeightedScoreEnum.
abstract final class WeightedScoreType {
  static const semanticFirst = 'semantic_first';
  static const keywordFirst = 'keyword_first';
  static const customized = 'customized';
}

/// DEFAULT_WEIGHTED_SCORE.other.
const defaultSemanticWeight = 0.7, defaultKeywordWeight = 0.3;

// ---- default.ts --------------------------------------------------------------------------------------------------

/// nodeDefault.defaultValue.
const knowledgeBaseDefaultValue = <String, Object?>{
  'index_chunk_variable_selector': <Object?>[],
  'keyword_number': 10,
  'retrieval_model': {'top_k': 3, 'score_threshold_enabled': false, 'score_threshold': 0.5},
};

/// nodeDefault.checkValid: the first validation issue's message, '' when valid. The model lists come as Dify's
/// `_embeddingModelList`, `_embeddingProviderModelList` and `_rerankModelList` in [data] (JSON or ported objects).
String checkValidKnowledgeBase(Json data, ChecklistTranslate t, Json? moreData) =>
    knowledgeBaseValidationMessage(knowledgeBaseValidationIssue(data), t);

// ---- utils.ts ----------------------------------------------------------------------------------------------------

bool isHighQualitySearchMethod(String? searchMethod) =>
    searchMethod == SearchMethod.semantic ||
    searchMethod == SearchMethod.hybrid ||
    searchMethod == SearchMethod.fullText;

/// KnowledgeBaseValidationIssueCode with the message's namespace and key.
enum KnowledgeBaseIssue {
  chunkStructureRequired('chunk-structure-required', 'workflow', 'nodes.knowledgeBase.chunkIsRequired'),
  chunksVariableRequired('chunks-variable-required', 'workflow', 'nodes.knowledgeBase.chunksVariableIsRequired'),
  indexMethodRequired('index-method-required', 'workflow', 'nodes.knowledgeBase.indexMethodIsRequired'),
  embeddingModelNotConfigured(
    'embedding-model-not-configured',
    'workflow',
    'nodes.knowledgeBase.embeddingModelNotConfigured',
  ),
  embeddingModelConfigureRequired(
    'embedding-model-configure-required',
    'common',
    'modelProvider.selector.configureRequired',
  ),
  embeddingModelApiKeyUnavailable(
    'embedding-model-api-key-unavailable',
    'common',
    'modelProvider.selector.apiKeyUnavailable',
  ),
  embeddingModelCreditsExhausted(
    'embedding-model-credits-exhausted',
    'common',
    'modelProvider.selector.creditsExhausted',
  ),
  embeddingModelDisabled('embedding-model-disabled', 'common', 'modelProvider.selector.disabled'),
  embeddingModelIncompatible('embedding-model-incompatible', 'common', 'modelProvider.selector.incompatible'),
  retrievalSettingRequired('retrieval-setting-required', 'workflow', 'nodes.knowledgeBase.retrievalSettingIsRequired'),
  rerankingModelRequired('reranking-model-required', 'workflow', 'nodes.knowledgeBase.rerankingModelIsRequired'),
  rerankingModelInvalid('reranking-model-invalid', 'workflow', 'nodes.knowledgeBase.rerankingModelIsInvalid');

  const KnowledgeBaseIssue(this.code, this.ns, this.key);
  final String code, ns, key;
}

Json _map(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : <String, Object?>{};
String? _str(Object? v) => v is String ? v : null;
bool _truthy(Object? v) => switch (v) {
  null || false || '' || 0 => false,
  _ => true,
};

/// A model list in node data: ported objects or the API's JSON; null when absent.
List<ProviderWithModels>? providerListOf(Object? v) =>
    v is List ? [for (final p in v) p is ProviderWithModels ? p : ProviderWithModels.fromJson(p)] : null;
List<ModelItem>? _modelListOf(Object? v) =>
    v is List ? [for (final m in v) m is ModelItem ? m : ModelItem.fromJson(m)] : null;

KnowledgeBaseIssue? _embeddingIssue(Json payload) {
  final model = _str(payload['embedding_model']);
  final provider = _str(payload['embedding_model_provider']);
  if (!_truthy(model) || !_truthy(provider)) return KnowledgeBaseIssue.embeddingModelNotConfigured;
  final current = providerListOf(payload['_embeddingModelList'])?.where((p) => p.provider == provider).firstOrNull;
  final scoped = _modelListOf(payload['_embeddingProviderModelList']);
  final hasScoped = scoped != null && scoped.isNotEmpty;
  final candidates = hasScoped ? scoped : current?.models;
  final currentModel = candidates?.where((m) => m.model == model).firstOrNull;
  if (currentModel == null) {
    // Dify: `providerExists ? incompatible : notConfigured`, where providerExists is always true here.
    return KnowledgeBaseIssue.embeddingModelIncompatible;
  }
  return switch (currentModel.status) {
    ModelStatusEnum.active => null,
    ModelStatusEnum.noConfigure => KnowledgeBaseIssue.embeddingModelConfigureRequired,
    ModelStatusEnum.credentialRemoved => KnowledgeBaseIssue.embeddingModelApiKeyUnavailable,
    ModelStatusEnum.quotaExceeded => KnowledgeBaseIssue.embeddingModelCreditsExhausted,
    ModelStatusEnum.disabled => KnowledgeBaseIssue.embeddingModelDisabled,
    _ => KnowledgeBaseIssue.embeddingModelIncompatible,
  };
}

/// getKnowledgeBaseValidationIssue: the first problem of [payload], null when it is complete.
KnowledgeBaseIssue? knowledgeBaseValidationIssue(Json payload) {
  final retrieval = payload['retrieval_model'];
  final r = _map(retrieval);
  if (!_truthy(payload['chunk_structure'])) return KnowledgeBaseIssue.chunkStructureRequired;
  final selector = payload['index_chunk_variable_selector'];
  if (selector is! List || selector.isEmpty) return KnowledgeBaseIssue.chunksVariableRequired;
  final technique = payload['indexing_technique'];
  if (!_truthy(technique)) return KnowledgeBaseIssue.indexMethodRequired;
  if (technique == IndexMethod.qualified) {
    final issue = _embeddingIssue(payload);
    if (issue != null) return issue;
  }
  if (retrieval == null || !_truthy(r['search_method'])) return KnowledgeBaseIssue.retrievalSettingRequired;
  if (_truthy(r['reranking_enable'])) {
    final rerank = _map(r['reranking_model']);
    final providerName = _str(rerank['reranking_provider_name']), modelName = _str(rerank['reranking_model_name']);
    if (r['reranking_model'] == null || !_truthy(providerName) || !_truthy(modelName)) {
      return KnowledgeBaseIssue.rerankingModelRequired;
    }
    final provider = providerListOf(payload['_rerankModelList'])?.where((p) => p.provider == providerName).firstOrNull;
    if (provider?.models.where((m) => m.model == modelName).firstOrNull == null) {
      return KnowledgeBaseIssue.rerankingModelInvalid;
    }
  }
  return null;
}

/// getKnowledgeBaseValidationMessage.
String knowledgeBaseValidationMessage(KnowledgeBaseIssue? issue, ChecklistTranslate t) =>
    issue == null ? '' : t(issue.ns, issue.key);

/// The issue's message in the UI language.
String knowledgeBaseIssueText(KnowledgeBaseIssue? issue) => issue == null ? '' : kbT(issue.ns, issue.key);

// ---- hooks/use-config.ts -----------------------------------------------------------------------------------------

/// useConfig's handlers over the node's current [data]: each returns the partial data Dify passes to
/// `handleNodeDataUpdateWithSyncDraft` (merged over the node's data).
class KnowledgeBaseConfig {
  KnowledgeBaseConfig(this.data);
  final Json data;

  Json get _retrieval => _map(data['retrieval_model']);

  static Json defaultWeights(String embeddingModel, String embeddingModelProvider) => {
    'vector_setting': {
      'vector_weight': defaultSemanticWeight,
      'embedding_provider_name': embeddingModelProvider,
      'embedding_model_name': embeddingModel,
    },
    'keyword_setting': {'keyword_weight': defaultKeywordWeight},
  };

  Json chunkStructureChange(String chunkStructure) {
    final structured = chunkStructure == ChunkStructure.parentChild || chunkStructure == ChunkStructure.questionAnswer;
    final searchMethod = _retrieval['search_method'];
    return {
      'chunk_structure': chunkStructure,
      'indexing_technique': structured ? IndexMethod.qualified : data['indexing_technique'],
      'retrieval_model': {
        ..._retrieval,
        'search_method': structured && !isHighQualitySearchMethod(_str(searchMethod))
            ? SearchMethod.keywordSearch
            : searchMethod,
      },
      'index_chunk_variable_selector': chunkStructure == data['chunk_structure']
          ? data['index_chunk_variable_selector']
          : <Object?>[],
    };
  }

  /// `produce(nodeData.data, …)`: the whole data with the change.
  Json indexMethodChange(String indexMethod) => {
    ...data,
    'indexing_technique': indexMethod,
    'retrieval_model': {
      ..._retrieval,
      if (indexMethod == IndexMethod.economical) 'search_method': SearchMethod.keywordSearch,
      if (indexMethod == IndexMethod.qualified) 'search_method': SearchMethod.semantic,
    },
  };

  Json keywordNumberChange(num keywordNumber) => {'keyword_number': keywordNumber};

  Json embeddingModelChange({required String embeddingModel, required String embeddingModelProvider}) {
    final retrieval = _retrieval;
    final weights = retrieval['weights'];
    return {
      'embedding_model': embeddingModel,
      'embedding_model_provider': embeddingModelProvider,
      'retrieval_model': {
        ...retrieval,
        'weights': weights != null
            ? {
                ..._map(weights),
                'vector_setting': {
                  ..._map(_map(weights)['vector_setting']),
                  'embedding_provider_name': embeddingModelProvider,
                  'embedding_model_name': embeddingModel,
                },
              }
            : defaultWeights(embeddingModel, embeddingModelProvider),
      },
    };
  }

  Json retrievalSearchMethodChange(String searchMethod) {
    final mode = _truthy(_retrieval['reranking_mode']) ? _retrieval['reranking_mode'] : HybridSearchMode.rerankingModel;
    return {
      'retrieval_model': {
        ..._retrieval,
        'search_method': searchMethod,
        'reranking_mode': mode,
        if (searchMethod == SearchMethod.hybrid) 'reranking_enable': mode == HybridSearchMode.rerankingModel,
      },
    };
  }

  Json hybridSearchModeChange(String mode) => {
    'retrieval_model': {
      ..._retrieval,
      'reranking_mode': mode,
      'reranking_enable': mode == HybridSearchMode.rerankingModel,
      'weights':
          _retrieval['weights'] ??
          defaultWeights(_str(data['embedding_model']) ?? '', _str(data['embedding_model_provider']) ?? ''),
    },
  };

  Json rerankingModelEnabledChange(bool enabled) => {
    'retrieval_model': {..._retrieval, 'reranking_enable': enabled},
  };

  Json weightedScoreChange(List<num> value) => {
    'retrieval_model': {
      ..._retrieval,
      'weights': {
        'weight_type': WeightedScoreType.customized,
        'vector_setting': {..._map(_map(_retrieval['weights'])['vector_setting']), 'vector_weight': value[0]},
        'keyword_setting': {'keyword_weight': value[1]},
      },
    },
  };

  Json rerankingModelChange({required String providerName, required String modelName}) => {
    'retrieval_model': {
      ..._retrieval,
      'reranking_model': {'reranking_provider_name': providerName, 'reranking_model_name': modelName},
    },
  };

  Json topKChange(num topK) => {
    'retrieval_model': {..._retrieval, 'top_k': topK},
  };

  Json scoreThresholdChange(num scoreThreshold) => {
    'retrieval_model': {..._retrieval, 'score_threshold': scoreThreshold},
  };

  Json scoreThresholdEnabledChange(bool enabled) => {
    'retrieval_model': {..._retrieval, 'score_threshold_enabled': enabled},
  };

  /// `Array.isArray(inputVariable) ? inputVariable : []`.
  Json inputVariableChange(Object? inputVariable) => {
    'index_chunk_variable_selector': inputVariable is List ? inputVariable : <Object?>[],
  };

  Json summaryIndexSettingChange(Json setting) => {
    'summary_index_setting': {..._map(data['summary_index_setting']), ...setting},
  };
}

// ---- hooks/use-embedding-model-status.ts -------------------------------------------------------------------------

/// useEmbeddingModelStatus: the installed provider ([providers] stands for the summary query), the provider and
/// model in [embeddingModelList] and deriveModelStatus over them.
({ModelProvider? providerMeta, ProviderWithModels? modelProvider, ModelItem? currentModel, DerivedModelStatus status})
embeddingModelStatus({
  String? embeddingModel,
  String? embeddingModelProvider,
  required List<ProviderWithModels> embeddingModelList,
  List<ModelProvider> providers = const [],
  required CredentialPanelState Function(ModelProvider? provider) credentialPanelOf,
}) {
  final providerMeta = providers.where((p) => p.provider == embeddingModelProvider).firstOrNull;
  final modelProvider = embeddingModelList.where((p) => p.provider == embeddingModelProvider).firstOrNull;
  final currentModel = modelProvider?.models.where((m) => m.model == embeddingModel).firstOrNull;
  return (
    providerMeta: providerMeta,
    modelProvider: modelProvider,
    currentModel: currentModel,
    status: deriveModelStatus(
      embeddingModel,
      embeddingModelProvider,
      providerMeta,
      currentModel,
      credentialPanelOf(providerMeta),
    ),
  );
}

// ---- hooks/use-settings-display.ts -------------------------------------------------------------------------------

/// useSettingsDisplay: the labels of the index methods and search methods.
Map<String, String> knowledgeBaseSettingsDisplay() => {
  IndexMethod.qualified: kbT('dataset-creation', 'stepTwo.qualified'),
  IndexMethod.economical: kbT('dataset-settings', 'form.indexMethodEconomy'),
  SearchMethod.semantic: kbT('dataset', 'retrieval.semantic_search.title'),
  SearchMethod.fullText: kbT('dataset', 'retrieval.full_text_search.title'),
  SearchMethod.hybrid: kbT('dataset', 'retrieval.hybrid_search.title'),
  SearchMethod.keywordSearch: kbT('dataset', 'retrieval.keyword_search.title'),
};

// ---- use-single-run-form-params.ts -------------------------------------------------------------------------------

/// One form of the single-run panel (BeforeRunForm's `forms` entry).
typedef SingleRunForm = ({List<Json> inputs, Json values, void Function(Json keyValue) onChange});

/// useSingleRunFormParams: the "Input Variables" form with the `query` paragraph; the chunks selector is the
/// dependent variable.
({
  List<SingleRunForm> forms,
  List<List<Object?>> Function() getDependentVars,
  List<Object?>? Function(String) getDependentVar,
})
knowledgeBaseSingleRunFormParams({
  required Json payload,
  required Json runInputData,
  required void Function(Json data) setRunInputData,
}) {
  final selector = payload['index_chunk_variable_selector'];
  final chunks = selector is List ? selector.cast<Object?>() : const <Object?>[];
  return (
    forms: [
      (
        inputs: [
          {
            'label': DifyI18n.tr('workflow', 'nodes.common.inputVars'),
            'variable': 'query',
            'type': 'paragraph',
            'required': true,
          },
        ],
        values: {'query': runInputData['query']},
        onChange: (keyValue) => setRunInputData({...runInputData, 'query': keyValue['query']}),
      ),
    ],
    getDependentVars: () => [chunks],
    getDependentVar: (variable) => variable == 'query' ? chunks : null,
  );
}

// ---- datasets/settings/utils checkShowMultiModalTip --------------------------------------------------------------

/// Whether to warn that a multimodal embedding model is used with a reranker that is not.
bool checkShowMultiModalTip({
  required String embeddingProvider,
  required String embeddingModel,
  required bool rerankingEnable,
  required String rerankingProviderName,
  required String rerankingModelName,
  required String? indexMethod,
  required List<ProviderWithModels> embeddingModelList,
  required List<ProviderWithModels> rerankModelList,
}) {
  if (indexMethod != IndexMethod.qualified || embeddingProvider.isEmpty || embeddingModel.isEmpty) return false;
  final embedding = embeddingModelList
      .where((p) => p.provider == embeddingProvider)
      .firstOrNull
      ?.models
      .where((m) => m.model == embeddingModel)
      .firstOrNull;
  if (embedding == null || !(embedding.features?.contains(ModelFeatureEnum.vision) ?? false)) return false;
  if (!rerankingEnable || rerankingModelName.isEmpty || rerankingProviderName.isEmpty) return false;
  final rerank = rerankModelList
      .where((p) => p.provider == rerankingProviderName)
      .firstOrNull
      ?.models
      .where((m) => m.model == rerankingModelName)
      .firstOrNull;
  if (rerank == null) return false;
  return !(rerank.features?.contains(ModelFeatureEnum.vision) ?? false);
}

/// isVisionEmbeddingModel (multimodal-retrieval-guidance).
bool isVisionEmbeddingModel(String? provider, String? model, List<ProviderWithModels> embeddingModelList) {
  if (provider == null || provider.isEmpty || model == null || model.isEmpty) return false;
  final m = embeddingModelList
      .where((p) => p.provider == provider)
      .firstOrNull
      ?.models
      .where((i) => i.model == model)
      .firstOrNull;
  return m?.features?.contains(ModelFeatureEnum.vision) ?? false;
}

// ---- option hooks ------------------------------------------------------------------------------------------------

/// An option card's content: the icon asset (`DifyIcon` name), its colour when active or hovered, the effect blob
/// colour and opacity (public/knowledge/option-card-effect-*).
typedef KbOption = ({String id, String icon, int activeColor, String title, String description, String? effect});

/// useChunkStructure: General, Parent-child, Q&A.
List<KbOption> chunkStructureOptions() => [
  (
    id: ChunkStructure.general,
    icon: 'vender/knowledge/general-chunk',
    activeColor: 0xFF444CE7, // util-colors-indigo-indigo-600
    title: kbT('dataset-creation', 'stepTwo.general'),
    description: kbT('dataset-creation', 'stepTwo.generalTip'),
    effect: 'blue',
  ),
  (
    id: ChunkStructure.parentChild,
    icon: 'vender/knowledge/parent-child-chunk',
    activeColor: 0xFF0BA5EC, // util-colors-blue-light-blue-light-500
    title: kbT('dataset-creation', 'stepTwo.parentChild'),
    description: kbT('dataset-creation', 'stepTwo.parentChildTip'),
    effect: 'blue-light',
  ),
  (
    id: ChunkStructure.questionAnswer,
    icon: 'vender/knowledge/question-and-answer',
    activeColor: 0xFF0E9384, // util-colors-teal-teal-600
    title: 'Q&A',
    description: kbT('dataset-creation', 'stepTwo.qaTip'),
    effect: 'teal',
  ),
];

/// useRetrievalSetting's `options`: Inverted Index for economical indexing, else Vector / Full-Text / Hybrid.
List<KbOption> retrievalOptions(String? indexMethod) {
  KbOption option(String id, String key, String icon) => (
    id: id,
    icon: icon,
    activeColor: 0xFF6938EF, // util-colors-purple-purple-600
    title: kbT('dataset', 'retrieval.$key.title'),
    description: kbT('dataset', 'retrieval.$key.description'),
    effect: 'purple',
  );
  if (indexMethod == IndexMethod.economical) {
    return [option(SearchMethod.keywordSearch, 'keyword_search', 'vender/knowledge/hybrid-search')];
  }
  return [
    option(SearchMethod.semantic, 'semantic_search', 'vender/knowledge/vector-search'),
    option(SearchMethod.fullText, 'full_text_search', 'vender/knowledge/full-text-search'),
    option(SearchMethod.hybrid, 'hybrid_search', 'vender/knowledge/hybrid-search'),
  ];
}

/// useRetrievalSetting's `hybridSearchModeOptions`.
List<({String id, String title, String description})> hybridSearchModeOptions() => [
  (
    id: HybridSearchMode.weightedScore,
    title: kbT('dataset', 'weightedScore.title'),
    description: kbT('dataset', 'weightedScore.description'),
  ),
  (
    id: HybridSearchMode.rerankingModel,
    title: kbT('common', 'modelProvider.rerankModel.key'),
    description: kbT('common', 'modelProvider.rerankModel.tip'),
  ),
];

// ---- i18n --------------------------------------------------------------------------------------------------------

/// [DifyI18n.tr], with Dify's English text for the keys of namespaces the app does not load (dataset-creation is
/// not among the copied ones; dataset and dataset-settings are not loaded by default).
String kbT(String ns, String key, [Map<String, Object?> params = const {}]) {
  final text = DifyI18n.tr(ns, key, params);
  if (text != DifyI18n.interpolate(key, params)) return text;
  final en = _english['$ns.$key'];
  return en == null ? text : DifyI18n.interpolate(en, params);
}

const _english = {
  'dataset-creation.stepTwo.qualified': 'High Quality',
  'dataset-creation.stepTwo.recommend': 'Recommend',
  'dataset-creation.stepTwo.general': 'General',
  'dataset-creation.stepTwo.generalTip': 'General text chunking mode, the chunks retrieved and recalled are the same.',
  'dataset-creation.stepTwo.parentChild': 'Parent-child',
  'dataset-creation.stepTwo.parentChildTip':
      'When using the parent-child mode, the child-chunk is used for retrieval and the parent-chunk is used for '
      'recall as context.',
  'dataset-creation.stepTwo.qaTip':
      'When using structured Q&A data, you can create documents that pair questions with answers. These documents '
      'are indexed based on the question portion, allowing the system to retrieve relevant answers based on query '
      'similarity.',
  'dataset-creation.stepTwo.indexMode': 'Index Method',
  'dataset-settings.form.indexMethodEconomy': 'Economical',
  'dataset-settings.form.indexMethodEconomyTip':
      'Using {{count}} keywords per chunk for retrieval, no tokens are consumed at the expense of reduced retrieval '
      'accuracy.',
  'dataset-settings.form.indexMethodHighQualityTip':
      'Calling the embedding model to process documents for more precise retrieval helps LLM generate high-quality '
      'answers.',
  'dataset-settings.form.numberOfKeywords': 'Number of Keywords',
  'dataset-settings.form.embeddingModel': 'Embedding Model',
  'dataset-settings.form.retrievalSetting.title': 'Retrieval Setting',
  'dataset-settings.form.retrievalSetting.learnMore': 'Learn more',
  'dataset-settings.form.retrievalSetting.multiModalTip':
      'When embedding model supports multi-modal, please select a multi-modal rerank model for better performance.',
  'dataset-settings.form.summaryAutoGen': 'Summary Auto-Gen',
  'dataset-settings.form.summaryAutoGenTip':
      'Summaries are automatically generated for newly added documents. Existing documents can still be summarized '
      'manually.',
  'dataset-settings.form.summaryModel': 'Summary Model',
  'dataset-settings.form.summaryInstructions': 'Instructions',
  'dataset-settings.form.summaryInstructionsPlaceholder': 'Describe the rules or style for auto-generated summaries…',
  'dataset-settings.form.multimodalRetrievalGuidance.pipelineTitle': 'Let images participate in retrieval',
  'dataset-settings.form.multimodalRetrievalGuidance.pipelineDescription':
      'If your knowledge includes screenshots, product images, manual illustrations, or charts, choose an Embedding '
      'model with a Vision label. Text-only models mainly process text content and may not include images in '
      'retrieval.',
  'dataset-settings.form.multimodalRetrievalGuidance.helpLink': 'Learn more',
  'dataset-settings.form.multimodalRetrievalGuidance.helpDescription': 'about multimodal retrieval.',
  'dataset-settings.form.multimodalRetrievalGuidance.dismiss': 'Dismiss guidance',
  'dataset.retrieval.semantic_search.title': 'Vector Search',
  'dataset.retrieval.semantic_search.description':
      'Generate query embeddings and search for the text chunk most similar to its vector representation.',
  'dataset.retrieval.full_text_search.title': 'Full-Text Search',
  'dataset.retrieval.full_text_search.description':
      'Index all terms in the document, allowing users to search any term and retrieve relevant text chunk '
      'containing those terms.',
  'dataset.retrieval.hybrid_search.title': 'Hybrid Search',
  'dataset.retrieval.hybrid_search.description':
      "Execute full-text search and vector searches simultaneously, re-rank to select the best match for the user's "
      'query. Users can choose to set weights or configure to a Rerank model.',
  'dataset.retrieval.keyword_search.title': 'Inverted Index',
  'dataset.retrieval.keyword_search.description':
      'Inverted Index is a structure used for efficient retrieval. Organized by terms, each term points to documents '
      'or web pages containing it.',
  'dataset.weightedScore.title': 'Weighted Score',
  'dataset.weightedScore.description':
      'By adjusting the weights assigned, this rerank strategy determines whether to prioritize semantic or keyword '
      'matching.',
  'dataset.weightedScore.semantic': 'Semantic',
  'dataset.weightedScore.keyword': 'Keyword',
};
