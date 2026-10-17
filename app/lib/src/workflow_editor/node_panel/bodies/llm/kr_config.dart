/// The Knowledge Retrieval node's logic, ported as pure Dart from Dify 1.17.1
/// web/app/components/workflow/nodes/knowledge-retrieval: utils.ts, the hooks of use-config.ts
/// (use-knowledge-input-manager, -dataset-selection, -model-config, -metadata-config), the metadata condition utils
/// and the retrieval-config mapping. Inputs are the node's Dify `data` (plain JSON); datasets are Dify `DataSet`
/// JSON (`id`, `name`, `indexing_technique`, `provider`, `embedding_model(_provider)`, `retrieval_model_dict`,
/// `is_multimodal`, `doc_metadata`, `icon_info`, `embedding_available`).
library;

import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/node_config.dart' show Json;
import '../../../prompt_editor/config_prompt.dart' show uuid4;
import 'llm_config.dart' show jsonClone;
import 'panel_edit.dart' show jsMap;

export '../../../header/checklist/node_validators.dart' show checkoutRerankModelConfiguredInRetrievalSettings;

/// `RETRIEVE_TYPE`.
abstract final class RetrieveType {
  static const oneWay = 'single';
  static const multiWay = 'multiple';
}

/// `RETRIEVE_METHOD`.
abstract final class RetrieveMethod {
  static const semantic = 'semantic_search';
  static const fullText = 'full_text_search';
  static const hybrid = 'hybrid_search';
  static const invertedIndex = 'invertedIndex';
  static const keywordSearch = 'keyword_search';
}

/// `RerankingModeEnum`.
abstract final class RerankingMode {
  static const rerankingModel = 'reranking_model';
  static const weightedScore = 'weighted_score';
}

/// `DATASET_DEFAULT` (config).
abstract final class DatasetDefault {
  static const topK = 4;
  static const scoreThreshold = 0.8;
}

/// `NEXT_PUBLIC_TOP_K_MAX_VALUE` (env default).
const topKMaxValue = 10;

/// `getSelectedDatasetsMode`.
typedef SelectedDatasetsMode = ({
  bool allHighQuality,
  bool allHighQualityVectorSearch,
  bool allHighQualityFullTextSearch,
  bool allEconomic,
  bool mixtureHighQualityAndEconomic,
  bool allInternal,
  bool allExternal,
  bool mixtureInternalAndExternal,
  bool inconsistentEmbeddingModel,
});

SelectedDatasetsMode getSelectedDatasetsMode([List<Json>? datasets]) {
  final list = datasets ?? const <Json>[];
  var allHighQuality = true, allHighQualityVectorSearch = true, allHighQualityFullTextSearch = true;
  var allEconomic = true, mixtureHighQualityAndEconomic = true, allExternal = true, allInternal = true;
  var mixtureInternalAndExternal = true, inconsistentEmbeddingModel = false;
  if (list.isEmpty) {
    allHighQuality = allHighQualityVectorSearch = allHighQualityFullTextSearch = false;
    allEconomic = mixtureHighQualityAndEconomic = allExternal = allInternal = mixtureInternalAndExternal = false;
  }
  for (final d in list) {
    if (d['indexing_technique'] == 'economy') {
      allHighQuality = allHighQualityVectorSearch = allHighQualityFullTextSearch = false;
    }
    if (d['indexing_technique'] == 'high_quality') {
      allEconomic = false;
      final method = jsGet(d['retrieval_model_dict'], 'search_method');
      if (method != RetrieveMethod.semantic) allHighQualityVectorSearch = false;
      if (method != RetrieveMethod.fullText) allHighQualityFullTextSearch = false;
    }
    if (d['provider'] != 'external') {
      allExternal = false;
    } else {
      allInternal = false;
      allHighQuality = allHighQualityVectorSearch = allHighQualityFullTextSearch = false;
      mixtureHighQualityAndEconomic = false;
    }
  }
  if (allExternal || allInternal) mixtureInternalAndExternal = false;
  if (allHighQuality || allEconomic) mixtureHighQualityAndEconomic = false;
  if (allHighQuality) inconsistentEmbeddingModel = {for (final d in list) d['embedding_model']}.length > 1;
  return (
    allHighQuality: allHighQuality,
    allHighQualityVectorSearch: allHighQualityVectorSearch,
    allHighQualityFullTextSearch: allHighQualityFullTextSearch,
    allEconomic: allEconomic,
    mixtureHighQualityAndEconomic: mixtureHighQualityAndEconomic,
    allInternal: allInternal,
    allExternal: allExternal,
    mixtureInternalAndExternal: mixtureInternalAndExternal,
    inconsistentEmbeddingModel: inconsistentEmbeddingModel,
  );
}

