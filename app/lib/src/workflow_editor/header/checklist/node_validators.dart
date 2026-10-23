/// The node validators (`checkValid` of web/app/components/workflow/nodes/*/default.ts, Dify 1.17.1) whose checks are
/// pure data logic, working on the node's Dify `data` (plain JSON, see `difyDataOf`).
///
/// Each returns the error message, '' when the node is valid. The messages, their order and the quirks are Dify's
/// (e.g. the if-else boolean sub-condition check, the legacy agent's tool-schema checks that never fail). Where Dify
/// would throw on a missing field (`variables.filter` of `undefined`), the ports read it as empty.
///
/// Not ported (they need plugin or server data): tool, datasource, datasource-empty, knowledge-index (model lists),
/// trigger-plugin, trigger-webhook, trigger-schedule and agent-v2.
library;

import '../../../workflow/dify_json.dart';
import '../../../workflow/model_catalog.dart' show renderI18nObject;

/// Dify's `t(key, { ns, ...params })`.
typedef ChecklistTranslate = String Function(String ns, String key, [Map<String, Object?> params]);

/// A node's `checkValid`: the error message for [data], '' when valid. [moreData] is Dify's `moreDataForCheckValid`.
typedef NodeCheckValid = String Function(
  Map<String, Object?> data,
  ChecklistTranslate t,
  Map<String, Object?>? moreData,
);

/// `LOOP_NODE_MAX_COUNT` (web/config, `NEXT_PUBLIC_LOOP_NODE_MAX_COUNT` default).
const loopNodeMaxCount = 100;

/// The ported validators by node type (`BlockEnum` value).
const Map<String, NodeCheckValid> nodeCheckValid = {
  'start': _valid,
  'iteration-start': _valid,
  'loop-start': _valid,
  'loop-end': _valid,
  'start-placeholder': _startPlaceholder,
  'end': _end,
  'answer': _answer,
  'llm': checkValidLLM,
  'knowledge-retrieval': _knowledgeRetrieval,
  'question-classifier': _questionClassifier,
  'if-else': _ifElse,
  'code': _code,
  'template-transform': _templateTransform,
  'http-request': _http,
  'variable-aggregator': _variableAggregator,
  // useAvailableNodesMetaData maps the legacy type to the aggregator's metadata.
  'variable-assigner': _variableAggregator,
  'parameter-extractor': _parameterExtractor,
  'iteration': _iteration,
  'document-extractor': _documentExtractor,
  'list-operator': _listOperator,
  'assigner': _assigner,
  'agent': checkValidAgent,
  'loop': _loop,
  'human-input': _humanInput,
};

// ---- JS helpers --------------------------------------------------------------------------------------------------

/// `x.length` of a string or an array; null (undefined) otherwise.
int? _len(Object? x) => switch (x) {
  final String s => s.length,
  final List l => l.length,
  _ => null,
};

/// `!x?.length`.
bool _noLength(Object? x) => !jsTruthy(_len(x));

String _required(ChecklistTranslate t, String field, [String prefix = 'errorMsg']) =>
    t('workflow', '$prefix.fieldRequired', {'field': field});

String _w(ChecklistTranslate t, String key) => t('workflow', key);

/// `x === undefined` for a member of [m].
bool _undefined(Object? m, String key) => m is! Map || !m.containsKey(key);

// ---- comparison operators (if-else/utils.ts) ---------------------------------------------------------------------

const _emptyRelatedOperators = {'empty', 'not empty', 'is null', 'is not null', 'exists', 'not exists'};

/// `isEmptyRelatedOperator` (if-else/utils.ts).
bool isEmptyRelatedOperator(Object? operator) => _emptyRelatedOperators.contains(operator);

/// `comparisonOperatorNotRequireValue` (if-else/utils.ts).
bool comparisonOperatorNotRequireValue(Object? operator) =>
    jsTruthy(operator) && _emptyRelatedOperators.contains(operator);

// ---- validators --------------------------------------------------------------------------------------------------

String _valid(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) => '';

String _startPlaceholder(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) =>
    _w(t, 'nodes.startPlaceholder.validationRequired');

String _end(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  final outputs = jsList(data['outputs']);
  final invalid =
      outputs.isEmpty ||
      outputs.any((o) {
        final name = jsStr(jsGet(o, 'variable'))?.trim();
        final selector = jsGet(o, 'value_selector');
        return !jsTruthy(name) || !(selector is List && selector.isNotEmpty);
      });
  return invalid ? _required(t, _w(t, 'nodes.end.output.variable')) : '';
}

