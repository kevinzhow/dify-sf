/// The LLM node's logic, ported as pure Dart from Dify 1.17.1 web/app/components/workflow/nodes/llm: utils.ts, the
/// hooks of use-config.ts (use-llm-input-manager, use-llm-prompt-config, use-llm-structured-output-config) and
/// utils/completion-params.ts. Inputs are the node's Dify `data` (plain JSON); handlers hand the next data to
/// `setInputs`, as Dify's do.
library;

import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../header/checklist/node_validators.dart'
    show extractPluginId, isLLMEnvironmentVariableValue, resolveLLMNodeModel;
import '../../../panel_fields/node_config.dart' show Json;
import '../../../prompt_editor/prompt_blocks.dart' show checkHasContextBlock, checkHasHistoryBlock, checkHasQueryBlock;
import 'model_parameter_modal.dart' show ModelParameterRule;
import 'llm_vars.dart' show jsMap;

export '../../../header/checklist/node_validators.dart'
    show isEnvironmentModelSource, isLLMEnvironmentVariableValue, resolveLLMNodeModel;

/// A deep copy of plain JSON (Dify's immer drafts).
T jsonClone<T>(T v) => switch (v) {
  final Map m => {for (final e in m.entries) '${e.key}': jsonClone(e.value)} as T,
  final List l => [for (final e in l) jsonClone(e)] as T,
  _ => v,
};

// ---- utils.ts ----------------------------------------------------------------------------------------------------

/// `getLLMEnvironmentModel`: the LLM environment variable [modelSelector] (`['env', name]`) names, if valid.
Json? getLLMEnvironmentModel(Object? modelSelector, List<Object?> environmentVariables) {
  if (modelSelector is! List || modelSelector.length != 2 || modelSelector[0] != 'env') return null;
  for (final v in environmentVariables) {
    if (jsGet(v, 'name') == modelSelector[1] && jsGet(v, 'value_type') == 'llm') {
      final value = jsGet(v, 'value');
      return isLLMEnvironmentVariableValue(value) ? jsMap(value) : null;
    }
  }
  return null;
}

/// `LLMModelIssueCode`.
enum LLMModelIssueCode {
  providerRequired('provider-required'),
  providerPluginUnavailable('provider-plugin-unavailable');

  const LLMModelIssueCode(this.value);
  final String value;
}

/// `getLLMModelIssue`.
LLMModelIssueCode? getLLMModelIssue({String? modelProvider, bool isModelProviderInstalled = true}) {
  if (modelProvider == null || modelProvider.isEmpty) return LLMModelIssueCode.providerRequired;
  if (!isModelProviderInstalled) return LLMModelIssueCode.providerPluginUnavailable;
  return null;
}

/// `isLLMModelProviderInstalled`.
bool isLLMModelProviderInstalled(String? modelProvider, Set<String> installedPluginIds) =>
    modelProvider == null || modelProvider.isEmpty || installedPluginIds.contains(extractPluginId(modelProvider));

/// Schema `Type` values (llm/types.ts).
abstract final class SchemaType {
  static const string = 'string', number = 'number', boolean = 'boolean', object = 'object', array = 'array';
  static const arrayString = 'array[string]', arrayNumber = 'array[number]', arrayObject = 'array[object]';
  static const arrayBoolean = 'array[boolean]';
  static const file = 'file', enumType = 'enum';
}

/// `getFieldType`: a schema field's type as shown (`file`, `enum`, `array[<items>]`).
String getFieldType(Json field) {
  final type = jsStr(field['type']) ?? SchemaType.string;
  if (field['schemaType'] == 'file') return SchemaType.file;
  if (field['enum'] case final List e when e.isNotEmpty) return SchemaType.enumType;
  final items = field['items'];
  if (type != SchemaType.array || items is! Map) return type;
  return switch (items['type']) {
    'string' => SchemaType.arrayString,
    'number' => SchemaType.arrayNumber,
    'boolean' => SchemaType.arrayBoolean,
    'object' => SchemaType.arrayObject,
    _ => 'undefined',
  };
}