/// A model identity (`{provider?, model?}`), the fallback rerank model.
typedef ModelIdentity = ({String? provider, String? model});

bool _validModel(Object? m) => jsTruthy(jsStr(jsGet(m, 'provider'))) && jsTruthy(jsStr(jsGet(m, 'model')));

/// `getMultipleRetrievalConfig`: the multi-path config fitting [selectedDatasets] (rerank mode, enable, model and
/// weights per the datasets' mix; [originalDatasets] tell whether the selection changed).
Json getMultipleRetrievalConfig(
  Json? multipleRetrievalConfig,
  List<Json> selectedDatasets,
  List<Json> originalDatasets, [
  ModelIdentity? fallbackRerankModel,
]) {
  final a = {for (final d in selectedDatasets) d['id']}, b = {for (final d in originalDatasets) d['id']};
  final isDatasetsChanged = a.difference(b).isNotEmpty || b.difference(a).isNotEmpty;
  final fallbackValid = jsTruthy(fallbackRerankModel?.provider) && jsTruthy(fallbackRerankModel?.model);
  final mode = getSelectedDatasetsMode(selectedDatasets);
  final c = multipleRetrievalConfig ?? const {'top_k': DatasetDefault.topK};
  final rerankingMode = c['reranking_mode'], weights = c['weights'], rerankingEnable = c['reranking_enable'];
  final result = <String, Object?>{
    'top_k': c['top_k'] ?? DatasetDefault.topK,
    'score_threshold': c['score_threshold'],
    'reranking_mode': rerankingMode,
    'reranking_model': c['reranking_model'],
    'weights': weights,
    'reranking_enable': rerankingEnable,
  };
  Json fallback() => {'provider': fallbackRerankModel?.provider ?? '', 'model': fallbackRerankModel?.model ?? ''};
  void fillModel() {
    if (!_validModel(result['reranking_model']) && fallbackValid) result['reranking_model'] = fallback();
  }

  void setDefaultWeights() {
    final w = mode.allHighQualityVectorSearch
        ? (1.0, 0.0)
        : mode.allHighQualityFullTextSearch
        ? (0.0, 1.0)
        : (0.7, 0.3);
    result['weights'] = {
      'weight_type': 'customized',
      'vector_setting': {
        'vector_weight': w.$1,
        'embedding_provider_name': selectedDatasets.first['embedding_model_provider'],
        'embedding_model_name': selectedDatasets.first['embedding_model'],
      },
      'keyword_setting': {'keyword_weight': w.$2},
    };
  }

  if ((mode.allEconomic && mode.allInternal) || mode.allExternal) {
    result['reranking_mode'] = RerankingMode.rerankingModel;
    fillModel();
    result['reranking_enable'] = rerankingEnable;
  }
  if (mode.mixtureHighQualityAndEconomic || mode.inconsistentEmbeddingModel || mode.mixtureInternalAndExternal) {
    result['reranking_mode'] = RerankingMode.rerankingModel;
    fillModel();
    result['reranking_enable'] = true;
  }
  if (mode.allHighQuality && !mode.inconsistentEmbeddingModel && mode.allInternal) {
    if (!jsTruthy(rerankingMode)) {
      if (fallbackValid) {
        result
          ..['reranking_mode'] = RerankingMode.rerankingModel
          ..['reranking_enable'] = true
          ..['reranking_model'] = fallback();
      } else {
        result
          ..['reranking_mode'] = RerankingMode.weightedScore
          ..['reranking_enable'] = false;
        setDefaultWeights();
      }
    }
    if (rerankingMode == RerankingMode.weightedScore) {
      result['reranking_enable'] = false;
      if (!jsTruthy(weights)) setDefaultWeights();
    }
    if (rerankingMode == RerankingMode.rerankingModel) {
      fillModel();
      result['reranking_enable'] = true;
    }
    if (rerankingMode == RerankingMode.weightedScore && jsTruthy(weights) && isDatasetsChanged) {
      if (_validModel(result['reranking_model']) || fallbackValid) {
        result
          ..['reranking_mode'] = RerankingMode.rerankingModel
          ..['reranking_enable'] = true;
        fillModel();
      } else {
        setDefaultWeights();
      }
    }
    if (rerankingMode == RerankingMode.rerankingModel &&
        !_validModel(result['reranking_model']) &&
        !fallbackValid &&
        isDatasetsChanged) {
      result
        ..['reranking_mode'] = RerankingMode.weightedScore
        ..['reranking_enable'] = false;
      setDefaultWeights();
    }
  }
  return result;
}