String _answer(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) =>
    jsTruthy(data['answer']) ? '' : _required(t, _w(t, 'nodes.answer.answer'));

String _variablesCheck(Map<String, Object?> data, ChecklistTranslate t) {
  final variables = jsList(data['variables']);
  if (variables.any((v) => !jsTruthy(jsGet(v, 'variable')))) {
    return _required(t, _w(t, 'errorMsg.fields.variable'));
  }
  if (variables.any((v) => !jsTruthy(_len(jsGet(v, 'value_selector'))))) {
    return _required(t, _w(t, 'errorMsg.fields.variableValue'));
  }
  return '';
}

String _code(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  final e = _variablesCheck(data, t);
  if (e.isNotEmpty) return e;
  return jsTruthy(data['code']) ? '' : _required(t, _w(t, 'errorMsg.fields.code'));
}

String _templateTransform(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  final e = _variablesCheck(data, t);
  if (e.isNotEmpty) return e;
  return jsTruthy(data['template']) ? '' : _required(t, _w(t, 'nodes.templateTransform.code'));
}

String _http(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  if (!jsTruthy(data['url'])) return _required(t, _w(t, 'nodes.http.api'));
  final body = data['body'];
  if (jsGet(body, 'type') == 'binary') {
    final file = jsGet(jsGet(jsGet(body, 'data'), '0'), 'file');
    if (!jsTruthy(file) || _len(file) == 0) return _required(t, _w(t, 'nodes.http.binaryFileVariable'));
  }
  return '';
}

String _documentExtractor(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) =>
    _noLength(data['variable_selector']) ? _required(t, _w(t, 'nodes.assigner.assignedVariable')) : '';

String _iteration(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  if (_noLength(data['iterator_selector'])) return _required(t, _w(t, 'nodes.iteration.input'));
  if (_noLength(data['output_selector'])) return _required(t, _w(t, 'nodes.iteration.output'));
  return '';
}

/// `Number(x)` for the JSON values a loop count can hold.
num _jsNumber(Object? x, {required bool undefined}) => switch (x) {
  null => undefined ? double.nan : 0,
  final num n => n,
  final bool b => b ? 1 : 0,
  final String s => s.trim().isEmpty ? 0 : (num.tryParse(s.trim()) ?? double.nan),
  _ => double.nan,
};

String _loop(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  var error = '';
  for (final v in jsList(data['loop_variables'])) {
    if (!jsTruthy(jsGet(v, 'label'))) error = _required(t, _w(t, 'errorMsg.fields.variable'));
  }
  for (final c in jsList(data['break_conditions'])) {
    if (error.isEmpty && _noLength(jsGet(c, 'variable_selector'))) {
      error = _required(t, _w(t, 'errorMsg.fields.variable'));
    }
    final op = jsGet(c, 'comparison_operator');
    if (error.isEmpty && !jsTruthy(op)) error = _required(t, _w(t, 'nodes.ifElse.operator'));
    if (error.isNotEmpty) continue;
    final sub = jsGet(c, 'sub_variable_condition');
    if (jsTruthy(sub) && op != 'empty' && op != 'not empty') {
      final isSet = jsList(jsGet(sub, 'conditions')).every((s) {
        final sop = jsGet(s, 'comparison_operator');
        if (!jsTruthy(sop)) return false;
        if (isEmptyRelatedOperator(sop)) return true;
        return jsTruthy(jsGet(s, 'value'));
      });
      if (!isSet) error = _required(t, _w(t, 'errorMsg.fields.variableValue'));
    } else if (!isEmptyRelatedOperator(op) &&
        (jsGet(c, 'varType') == 'boolean' ? _undefined(c, 'value') : !jsTruthy(jsGet(c, 'value')))) {
      error = _required(t, _w(t, 'errorMsg.fields.variableValue'));
    }
  }
  if (error.isEmpty) {
    final count = _jsNumber(data['loop_count'], undefined: !data.containsKey('loop_count'));
    if (count.isNaN || count != count.truncate() || count < 1 || count > loopNodeMaxCount) {
      error = t('workflow', 'nodes.loop.loopMaxCountError', {'maxCount': loopNodeMaxCount});
    }
  }
  return error;
}