/// `getHasChildren`.
bool getHasChildren(Json schema) {
  final type = schema['type'];
  if (type == SchemaType.object) return jsKeyCount(schema['properties']) > 0;
  if (type == SchemaType.array) {
    final items = jsMap(schema['items']);
    return items['type'] == SchemaType.object && jsKeyCount(items['properties']) > 0;
  }
  return false;
}

/// `inferType`: booleans become strings, as in Dify.
String _inferType(Object? v) => switch (v) {
  List() => SchemaType.array,
  bool() => SchemaType.string,
  num() => SchemaType.number,
  String() => SchemaType.string,
  Map() => SchemaType.object,
  _ => SchemaType.string,
};

/// `jsonToSchema`: the schema of a sample value (every object key required, `additionalProperties: false`; an
/// array's items from its first element).
Json jsonToSchema(Object? json) {
  final schema = <String, Object?>{'type': _inferType(json)};
  if (schema['type'] == SchemaType.object) {
    final props = <String, Object?>{};
    final required = <String>[];
    schema['properties'] = props;
    schema['required'] = required;
    schema['additionalProperties'] = false;
    for (final e in jsMap(json).entries) {
      props[e.key] = jsonToSchema(e.value);
      required.add(e.key);
    }
  } else if (schema['type'] == SchemaType.array) {
    final list = json! as List;
    schema['items'] = jsonToSchema(list.isEmpty ? null : list.first);
  }
  return schema;
}

/// `checkJsonDepth`.
int checkJsonDepth(Object? json) {
  if (json is List) {
    final first = json.isEmpty ? null : json.first;
    return first is Map ? checkJsonDepth(first) : 0;
  }
  if (json is Map) {
    if (json.isEmpty) return 1;
    return json.values.map(checkJsonDepth).reduce((a, b) => a > b ? a : b) + 1;
  }
  return 0;
}

/// `checkJsonSchemaDepth`.
int checkJsonSchemaDepth(Object? schema) {
  if (schema is! Map) return 0;
  final props = schema['properties'];
  if (schema['type'] == SchemaType.object && props is Map) {
    if (props.isEmpty) return 1;
    return props.values.map(checkJsonSchemaDepth).reduce((a, b) => a > b ? a : b) + 1;
  }
  final items = schema['items'];
  if (schema['type'] == SchemaType.array && items is Map && items['type'] == SchemaType.object) {
    return checkJsonSchemaDepth(items) + 1;
  }
  return 0;
}

/// `JSON_SCHEMA_MAX_DEPTH` (config).
const jsonSchemaMaxDepth = 10;

/// `preValidateSchema` (zod `schemaRootObject`): null when [schema] is an object schema root (`type: 'object'`,
/// `properties` a record, `required` an array of strings, `additionalProperties` a boolean if present), else the
/// issue.
String? preValidateSchema(Object? schema) {
  if (schema is! Map) return 'Expected object, received ${_jsTypeName(schema)}';
  if (schema['type'] != 'object') return 'Invalid literal value, expected "object" at "type"';
  if (schema['properties'] is! Map) {
    return 'Expected object, received ${_jsTypeName(schema['properties'])} at "properties"';
  }
  final req = schema['required'];
  if (req is! List) return 'Expected array, received ${_jsTypeName(req)} at "required"';
  if (req.any((r) => r is! String)) return 'Expected string at "required"';
  final ap = schema['additionalProperties'];
  if (schema.containsKey('additionalProperties') && ap != null && ap is! bool) {
    return 'Expected boolean, received ${_jsTypeName(ap)} at "additionalProperties"';
  }
  return null;
}

String _jsTypeName(Object? v) => switch (v) {
  null => 'undefined',
  List() => 'array',
  Map() => 'object',
  String() => 'string',
  num() => 'number',
  bool() => 'boolean',
  _ => 'unknown',
};

const _simpleTypes = {'array', 'boolean', 'integer', 'null', 'number', 'object', 'string'};