// ---- hooks/use-knowledge-input-manager.ts ------------------------------------------------------------------------

/// `normalizeInputs`: the inactive mode's config goes.
Json normalizeKrInputs(Json next) {
  final out = {...next};
  out.remove(next['retrieval_mode'] == RetrieveType.multiWay ? 'single_retrieval_config' : 'multiple_retrieval_config');
  return out;
}

/// useKnowledgeInputManager: [setInputs] normalizes; the query selectors' handlers.
class KrInputManager {
  KrInputManager({required this.inputs, required this.doSetInputs});

  /// `inputRef.current`.
  Json inputs;
  void Function(Json inputs) doSetInputs;

  void setInputs(Json next) {
    final n = normalizeKrInputs(next);
    doSetInputs(n);
    inputs = n;
  }

  void handleQueryVarChange(List<String> selector) =>
      setInputs({...jsonClone(inputs), 'query_variable_selector': selector});

  void handleQueryAttachmentChange(List<String> selector) =>
      setInputs({...jsonClone(inputs), 'query_attachment_selector': selector});
}

// ---- hooks/use-knowledge-dataset-selection.ts --------------------------------------------------------------------

/// useKnowledgeDatasetSelection's state and handlers: the selected datasets' details (loaded once), the rerank
/// popover's open state.
class KrDatasetSelection {
  KrDatasetSelection({
    required this.inputsOf,
    required this.setInputs,
    required this.payloadRetrievalMode,
    this.updateDatasetsDetail,
    this.fallbackRerankModel = (provider: null, model: null),
    this.fetchDatasets,
  });

  final Json Function() inputsOf;
  final void Function(Json inputs) setInputs;
  final String? Function() payloadRetrievalMode;
  void Function(List<Json> datasets)? updateDatasetsDetail;
  ModelIdentity fallbackRerankModel;
  Future<List<Json>> Function(List<String> ids)? fetchDatasets;

  List<Json> selectedDatasets = const [];
  bool selectedDatasetsLoaded = false;
  bool rerankModelOpen = false;

  /// The mount effect: the datasets' details, then the ids written back and the selection marked loaded.
  Future<void> load() async {
    final ids = [for (final id in jsList(inputsOf()['dataset_ids'])) jsKey(id)];
    if (ids.isNotEmpty && fetchDatasets != null) {
      try {
        selectedDatasets = await fetchDatasets!(ids);
      } on Object {
        selectedDatasets = const [];
      }
    }
    setInputs({...jsonClone(inputsOf()), 'dataset_ids': ids});
    selectedDatasetsLoaded = true;
  }

  /// handleOnDatasetsChange.
  void handleOnDatasetsChange(List<Json> newDatasets) {
    final mode = getSelectedDatasetsMode(newDatasets);
    final noMultiModal = newDatasets.every((d) => d['is_multimodal'] != true);
    final next = jsonClone(inputsOf());
    next['dataset_ids'] = [for (final d in newDatasets) d['id']];
    if (payloadRetrievalMode() == RetrieveType.multiWay && newDatasets.isNotEmpty) {
      next['multiple_retrieval_config'] = getMultipleRetrievalConfig(
        jsMap(next['multiple_retrieval_config']),
        newDatasets,
        selectedDatasets,
        fallbackRerankModel,
      );
    }
    if (noMultiModal) next['query_attachment_selector'] = <String>[];
    updateDatasetsDetail?.call(newDatasets);
    setInputs(next);
    selectedDatasets = newDatasets;
    if ((mode.allInternal && (mode.mixtureHighQualityAndEconomic || mode.inconsistentEmbeddingModel)) ||
        mode.mixtureInternalAndExternal ||
        mode.allExternal) {
      rerankModelOpen = true;
    }
  }

  bool get showImageQueryVarSelector => selectedDatasets.any((d) => d['is_multimodal'] == true);
}

// ---- hooks/use-knowledge-model-config.ts -------------------------------------------------------------------------

/// The current text generation model (provider, model, mode).
typedef TextModelIdentity = ({String provider, String model, String? mode});

Json _singleConfig(String provider, String name, String mode) => {
  'model': {'provider': provider, 'name': name, 'mode': mode, 'completion_params': <String, Object?>{}},
};