String _ifElse(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  var error = '';
  final cases = jsList(data['cases']);
  if (cases.isEmpty) error = _required(t, 'IF');
  for (final (index, caseItem) in cases.indexed) {
    final conditions = jsList(jsGet(caseItem, 'conditions'));
    if (conditions.isEmpty) error = _required(t, index == 0 ? 'IF' : 'ELIF');
    for (final c in conditions) {
      if (error.isEmpty && _noLength(jsGet(c, 'variable_selector'))) {
        error = _required(t, _w(t, 'errorMsg.fields.variable'));
      }
      final op = jsGet(c, 'comparison_operator');
      if (error.isEmpty && !jsTruthy(op)) error = _required(t, _w(t, 'nodes.ifElse.operator'));
      if (error.isNotEmpty) continue;
      bool isBool(Object? x) => jsGet(x, 'varType') == 'boolean' || jsGet(x, 'varType') == 'array[boolean]';
      final sub = jsGet(c, 'sub_variable_condition');
      if (jsTruthy(sub)) {
        final isSet = jsList(jsGet(sub, 'conditions')).every((s) {
          final sop = jsGet(s, 'comparison_operator');
          if (!jsTruthy(sop)) return false;
          if (isEmptyRelatedOperator(sop)) return true;
          // Dify's quirk: a boolean sub-condition counts as set when its value is undefined.
          return isBool(s) ? _undefined(s, 'value') : jsTruthy(jsGet(s, 'value'));
        });
        if (!isSet) error = _required(t, _w(t, 'errorMsg.fields.variableValue'));
      } else if (!isEmptyRelatedOperator(op) && (isBool(c) ? _undefined(c, 'value') : !jsTruthy(jsGet(c, 'value')))) {
        error = _required(t, _w(t, 'errorMsg.fields.variableValue'));
      }
    }
  }
  return error;
}

String _questionClassifier(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  if (_noLength(data['query_variable_selector'])) {
    return _required(t, _w(t, 'nodes.questionClassifiers.inputVars'));
  }
  if (!jsTruthy(jsGet(data['model'], 'provider'))) return _required(t, _w(t, 'nodes.questionClassifiers.model'));
  final classes = jsList(data['classes']);
  if (classes.isEmpty) return _required(t, _w(t, 'nodes.questionClassifiers.class'));
  if (classes.any((c) => !jsTruthy(jsGet(c, 'name')))) {
    return _required(t, _w(t, 'nodes.questionClassifiers.topicName'));
  }
  return _visionCheck(data, t);
}

String _visionCheck(Map<String, Object?> data, ChecklistTranslate t) {
  final vision = data['vision'];
  if (jsTruthy(jsGet(vision, 'enabled')) && _noLength(jsGet(jsGet(vision, 'configs'), 'variable_selector'))) {
    return _required(t, _w(t, 'errorMsg.fields.visionVariable'));
  }
  return '';
}

String _parameterExtractor(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  if (_noLength(data['query'])) return _required(t, _w(t, 'nodes.parameterExtractor.inputVar'));
  if (!jsTruthy(jsGet(data['model'], 'provider'))) return _required(t, _w(t, 'errorMsg.fields.model'));
  final parameters = jsList(data['parameters']);
  if (parameters.isEmpty) return _required(t, _w(t, 'nodes.parameterExtractor.extractParameters'));
  const content = 'nodes.parameterExtractor.addExtractParameterContent';
  for (final p in parameters) {
    if (!jsTruthy(jsGet(p, 'name'))) return _required(t, _w(t, '$content.namePlaceholder'));
    if (!jsTruthy(jsGet(p, 'type'))) return _required(t, _w(t, '$content.typePlaceholder'));
    if (!jsTruthy(jsGet(p, 'description'))) return _required(t, _w(t, '$content.descriptionPlaceholder'));
  }
  return _visionCheck(data, t);
}

String _variableAggregator(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  var error = '';
  final settings = data['advanced_settings'];
  void validate(List<Object?> variables) {
    for (final v in variables) {
      if (!jsTruthy(v) || _len(v) == 0) error = _required(t, _w(t, 'errorMsg.fields.variableValue'));
    }
  }

  if (jsTruthy(jsGet(settings, 'group_enabled'))) {
    final groups = jsList(jsGet(settings, 'groups'));
    if (groups.isEmpty) {
      error = _required(t, _w(t, 'nodes.variableAssigner.title'));
    } else {
      for (final g in groups) {
        validate(jsList(jsGet(g, 'variables')));
      }
    }
  } else {
    final variables = jsList(data['variables']);
    if (variables.isEmpty) {
      error = _required(t, _w(t, 'nodes.variableAssigner.title'));
    } else {
      validate(variables);
    }
  }
  return error;
}