/// Draft-07 meta-schema checks of the keywords structured outputs use (`type`, `properties`, `required`, `items`,
/// `enum`, `additionalProperties`, `description`, `title`), as jsonschema's `Error: <stack>` lines.
List<String> _draft07Errors(Object? schema, String path) {
  if (schema is bool) return const [];
  if (schema is! Map) return ['$path is not of a type(s) object,boolean'];
  final errors = <String>[];
  final type = schema['type'];
  if (type != null) {
    final ok = type is String
        ? _simpleTypes.contains(type)
        : type is List && type.isNotEmpty && type.every((t) => t is String && _simpleTypes.contains(t));
    if (!ok) errors.add('$path.type is not any of [subschema 0],[subschema 1]');
  }
  for (final k in const ['description', 'title']) {
    if (schema.containsKey(k) && schema[k] is! String) errors.add('$path.$k is not of a type(s) string');
  }
  final props = schema['properties'];
  if (props != null) {
    if (props is! Map) {
      errors.add('$path.properties is not of a type(s) object');
    } else {
      for (final e in props.entries) {
        errors.addAll(_draft07Errors(e.value, '$path.properties.${e.key}'));
      }
    }
  }
  final req = schema['required'];
  if (req != null) {
    if (req is! List) {
      errors.add('$path.required is not of a type(s) array');
    } else {
      for (final (i, r) in req.indexed) {
        if (r is! String) errors.add('$path.required[$i] is not of a type(s) string');
      }
      if (req.toSet().length != req.length) errors.add('$path.required contains duplicate item');
    }
  }
  final items = schema['items'];
  if (items != null) {
    if (items is List) {
      for (final (i, s) in items.indexed) {
        errors.addAll(_draft07Errors(s, '$path.items[$i]'));
      }
    } else {
      errors.addAll(_draft07Errors(items, '$path.items'));
    }
  }
  if (schema.containsKey('enum') && schema['enum'] is! List) errors.add('$path.enum is not of a type(s) array');
  final ap = schema['additionalProperties'];
  if (ap != null) errors.addAll(_draft07Errors(ap, '$path.additionalProperties'));
  return errors;
}

/// `forbidBooleanProperties` (utils/validators.ts).
List<String> forbidBooleanProperties(Object? schema, [List<String> path = const []]) {
  final errors = <String>[];
  final props = schema is Map ? schema['properties'] : null;
  if (props is Map) {
    for (final e in props.entries) {
      final at = [...path, '${e.key}'];
      if (e.value is bool) {
        errors.add("Error: Property '${at.join('.')}' must not be a boolean schema");
      } else if (e.value is Map) {
        errors.addAll(forbidBooleanProperties(e.value, at));
      }
    }
  }
  return errors;
}

/// `validateSchemaAgainstDraft7` with `getValidationErrorMessage`'s formatting applied per error.
List<String> validateSchemaAgainstDraft7(Object? schema) => [
  for (final e in _draft07Errors(schema, 'instance')) 'Error: $e\n',
  ...forbidBooleanProperties(schema),
];

/// `getValidationErrorMessage`.
String getValidationErrorMessage(List<String> errors) => errors.join();

// ---- utils/completion-params.ts ----------------------------------------------------------------------------------

/// `mergeValidCompletionParams`: [oldParams] that [rules] allow (`stop` is kept in advanced mode), and why the others
/// were removed.
({Json params, Map<String, String> removedDetails}) mergeValidCompletionParams(
  Json? oldParams,
  List<ModelParameterRule> rules, {
  bool isAdvancedMode = false,
}) {
  if (oldParams == null || oldParams.isEmpty) return (params: {}, removedDetails: {});
  final ruleMap = {for (final r in rules) r.name: r};
  final next = <String, Object?>{};
  final removed = <String, String>{};
  String fmt(num? n, bool min) => n == null ? (min ? '-Infinity' : 'Infinity') : jsKey(n);
  for (final MapEntry(:key, :value) in oldParams.entries) {
    if (key == 'stop' && isAdvancedMode) {
      next[key] = value;
      continue;
    }
    final rule = ruleMap[key];
    if (rule == null) {
      removed[key] = 'unsupported';
      continue;
    }
    switch (rule.type) {
      case 'int' || 'float':
        if (value is! num) {
          removed[key] = 'invalid type';
          continue;
        }
        if ((rule.min != null && value < rule.min!) || (rule.max != null && value > rule.max!)) {
          removed[key] = 'out of range (${fmt(rule.min, true)}-${fmt(rule.max, false)})';
          continue;
        }
        next[key] = value;
      case 'boolean':
        if (value is! bool) {
          removed[key] = 'invalid type';
          continue;
        }
        next[key] = value;
      case 'string' || 'text':
        if (value is! String) {
          removed[key] = 'invalid type';
          continue;
        }
        if (rule.options.isNotEmpty && !rule.options.contains(value)) {
          removed[key] = 'unsupported option';
          continue;
        }
        next[key] = value;
      default:
        removed[key] = 'unsupported rule type: ${rule.type}';
    }
  }
  return (params: next, removedDetails: removed);
}