/// useKnowledgeModelConfig's handlers and its init effect ([init]).
class KrModelConfig {
  KrModelConfig({
    required this.inputsOf,
    required this.setInputs,
    required this.selectedDatasets,
    this.currentModel,
    this.fallbackRerankModel = (provider: null, model: null),
    this.hasRerankDefaultModel = false,
  });

  final Json Function() inputsOf;
  final void Function(Json inputs) setInputs;
  final List<Json> Function() selectedDatasets;
  TextModelIdentity? currentModel;
  ModelIdentity fallbackRerankModel;
  bool hasRerankDefaultModel;

  Json _model(Json draft) {
    if (draft['single_retrieval_config'] is! Map) draft['single_retrieval_config'] = _singleConfig('', '', '');
    return jsMap(jsMap(draft['single_retrieval_config'])['model']);
  }

  void handleModelChanged(({String provider, String modelId, String? mode}) m) {
    final next = jsonClone(inputsOf());
    _model(next)
      ..['provider'] = m.provider
      ..['name'] = m.modelId
      ..['mode'] = m.mode ?? 'chat';
    setInputs(next);
  }

  void handleCompletionParamsChange(Json params) {
    final current = jsGet(jsGet(inputsOf()['single_retrieval_config'], 'model'), 'completion_params');
    if (jsonEquals(params, current)) return;
    final next = jsonClone(inputsOf());
    _model(next)['completion_params'] = params;
    setInputs(next);
  }

  /// The init effect (also rerun when the default models change).
  void init() {
    final current = inputsOf();
    if (current['retrieval_mode'] == RetrieveType.multiWay &&
        jsTruthy(jsGet(jsGet(current['multiple_retrieval_config'], 'reranking_model'), 'provider')) &&
        jsTruthy(fallbackRerankModel.model) &&
        hasRerankDefaultModel) {
      return;
    }
    if (current['retrieval_mode'] == RetrieveType.oneWay &&
        jsTruthy(jsGet(jsGet(current['single_retrieval_config'], 'model'), 'provider'))) {
      return;
    }
    final next = jsonClone(current);
    final cm = currentModel;
    if (cm != null && cm.provider.isNotEmpty && cm.model.isNotEmpty) {
      if (!jsTruthy(jsGet(jsGet(next['single_retrieval_config'], 'model'), 'provider'))) {
        next['single_retrieval_config'] = _singleConfig(cm.provider, cm.model, cm.mode ?? 'chat');
      }
    }
    final m = jsMap(next['multiple_retrieval_config']);
    next['multiple_retrieval_config'] = {
      'top_k': jsTruthy(m['top_k']) ? m['top_k'] : DatasetDefault.topK,
      'score_threshold': m['score_threshold'],
      'reranking_model': m['reranking_model'],
      'reranking_mode': m['reranking_mode'],
      'weights': m['weights'],
      'reranking_enable': m.containsKey('reranking_enable') && m['reranking_enable'] != null
          ? m['reranking_enable']
          : jsTruthy(fallbackRerankModel.model) && hasRerankDefaultModel,
    };
    setInputs(next);
  }

  void handleRetrievalModeChange(String newMode) {
    final next = jsonClone(inputsOf());
    next['retrieval_mode'] = newMode;
    if (newMode == RetrieveType.multiWay) {
      next['multiple_retrieval_config'] = getMultipleRetrievalConfig(
        jsMap(next['multiple_retrieval_config']),
        selectedDatasets(),
        selectedDatasets(),
        fallbackRerankModel,
      );
    } else if (!jsTruthy(jsGet(jsGet(next['single_retrieval_config'], 'model'), 'provider'))) {
      next['single_retrieval_config'] = _singleConfig(
        currentModel?.provider ?? '',
        currentModel?.model ?? '',
        currentModel?.mode ?? 'chat',
      );
    }
    setInputs(next);
  }

  void handleMultipleRetrievalConfigChange(Json config) => setInputs({
    ...jsonClone(inputsOf()),
    'multiple_retrieval_config': getMultipleRetrievalConfig(
      config,
      selectedDatasets(),
      selectedDatasets(),
      fallbackRerankModel,
    ),
  });
}

// ---- hooks/use-knowledge-metadata-config.ts ----------------------------------------------------------------------

/// `MetadataFilteringModeEnum`.
abstract final class MetadataFilteringMode {
  static const disabled = 'disabled';
  static const automatic = 'automatic';
  static const manual = 'manual';
}