String _assigner(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  var error = '';
  for (final item in jsList(data['items'])) {
    if (error.isEmpty && _noLength(jsGet(item, 'variable_selector'))) {
      error = _required(t, _w(t, 'nodes.assigner.assignedVariable'));
    }
    final op = jsGet(item, 'operation');
    if (error.isNotEmpty || op == 'clear' || op == 'remove-first' || op == 'remove-last') continue;
    final value = jsGet(item, 'value');
    final missing = const {'set', '+=', '-=', '*=', '/='}.contains(op)
        ? !jsTruthy(value) && value != false && value is! num
        : _noLength(value);
    if (missing) error = _required(t, _w(t, 'nodes.assigner.variable'));
  }
  return error;
}

String _listOperator(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  if (_noLength(data['variable'])) return _required(t, _w(t, 'nodes.listFilter.inputVar'));
  final filterBy = data['filter_by'];
  if (!jsTruthy(jsGet(filterBy, 'enabled'))) return '';
  final condition = jsGet(jsGet(filterBy, 'conditions'), '0');
  if (data['var_type'] == 'array[file]' && !jsTruthy(jsGet(condition, 'key'))) {
    return _required(t, _w(t, 'nodes.listFilter.filterConditionKey'));
  }
  final op = jsGet(condition, 'comparison_operator');
  if (!jsTruthy(op)) return _required(t, _w(t, 'nodes.listFilter.filterConditionComparisonOperator'));
  final missingValue = data['item_var_type'] == 'boolean'
      ? _undefined(condition, 'value')
      : !jsTruthy(jsGet(condition, 'value'));
  if (!comparisonOperatorNotRequireValue(op) && missingValue) {
    return _required(t, _w(t, 'nodes.listFilter.filterConditionComparisonValue'));
  }
  return '';
}

/// `checkoutRerankModelConfiguredInRetrievalSettings` (knowledge-retrieval/utils.ts) with the parts of
/// `getSelectedDatasetsMode` it reads.
bool checkoutRerankModelConfiguredInRetrievalSettings(List<Object?> datasets, Object? multipleRetrievalConfig) {
  if (!jsTruthy(multipleRetrievalConfig)) return true;
  var allEconomic = datasets.isNotEmpty, allExternal = datasets.isNotEmpty, allInternal = datasets.isNotEmpty;
  for (final d in datasets) {
    if (jsGet(d, 'indexing_technique') == 'high_quality') allEconomic = false;
    if (jsGet(d, 'provider') != 'external') {
      allExternal = false;
    } else {
      allInternal = false;
    }
  }
  final model = jsGet(multipleRetrievalConfig, 'reranking_model');
  if (jsGet(multipleRetrievalConfig, 'reranking_mode') == 'reranking_model' &&
      (!jsTruthy(jsGet(model, 'provider')) || !jsTruthy(jsGet(model, 'model')))) {
    return ((allEconomic && allInternal) || allExternal) &&
        !jsTruthy(jsGet(multipleRetrievalConfig, 'reranking_enable'));
  }
  return true;
}

/// Knowledge retrieval: the selected datasets' details come in the data's `_datasets` (Dify's `getCheckData`).
String _knowledgeRetrieval(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  var error = '';
  if (!jsTruthy(data['dataset_ids']) || _len(data['dataset_ids']) == 0) {
    error = _required(t, _w(t, 'nodes.knowledgeRetrieval.knowledge'));
  }
  final mode = data['retrieval_mode'];
  if (error.isEmpty &&
      mode == 'single' &&
      !jsTruthy(jsGet(jsGet(data['single_retrieval_config'], 'model'), 'provider'))) {
    error = _required(t, t('common', 'modelProvider.systemReasoningModel.key'));
  }
  if (mode == 'multiple' &&
      error.isEmpty &&
      !checkoutRerankModelConfiguredInRetrievalSettings(jsList(data['_datasets']), data['multiple_retrieval_config'])) {
    error = _required(t, _w(t, 'errorMsg.fields.rerankModel'));
  }
  return error;
}