// ---- hooks/use-llm-input-manager.ts ------------------------------------------------------------------------------

/// useLLMInputManager: [setInputs] injects [defaultRolePrefix] into a memory that has none; the completion default
/// prompt sets that prefix; [hydrate] (the hook's effect) fills a missing prompt from the defaults.
class LlmInputManager {
  LlmInputManager({required this.inputs, required this.doSetInputs, this.defaultConfig, required this.isChatModel});

  /// `inputRef.current`.
  Json inputs;
  void Function(Json inputs) doSetInputs;
  Json? defaultConfig;
  bool isChatModel;
  Json defaultRolePrefix = const {'user': '', 'assistant': ''};

  void setInputs(Json next) {
    final memory = next['memory'];
    if (memory is Map && memory['role_prefix'] == null) {
      final withPrefix = jsonClone(next);
      (withPrefix['memory']! as Map)['role_prefix'] = {...defaultRolePrefix};
      doSetInputs(withPrefix);
      inputs = withPrefix;
      return;
    }
    doSetInputs(next);
    inputs = next;
  }

  /// appendDefaultPromptConfig: [draft]'s prompt from [config]'s templates for a chat ([isChat], by default
  /// [isChatModel]) or completion model.
  void appendDefaultPromptConfig(Json draft, Json? config, [bool? isChat]) {
    final templates = config?['prompt_templates'];
    if (templates is! Map) return;
    if (isChat ?? isChatModel) {
      draft['prompt_template'] = jsonClone(jsGet(jsGet(templates, 'chat_model'), 'prompts'));
      return;
    }
    final completion = jsGet(templates, 'completion_model');
    draft['prompt_template'] = jsonClone(jsGet(completion, 'prompt'));
    final role = jsGet(completion, 'conversation_histories_role');
    defaultRolePrefix = {'user': jsGet(role, 'user_prefix'), 'assistant': jsGet(role, 'assistant_prefix')};
  }

  /// The effect: with defaults loaded and no prompt yet, the default prompt.
  void hydrate() {
    final config = defaultConfig;
    if (config == null || config.isEmpty || inputs['prompt_template'] != null) return;
    final next = jsonClone(inputs);
    appendDefaultPromptConfig(next, config);
    setInputs(next);
  }
}

// ---- hooks/use-llm-prompt-config.ts ------------------------------------------------------------------------------

/// The block status of the prompt (`hasSetBlockStatus`).
typedef LlmBlockStatus = ({bool history, bool query, bool context});

/// useLLMPromptConfig over `inputs` (read through [inputsOf], Dify's inputRef) and [setInputs].
class LlmPromptConfig {
  LlmPromptConfig({
    required this.inputsOf,
    required this.setInputs,
    required this.isChatMode,
    required this.isChatModel,
  });

  final Json Function() inputsOf;
  final void Function(Json inputs) setInputs;
  final bool isChatMode, isChatModel;

  Json get _inputs => inputsOf();

  List<Object?> get _prompts => jsList(_inputs['prompt_template']);
  Object? get _prompt => _inputs['prompt_template'];

  String? _text(Object? item) => jsStr(jsGet(item, 'text'));

  LlmBlockStatus get hasSetBlockStatus {
    final hasSetContext = isChatModel
        ? _prompts.any((p) => checkHasContextBlock(_text(p)))
        : checkHasContextBlock(_text(_prompt));
    if (!isChatMode) return (history: false, query: false, context: hasSetContext);
    if (isChatModel) {
      return (history: false, query: _prompts.any((p) => checkHasQueryBlock(_text(p))), context: hasSetContext);
    }
    return (
      history: checkHasHistoryBlock(_text(_prompt)),
      query: checkHasQueryBlock(_text(_prompt)),
      context: hasSetContext,
    );
  }