/// `MetadataFilteringVariableType`.
abstract final class MetadataVarType {
  static const string = 'string';
  static const number = 'number';
  static const time = 'time';
  static const select = 'select';
}

/// useKnowledgeMetadataConfig's handlers ([newId] is uuid4).
class KrMetadataConfig {
  KrMetadataConfig({required this.inputsOf, required this.setInputs, String Function()? newId})
    : newId = newId ?? uuid4;

  final Json Function() inputsOf;
  final void Function(Json inputs) setInputs;
  final String Function() newId;

  void _produce(void Function(Json d) f) {
    final d = jsonClone(inputsOf());
    f(d);
    setInputs(d);
  }

  List<Object?>? _conditions(Json d) => jsGet(d['metadata_filtering_conditions'], 'conditions') as List<Object?>?;

  void handleMetadataFilterModeChange(String mode) => _produce((d) => d['metadata_filtering_mode'] = mode);

  void handleAddCondition(Json metadata) => _produce((d) {
    final condition = {
      'id': newId(),
      'metadata_id': metadata['id'],
      'name': metadata['name'],
      'comparison_operator': metadata['type'] == MetadataVarType.number ? '=' : 'is',
    };
    final list = _conditions(d);
    if (d['metadata_filtering_conditions'] is Map && list != null) {
      list.add(condition);
      return;
    }
    d['metadata_filtering_conditions'] = {
      'logical_operator': 'and',
      'conditions': [condition],
    };
  });

  void handleRemoveCondition(String id) => _produce((d) => _conditions(d)?.removeWhere((c) => jsGet(c, 'id') == id));

  void handleUpdateCondition(String id, Json condition) => _produce((d) {
    final list = _conditions(d);
    final i = list?.indexWhere((c) => jsGet(c, 'id') == id) ?? -1;
    if (i > -1) list![i] = condition;
  });

  void handleToggleConditionLogicalOperator() => _produce((d) {
    final c = d['metadata_filtering_conditions'];
    if (c is! Map) return;
    c['logical_operator'] = c['logical_operator'] == 'and' ? 'or' : 'and';
  });

  void handleMetadataModelChange(({String provider, String modelId, String? mode}) m) => _produce((d) {
    d['metadata_model_config'] = {
      'provider': m.provider,
      'name': m.modelId,
      'mode': (m.mode ?? '').isEmpty ? 'chat' : m.mode,
      'completion_params': jsGet(d['metadata_model_config'], 'completion_params') ?? {'temperature': 0.7},
    };
  });

  void handleMetadataCompletionParamsChange(Json params) =>
      _produce((d) => d['metadata_model_config'] = {...jsMap(d['metadata_model_config']), 'completion_params': params});
}

/// `intersectionBy(...doc_metadata, 'name')`: the metadata fields every dataset with metadata has (by name, the
/// first dataset's entries).
List<Json> metadataIntersection(List<Json> selectedDatasets) {
  final lists = [
    for (final d in selectedDatasets)
      if (d['doc_metadata'] is List) [for (final m in jsList(d['doc_metadata'])) jsMap(m)],
  ];
  if (lists.isEmpty) return const [];
  final rest = [
    for (final l in lists.skip(1)) {for (final m in l) m['name']},
  ];
  final seen = <Object?>{};
  return [
    for (final m in lists.first)
      if (rest.every((names) => names.contains(m['name'])) && seen.add(m['name'])) m,
  ];
}

// ---- metadata condition utils (condition-list/utils.ts) -----------------------------------------------------------

const _notTranslate = {'=', '≠', '>', '≥', '<', '≤'};

/// `isComparisonOperatorNeedTranslate`.
bool isComparisonOperatorNeedTranslate(String? operator) => operator != null && !_notTranslate.contains(operator);

/// `getOperators`.
List<String> getMetadataOperators(String? type) => switch (type) {
  MetadataVarType.string || MetadataVarType.select => const [
    'is',
    'is not',
    'contains',
    'not contains',
    'start with',
    'end with',
    'empty',
    'not empty',
    'in',
    'not in',
  ],
  MetadataVarType.number => const ['=', '≠', '>', '<', '≥', '≤', 'empty', 'not empty'],
  _ => const ['is', 'before', 'after', 'empty', 'not empty'],
};

/// `comparisonOperatorNotRequireValue`.
bool comparisonOperatorNotRequireValue(String? operator) =>
    operator != null &&
    const {'empty', 'not empty', 'is null', 'is not null', 'exists', 'not exists'}.contains(operator);