String _humanInput(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  const p = 'nodes.humanInput.errorMsg';
  final methods = jsList(data['delivery_methods']);
  if (methods.isEmpty) return _w(t, '$p.noDeliveryMethod');
  if (!methods.any((m) => jsTruthy(jsGet(m, 'enabled')))) return _w(t, '$p.noDeliveryMethodEnabled');
  bool emailComplete(Object? config) {
    if (!jsTruthy(config)) return false;
    final subject = jsStr(jsGet(config, 'subject'))?.trim(), body = jsStr(jsGet(config, 'body'))?.trim();
    if (!jsTruthy(subject) || !jsTruthy(body)) return false;
    if (!body!.contains('{{#url#}}')) return false;
    final recipients = jsGet(config, 'recipients');
    return jsTruthy(jsGet(recipients, 'whole_workspace')) || jsTruthy(_len(jsGet(recipients, 'items')));
  }

  if (methods.any(
    (m) => jsTruthy(jsGet(m, 'enabled')) && jsGet(m, 'type') == 'email' && !emailComplete(jsGet(m, 'config')),
  )) {
    return _w(t, '$p.emailConfigIncomplete');
  }
  final actions = jsList(data['user_actions']);
  if (actions.isEmpty) return _w(t, '$p.noUserActions');
  final ids = [for (final a in actions) jsGet(a, 'id')];
  if (ids.length != ids.toSet().length) return _w(t, '$p.duplicateActionId');
  if (actions.any((a) => !jsTruthy(jsStr(jsGet(a, 'id'))?.trim()))) return _w(t, '$p.emptyActionId');
  if (actions.any((a) => !jsTruthy(jsStr(jsGet(a, 'title'))?.trim()))) return _w(t, '$p.emptyActionTitle');
  return '';
}

// ---- llm ---------------------------------------------------------------------------------------------------------

/// `isEnvironmentModelSource` (llm/utils.ts).
bool isEnvironmentModelSource(Object? modelSelector) =>
    modelSelector is List && (modelSelector.isEmpty || modelSelector[0] == 'env');

/// `isLLMEnvironmentVariableValue` (llm-environment-variable.ts).
bool isLLMEnvironmentVariableValue(Object? value) {
  if (value is! Map) return false;
  final provider = value['provider'], name = value['name'], mode = value['mode'];
  final params = value['completion_params'];
  return provider is String &&
      provider.trim().isNotEmpty &&
      name is String &&
      name.trim().isNotEmpty &&
      (mode == 'chat' || mode == 'completion') &&
      (!value.containsKey('completion_params') || params is Map);
}

/// `resolveLLMNodeModel` (llm/utils.ts): the node's model, or the LLM environment variable its `model_selector`
/// points at (null when that is missing or of another mode). [environmentVariables] are Dify's declarations.
Map<String, Object?>? resolveLLMNodeModel(Object? model, Object? modelSelector, List<Object?> environmentVariables) {
  if (!isEnvironmentModelSource(modelSelector)) return model is Map ? model.cast<String, Object?>() : null;
  final selector = modelSelector! as List;
  if (selector.length != 2 || selector[0] != 'env') return null;
  // (A typed list's firstWhere cannot return null from orElse.)
  final env = environmentVariables
      .where((v) => jsGet(v, 'name') == selector[1] && jsGet(v, 'value_type') == 'llm')
      .firstOrNull;
  final value = jsGet(env, 'value');
  if (value is! Map || !isLLMEnvironmentVariableValue(value) || value['mode'] != jsGet(model, 'mode')) return null;
  return {
    if (model is Map) ...model.cast<String, Object?>(),
    'provider': value['provider'],
    'name': value['name'],
    'completion_params': value['completion_params'] ?? jsGet(model, 'completion_params'),
  };
}

/// `extractPluginId` (utils/plugin.ts): `org/name/provider` -> `org/name`.
String extractPluginId(String provider) {
  final parts = provider.split('/');
  return parts.length >= 2 ? '${parts[0]}/${parts[1]}' : provider;
}