  bool get shouldShowContextTip => !hasSetBlockStatus.context && jsGet(_inputs['context'], 'enabled') == true;

  bool get isShowVars => isChatModel
      ? _prompts.any((p) => jsGet(p, 'edition_type') == 'jinja2')
      : jsGet(_prompt, 'edition_type') == 'jinja2';

  Json _ensurePromptConfig(Json draft) {
    var config = draft['prompt_config'];
    if (config is! Map) draft['prompt_config'] = config = <String, Object?>{'jinja2_variables': <Object?>[]};
    if (config['jinja2_variables'] is! List) config['jinja2_variables'] = <Object?>[];
    return config.cast<String, Object?>();
  }

  void _produce(void Function(Json draft) f) {
    final draft = jsonClone(_inputs);
    f(draft);
    setInputs(draft);
  }

  void handleAddEmptyVariable() => _produce(
    (d) => (_ensurePromptConfig(d)['jinja2_variables']! as List).add({'variable': '', 'value_selector': <String>[]}),
  );

  void handleAddVariable(Json payload) =>
      _produce((d) => (_ensurePromptConfig(d)['jinja2_variables']! as List).add(payload));

  void handleVarListChange(List<Json> list) => _produce((d) => _ensurePromptConfig(d)['jinja2_variables'] = list);

  void handleVarNameChange(String oldName, String newName) => _produce((d) {
    String rename(Object? s) => '${s ?? ''}'.replaceAll('{{ $oldName }}', '{{ $newName }}');
    if (isChatModel) {
      for (final p in jsList(d['prompt_template'])) {
        if (p is Map && p['edition_type'] == 'jinja2') p['jinja2_text'] = rename(p['jinja2_text']);
      }
      return;
    }
    final p = d['prompt_template'];
    if (p is! Map || p['edition_type'] != 'jinja2') return;
    p['jinja2_text'] = rename(p['jinja2_text']);
  });

  void handleContextVarChange(List<String>? selector) => _produce((d) {
    final context = d['context'] is Map ? d['context']! as Map : (d['context'] = <String, Object?>{}) as Map;
    context['variable_selector'] = selector ?? <String>[];
    context['enabled'] = selector != null && selector.isNotEmpty;
  });

  void handlePromptChange(Object? prompt) => _produce((d) => d['prompt_template'] = prompt);

  void handleMemoryChange(Json? memory) => _produce((d) => d['memory'] = memory);

  void handleSyeQueryChange(String query) => _produce((d) {
    final memory = d['memory'];
    if (memory is! Map) {
      d['memory'] = {
        'window': {'enabled': false, 'size': 10},
        'query_prompt_template': query,
      };
      return;
    }
    memory['query_prompt_template'] = query;
  });
}

// ---- hooks/use-llm-structured-output-config.ts -------------------------------------------------------------------

/// `isModelSupportStructuredOutput`: whether the text generation [modelList] gives [provider] / [name] the
/// structured-output feature; null when the model is not listed (Dify's `undefined`).
bool? isModelSupportStructuredOutput(List<ProviderWithModels> modelList, String provider, String name) {
  final p = modelList.where((m) => m.provider == provider).firstOrNull;
  final m = p?.models.where((m) => m.model == name).firstOrNull;
  if (m == null) return null;
  return m.features?.contains(ModelFeatureEnum.structuredOutput);
}

/// useLLMStructuredOutputConfig's state and handlers: the output section's collapse (closed at first, opened by
/// enabling structured output); toggling or saving the schema drops the node's inspected variables.
class LlmStructuredOutputConfig {
  LlmStructuredOutputConfig({
    required this.id,
    required this.inputsOf,
    required this.setInputs,
    required this.deleteNodeInspectorVars,
  });

  final String id;
  Json Function() inputsOf;
  void Function(Json inputs) setInputs;
  void Function(String nodeId) deleteNodeInspectorVars;
  bool structuredOutputCollapsed = true;

  void handleStructureOutputEnableChange(bool enabled) {
    setInputs({...jsonClone(inputsOf()), 'structured_output_enabled': enabled});
    if (enabled) structuredOutputCollapsed = false;
    deleteNodeInspectorVars(id);
  }