/// `VARIABLE_REGEX`.
final metadataVariableRegex = RegExp(r'\{\{(#[\w-]{1,50}(\.[a-z_]\w{0,29}){1,10}#)\}\}', caseSensitive: false);

/// `COMMON_VARIABLE_REGEX`.
final metadataCommonVariableRegex = RegExp(r'\{\{([\w-]{1,50})\}\}');

/// The condition's metadata (condition-item.tsx `currentMetadata`): by id and name, then a unique id, then name.
Json? conditionMetadata(Json condition, List<Json> metadataList) {
  final id = condition['metadata_id'], name = condition['name'];
  if (jsTruthy(id)) {
    final both = metadataList.where((m) => m['id'] == id && m['name'] == name).firstOrNull;
    if (both != null) return both;
    final byId = metadataList.where((m) => m['id'] == id).toList();
    if (byId.length == 1) return byId.single;
  }
  return metadataList.where((m) => m['name'] == name).firstOrNull;
}

/// `valueAndValueMethod`: a `{{#node.var#}}` string value of a string / number / select field is a variable
/// (`node.var`), anything else a constant.
({Object? value, String valueMethod}) conditionValueAndMethod(Object? value, String? type, {bool isCommon = false}) {
  if ((type == MetadataVarType.string || type == MetadataVarType.number || type == MetadataVarType.select) &&
      value is String) {
    final m = (isCommon ? metadataCommonVariableRegex : metadataVariableRegex).firstMatch(value);
    final n = isCommon ? 2 : 3;
    if (m != null) {
      final s = m[0]!;
      return (value: s.substring(n, s.length - n), valueMethod: 'variable');
    }
    return (value: value, valueMethod: 'constant');
  }
  return (value: value, valueMethod: 'constant');
}

/// The stale conditions MetadataTrigger removes once the datasets are loaded: no metadata with their id (or, for
/// conditions without one, their name).
List<String> staleConditionIds(List<Json> conditions, List<Json> metadataList) => [
  for (final c in conditions)
    if (!(jsTruthy(c['metadata_id'])
        ? metadataList.any((m) => m['id'] == c['metadata_id'])
        : metadataList.any((m) => m['name'] == c['name'])))
      '${c['id']}',
];

// ---- components/retrieval-config.tsx -------------------------------------------------------------------------------

/// RetrievalConfig's `datasetConfigs`: the multi-path config as ConfigContent reads it.
Json datasetConfigsOf(String? retrievalMode, Json? multiple) {
  final m = multiple ?? const <String, Object?>{};
  final rm = m['reranking_model'];
  final st = m['score_threshold'];
  return {
    'retrieval_model': retrievalMode,
    'reranking_model': _validModel(rm)
        ? {'reranking_provider_name': jsGet(rm, 'provider'), 'reranking_model_name': jsGet(rm, 'model')}
        : {'reranking_provider_name': '', 'reranking_model_name': ''},
    'top_k': jsTruthy(m['top_k']) ? m['top_k'] : DatasetDefault.topK,
    'score_threshold_enabled': st != null,
    'score_threshold': st,
    'reranking_mode': m['reranking_mode'],
    'weights': m['weights'],
    'reranking_enable': m['reranking_enable'],
  };
}

/// RetrievalConfig's handleChange: ConfigContent's configs back as `multiple_retrieval_config`.
Json multipleConfigFromDatasetConfigs(Json configs, String? retrievalMode) {
  final provider = jsStr(jsGet(configs['reranking_model'], 'reranking_provider_name'));
  return {
    'top_k': configs['top_k'],
    'score_threshold': configs['score_threshold_enabled'] == true
        ? (configs['score_threshold'] ?? DatasetDefault.scoreThreshold)
        : null,
    'reranking_model': retrievalMode == RetrieveType.oneWay || !jsTruthy(provider)
        ? null
        : {'provider': provider, 'model': jsGet(configs['reranking_model'], 'reranking_model_name')},
    'reranking_mode': configs['reranking_mode'],
    'weights': configs['weights'],
    'reranking_enable': configs['reranking_enable'],
  };
}

/// `formatIndexingTechniqueAndMethod` (hooks/use-knowledge.ts) with [t] the `dataset` namespace.
String formatIndexingTechniqueAndMethod(String Function(String key) t, Object? technique, Object? method) {
  var result = t('indexingTechnique.$technique');
  if (jsTruthy(method)) {
    result += ' · ${technique == 'economy' ? t('indexingMethod.invertedIndex') : t('indexingMethod.$method')}';
  }
  return result;
}