/// LLM (llm/default.ts). [more]: `flowType`, `environmentVariables` (Dify's declarations).
String checkValidLLM(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  var error = '';
  final isSnippetFlow = jsGet(more, 'flowType') == 'snippet';
  final selector = data['model_selector'];
  final hasSelector = data.containsKey('model_selector');
  final hasValidModelSelector =
      !hasSelector || !isEnvironmentModelSource(selector) || (_len(selector) == 2 && jsGet(selector, '0') == 'env');
  final envVars = jsGet(more, 'environmentVariables');
  final model = hasSelector && envVars != null
      ? resolveLLMNodeModel(data['model'], selector, jsList(envVars))
      : data['model'];
  if (!jsTruthy(hasValidModelSelector ? jsGet(model, 'provider') : null)) {
    error = _required(t, _w(t, 'errorMsg.fields.model'));
  }
  final isChatModel = jsGet(model, 'mode') == 'chat';
  final prompt = data['prompt_template'];
  bool isJinja(Object? p) => jsGet(p, 'edition_type') == 'jinja2';
  final memory = data['memory'];
  if (error.isEmpty && !jsTruthy(memory)) {
    final isPromptEmpty = isChatModel
        ? !jsList(prompt).any((p) => isJinja(p) ? jsGet(p, 'jinja2_text') != '' : jsGet(p, 'text') != '')
        : isJinja(prompt)
        ? jsGet(prompt, 'jinja2_text') == ''
        : jsGet(prompt, 'text') == '';
    if (isPromptEmpty) error = _required(t, _w(t, 'nodes.llm.prompt'));
  }
  if (error.isEmpty && jsTruthy(memory)) {
    final query = jsGet(memory, 'query_prompt_template');
    if (!isSnippetFlow && isChatModel && jsTruthy(query) && !'$query'.contains('{{#sys.query#}}')) {
      error = _w(t, 'nodes.llm.sysQueryInUser');
    }
  }
  if (error.isEmpty) {
    final isShowVars = isChatModel ? jsList(prompt).any(isJinja) : isJinja(prompt);
    final jinjaVars = jsGet(data['prompt_config'], 'jinja2_variables');
    if (isShowVars && jsTruthy(jinjaVars)) {
      for (final v in jsList(jinjaVars)) {
        if (error.isEmpty && !jsTruthy(jsGet(v, 'variable'))) error = _required(t, _w(t, 'errorMsg.fields.variable'));
        if (error.isEmpty && _noLength(jsGet(v, 'value_selector'))) {
          error = _required(t, _w(t, 'errorMsg.fields.variableValue'));
        }
      }
    }
  }
  if (error.isEmpty) error = _visionCheck(data, t);
  return error;
}

// ---- legacy agent ------------------------------------------------------------------------------------------------

/// Legacy agent (agent/default.ts). [more]: `strategy` (the strategy's declaration, `{parameters: [...]}`), `language`
/// and `isReadyForCheckValid` (the strategy providers are loaded). Dify's per-tool schema checks run inside `forEach`
/// callbacks whose results are dropped, so they never fail; and a required multi-tool parameter with enabled tools
/// ends the check as valid. Both kept.
String checkValidAgent(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) {
  if (!jsTruthy(jsGet(more, 'isReadyForCheckValid'))) return '';
  final strategy = jsGet(more, 'strategy');
  if (!jsTruthy(strategy)) return _w(t, 'nodes.agent.checkList.strategyNotSelected');
  final language = jsStr(jsGet(more, 'language')) ?? 'en_US';
  String label(Object? param) {
    final l = jsGet(param, 'label');
    return renderI18nObject(l is Map ? {for (final e in l.entries) '${e.key}': jsStr(e.value)} : null, language);
  }

  final params = data['agent_parameters'];
  for (final param in jsList(jsGet(strategy, 'parameters'))) {
    final required = jsTruthy(jsGet(param, 'required'));
    final type = jsGet(param, 'type');
    final value = jsGet(jsGet(params, '${jsGet(param, 'name')}'), 'value');
    if (required && type == 'tool-selector') {
      if (!jsTruthy(value)) return _required(t, label(param));
      if (!jsTruthy(jsGet(value, 'enabled'))) return t('workflow', 'errorMsg.noValidTool', {'field': label(param)});
    }
    if (required && type == 'array[tools]') {
      final tools = jsTruthy(value) ? value : const [];
      if (_noLength(tools)) return _required(t, label(param));
      if (jsList(tools).every((tool) => !jsTruthy(jsGet(tool, 'enabled')))) {
        return t('workflow', 'errorMsg.noValidTool', {'field': label(param)});
      }
      return '';
    }
    if (required && !jsTruthy(jsTruthy(value) ? value : jsGet(param, 'default'))) return _required(t, label(param));
  }
  return '';
}