  void handleStructureOutputChange(Json output) {
    setInputs({...jsonClone(inputsOf()), 'structured_output': output});
    deleteNodeInspectorVars(id);
  }

  void handleReasoningFormatChange(String format) => setInputs({...jsonClone(inputsOf()), 'reasoning_format': format});
}

// ---- use-config.ts -----------------------------------------------------------------------------------------------

/// The model the panel shows (`model` of use-config): the node's, or the resolved environment model; an unresolved
/// environment reference shows no provider or name.
Json effectiveLlmModel(Json inputs, List<Object?> environmentVariables) {
  final resolved = resolveLLMNodeModel(
    inputs['model'],
    inputs['model_selector'],
    List<Object?>.of(environmentVariables),
  );
  return resolved ?? {...jsMap(inputs['model']), 'provider': '', 'name': ''};
}

/// useConfig's model handlers over an [LlmInputManager] (the shared inputRef / setInputs).
class LlmModelConfig {
  LlmModelConfig({required this.manager, required this.environmentVariables, this.onModelChanged});

  final LlmInputManager manager;
  final List<Object?> environmentVariables;

  /// `setModelChanged(true)`: the vision follow-up runs after the change lands.
  final void Function()? onModelChanged;

  /// applyModelIdentity.
  void applyModelIdentity(
    ({String provider, String modelId, String? mode}) model, {
    List<String>? modelSelector,
    Json? completionParams,
  }) {
    final current = manager.inputs;
    final next = jsonClone(current);
    final m = next['model'] is Map ? (next['model']! as Map) : (next['model'] = <String, Object?>{}) as Map;
    m['provider'] = model.provider;
    m['name'] = model.modelId;
    m['mode'] = model.mode;
    if (completionParams != null) m['completion_params'] = completionParams;
    next['model_selector'] = modelSelector;
    final isModeChange = model.mode != jsGet(current['model'], 'mode');
    final config = manager.defaultConfig;
    if (isModeChange && config != null && config.isNotEmpty) {
      manager.appendDefaultPromptConfig(next, config, model.mode == 'chat');
    }
    manager.setInputs(next);
    onModelChanged?.call();
  }

  /// handleModelChanged.
  void handleModelChanged(({String provider, String modelId, String? mode}) model, [Json? completionParams]) =>
      applyModelIdentity(model, completionParams: completionParams);

  /// handleModelSourceChange.
  void handleModelSourceChange(bool useEnvironmentVariable) {
    final current = manager.inputs;
    final next = jsonClone(current);
    if (useEnvironmentVariable) {
      next['model_selector'] = <String>[];
    } else {
      final model = resolveLLMNodeModel(
        current['model'],
        current['model_selector'],
        List<Object?>.of(environmentVariables),
      );
      if (model != null) {
        final m = next['model'] is Map ? (next['model']! as Map) : (next['model'] = <String, Object?>{}) as Map;
        m['provider'] = model['provider'];
        m['name'] = model['name'];
        m['mode'] = model['mode'];
        m['completion_params'] = jsonClone(model['completion_params']);
      }
      next['model_selector'] = null;
    }
    manager.setInputs(next);
  }

  /// handleModelSelectorChange.
  void handleModelSelectorChange(List<String> modelSelector, [Json? completionParams]) {
    final selected = getLLMEnvironmentModel(modelSelector, environmentVariables);
    if (selected == null) {
      manager.setInputs({...jsonClone(manager.inputs), 'model_selector': modelSelector});
      return;
    }
    applyModelIdentity(
      (provider: '${selected['provider']}', modelId: '${selected['name']}', mode: jsStr(selected['mode'])),
      modelSelector: modelSelector,
      completionParams: selected['completion_params'] is Map
          ? jsonClone(jsMap(selected['completion_params']))
          : completionParams,
    );
  }

  /// handleCompletionParamsChange.
  void handleCompletionParamsChange(Json params) {
    final next = jsonClone(manager.inputs);
    final m = next['model'] is Map ? (next['model']! as Map) : (next['model'] = <String, Object?>{}) as Map;
    m['completion_params'] = params;
    manager.setInputs(next);
  }
}
