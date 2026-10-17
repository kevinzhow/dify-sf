/// The classic Agent node's logic, ported as pure Dart from Dify 1.17.1: nodes/agent/use-config.ts
/// (`useStrategyInfo`, the form data, `onFormChange`, the output schema, the legacy tool value migration),
/// nodes/agent/panel.tsx (`strategyParamToCredientialForm`), _base/components/agent-strategy-selector.tsx
/// (`formatStrategy`), tools/utils/to-form-schema.ts (`toType`, `toolParametersToFormSchemas`, `generateFormValue`,
/// `generateAgentToolValue`), plugin-detail-panel/tool-selector/hooks/use-tool-selector.ts (`getToolValue`) and
/// utils/plugin-version-feature.ts (`isSupportMCP`). Everything works on Dify's plain JSON.
library;

import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/node_config.dart' show Json;
import 'llm_config.dart' show jsonClone;
import 'panel_edit.dart' show jsMap;

/// `FormTypeEnum` values the agent's strategy forms use.
abstract final class AgentFormType {
  static const textInput = 'text-input', textNumber = 'number-input', secretInput = 'secret-input';
  static const select = 'select', radio = 'radio', checkbox = 'checkbox', boolean = 'boolean';
  static const files = 'files', file = 'file';
  static const modelSelector = 'model-selector', toolSelector = 'tool-selector';
  static const multiToolSelector = 'array[tools]', appSelector = 'app-selector', any = 'any';
  static const dynamicSelect = 'dynamic-select', date = 'date', dateRange = 'date-range';
}

/// `AgentFeature.HISTORY_MESSAGES`.
const agentFeatureHistoryMessages = 'history-messages';

/// The strategy a node uses (agent-strategy.tsx `Strategy`).
typedef AgentStrategyRef = ({
  String providerName,
  String strategyName,
  String label,
  Json outputSchema,
  String pluginUniqueIdentifier,
  Json? meta,
});

/// The node's strategy, if it has one (`inputs.agent_strategy_name` set).
AgentStrategyRef? agentStrategyOf(Json inputs) {
  final name = jsStr(inputs['agent_strategy_name']);
  if (name == null || name.isEmpty) return null;
  return (
    providerName: jsStr(inputs['agent_strategy_provider_name']) ?? '',
    strategyName: name,
    label: jsStr(inputs['agent_strategy_label']) ?? '',
    outputSchema: jsMap(inputs['output_schema']),
    pluginUniqueIdentifier: jsStr(inputs['plugin_unique_identifier']) ?? '',
    meta: inputs['meta'] is Map ? jsMap(inputs['meta']) : null,
  );
}

/// The panel's onStrategyChange: the node data with [s] as its strategy (old parameters stay, hidden).
Json withAgentStrategy(Json inputs, AgentStrategyRef s) => {
  ...inputs,
  'agent_strategy_provider_name': s.providerName,
  'agent_strategy_name': s.strategyName,
  'agent_strategy_label': s.label,
  'output_schema': s.outputSchema,
  'plugin_unique_identifier': s.pluginUniqueIdentifier,
  'meta': s.meta,
};

// ---- tools/utils/to-form-schema.ts -------------------------------------------------------------------------------

/// `toType`.
String toFormType(String type) => switch (type) {
  'string' => AgentFormType.textInput,
  'number' => AgentFormType.textNumber,
  'boolean' => AgentFormType.checkbox,
  _ => type,
};

/// `strategyParamToCredientialForm` (agent/panel.tsx): a strategy parameter as a form schema.
Json strategyParamToCredentialForm(Json param) => {
  ...param,
  'variable': param['name'],
  'show_on': <Object?>[],
  'type': toFormType(jsStr(param['type']) ?? ''),
  'tooltip': param['help'],
};

/// `toolParametersToFormSchemas`.
List<Json> toolParametersToFormSchemas(Object? parameters) => [
  for (final p in jsList(parameters))
    if (p is Map)
      {
        ...jsMap(p),
        'variable': p['name'],
        'type': toFormType(jsStr(p['type']) ?? ''),
        '_type': p['type'],
        'show_on': <Object?>[],
        if (p['options'] is List)
          'options': [
            for (final o in jsList(p['options'])) {...jsMap(o), 'show_on': <Object?>[]},
          ],
        'tooltip': p['human_description'],
      },
];

/// `correctInitialData`.
Json _correctInitialData(String type, Json target, Object? defaultValue) {
  if (type == 'text-input' || type == 'secret-input') target['type'] = 'mixed';
  if (type == 'boolean') {
    if (defaultValue is String) target['value'] = defaultValue == 'true' || defaultValue == '1';
    if (defaultValue is bool) target['value'] = defaultValue;
    if (defaultValue is num) target['value'] = defaultValue == 1;
  }
  if (type == 'number-input' && defaultValue is String && defaultValue.isNotEmpty) {
    target['value'] = double.tryParse(defaultValue) ?? double.nan;
  }
  if (type == AgentFormType.date || type == AgentFormType.dateRange) {
    if (defaultValue is String) target['value'] = defaultValue;
    if (defaultValue is Map) target['value'] = defaultValue.toString();
  }
  if (type == 'app-selector' || type == 'model-selector') target['value'] = defaultValue;
  return target;
}

bool _emptyish(Object? v) => v == null || v == '';

/// `generateFormValue`: the defaults of [schemas] missing from [value] (`{value: {type: constant, value}}`, or
/// `{auto: 1, value: null}` for reasoning parameters).
Json generateFormValue(Json value, List<Json> schemas, {bool isReasoning = false}) {
  final out = <String, Object?>{};
  for (final s in schemas) {
    final name = '${s['variable']}';
    if (s.containsKey('default') && s['default'] != null && _emptyish(value[name])) {
      out[name] = isReasoning
          ? {'auto': 1, 'value': null}
          : {
              'value': _correctInitialData('${s['type']}', {'type': 'constant', 'value': s['default']}, s['default']),
            };
    }
  }
  return out;
}

/// `getVarKindType` (to-form-schema.ts).
String? _varKindType(String type) {
  if (type == AgentFormType.file || type == AgentFormType.files) return 'variable';
  if (const {
    AgentFormType.select,
    AgentFormType.checkbox,
    AgentFormType.textNumber,
    AgentFormType.date,
    AgentFormType.dateRange,
  }.contains(type)) {
    return 'constant';
  }
  if (type == AgentFormType.textInput || type == AgentFormType.secretInput) return 'mixed';
  return null;
}

/// `generateAgentToolValue`: settings as `{value: {type: constant, value}}` (corrected per type); reasoning parameters
/// as `{auto: 1, value: null}` or `{auto: 0, value}`.
Json generateAgentToolValue(Json value, List<Json> schemas, {bool isReasoning = false}) {
  final out = <String, Object?>{};
  for (final s in schemas) {
    final name = '${s['variable']}';
    final item = jsMap(value[name]);
    if (!isReasoning) {
      out[name] = {
        'value': _correctInitialData('${s['type']}', {'type': 'constant', 'value': item['value']}, item['value']),
      };
    } else if (item['auto'] == 1) {
      out[name] = {'auto': 1, 'value': null};
    } else {
      out[name] = {
        'auto': 0,
        'value': item['value'] ?? {'type': _varKindType('${s['type']}'), 'value': null},
      };
    }
  }
  return out;
}

// ---- use-config.ts -----------------------------------------------------------------------------------------------

/// The strategy plugin's state (useStrategyInfo's `strategyStatus`).
typedef AgentStrategyStatus = ({String source, bool installed, bool isExistInPlugin});

/// The strategy named [strategyName] in a provider detail (`declaration.strategies`).
Json? findStrategy(Json? providerDetail, String? strategyName) {
  for (final s in jsList(jsGet(jsGet(providerDetail, 'declaration'), 'strategies'))) {
    if (jsGet(jsGet(s, 'identity'), 'name') == strategyName) return jsMap(s);
  }
  return null;
}

/// useStrategyInfo's status: undefined while loading; the plugin installed unless the detail failed; `marketplace`
/// when the marketplace knows the plugin.
AgentStrategyStatus? strategyStatusOf({
  required bool loading,
  required bool isError,
  required Json? strategy,
  bool isInMarketplace = false,
}) {
  if (loading) return null;
  return (source: isInMarketplace ? 'marketplace' : 'external', installed: !isError, isExistInPlugin: strategy != null);
}

/// `formData`: the node's agent parameter values of the strategy's parameters.
Json agentFormData(Json inputs, Json? strategy) {
  final names = {for (final p in jsList(strategy?['parameters'])) jsGet(p, 'name')};
  return {
    for (final e in jsMap(inputs['agent_parameters']).entries)
      if (names.contains(e.key)) e.key: jsGet(e.value, 'value'),
  };
}

/// `onFormChange`: [value] as `agent_parameters` (`{type: variable}` for `any` parameters, else constant).
Json agentParametersOf(Json value, Json? strategy) {
  bool isVariable(String name) =>
      jsList(strategy?['parameters']).any((p) => jsGet(p, 'name') == name && jsGet(p, 'type') == AgentFormType.any);
  return {
    for (final e in value.entries) e.key: {'type': isVariable(e.key) ? 'variable' : 'constant', 'value': e.value},
  };
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// `outputSchema`: the strategy's extra outputs (`String`, `Array[Number]`, `Unknown` …).
List<({String name, String type, String description})> agentOutputSchema(Json inputs) {
  final props = jsGet(inputs['output_schema'], 'properties');
  if (props is! Map) return const [];
  return [
    for (final e in props.entries)
      () {
        final o = jsMap(e.value);
        final type = jsStr(o['type']);
        final itemType = jsStr(jsGet(o['items'], 'type'));
        return (
          name: '${e.key}',
          type: type == 'array'
              ? 'Array[${itemType != null && itemType.isNotEmpty ? _capitalize(itemType) : 'Unknown'}]'
              : (type != null && type.isNotEmpty ? _capitalize(type) : 'Unknown'),
          description: jsStr(o['description']) ?? '',
        );
      }(),
  ];
}

/// `formattingToolData`: a legacy tool value's settings and parameters in the `{value: {type, value}}` /
/// `{auto, value}` forms, from its `schemas`.
Json formattingToolData(Json data) {
  final schemas = jsList(data['schemas']);
  final settings = generateAgentToolValue(
    jsMap(data['settings']),
    toolParametersToFormSchemas([
      for (final s in schemas)
        if (jsGet(s, 'form') != 'llm') s,
    ]),
  );
  final params = generateAgentToolValue(
    jsMap(data['parameters']),
    toolParametersToFormSchemas([
      for (final s in schemas)
        if (jsGet(s, 'form') == 'llm') s,
    ]),
    isReasoning: true,
  );
  return {...jsonClone(data), 'settings': settings, 'parameters': params};
}

/// `formattingLegacyData`: data without a `version` / `tool_node_version` gets its tool values migrated and
/// `tool_node_version: '2'`; other data is returned as is.
Json formattingLegacyData(Json inputs, Json? strategy) {
  if (jsTruthy(inputs['version']) || jsTruthy(inputs['tool_node_version'])) return inputs;
  final next = jsonClone(inputs);
  final params = next['agent_parameters'];
  if (params is Map) {
    for (final key in params.keys.toList()) {
      final schema = jsList(strategy?['parameters']).where((s) => jsGet(s, 'name') == key).firstOrNull;
      final entry = params[key];
      if (entry is! Map) continue;
      final type = jsGet(schema, 'type');
      if (type == AgentFormType.toolSelector) entry['value'] = formattingToolData(jsMap(entry['value']));
      if (type == AgentFormType.multiToolSelector) {
        entry['value'] = [for (final t in jsList(entry['value'])) formattingToolData(jsMap(t))];
      }
    }
  }
  next['tool_node_version'] = '2';
  return next;
}

// ---- agent-strategy-selector.tsx ---------------------------------------------------------------------------------

/// A strategy offered by the selector: the provider (`StrategyPluginDetail`) and the strategy.
typedef StrategyChoice = ({Json provider, Json strategy});

/// `formatStrategy` as the list the selector shows: each provider's identity name, label, icon, and its strategies.
typedef StrategyProviderRow = ({String id, String name, Object? label, Object? icon, Json? meta, List<Json> tools});

List<StrategyProviderRow> formatStrategies(List<Json> providers) => [
  for (final p in providers)
    (
      id: jsStr(p['plugin_unique_identifier']) ?? '',
      name: jsStr(jsGet(jsGet(p['declaration'], 'identity'), 'name')) ?? '',
      label: jsGet(jsGet(p['declaration'], 'identity'), 'label'),
      icon: jsGet(jsGet(p['declaration'], 'identity'), 'icon'),
      meta: p['meta'] is Map ? jsMap(p['meta']) : null,
      tools: [for (final s in jsList(jsGet(p['declaration'], 'strategies'))) jsMap(s)],
    ),
];

/// The selector's onSelect: the strategy reference for a provider row and one of its strategies.
AgentStrategyRef strategyRefOf(StrategyProviderRow provider, Json strategy, String language) {
  final label = jsGet(jsGet(strategy, 'identity'), 'label');
  return (
    providerName: provider.name,
    strategyName: jsStr(jsGet(jsGet(strategy, 'identity'), 'name')) ?? '',
    label: label is Map ? (jsStr(label[language]) ?? jsStr(label['en_US']) ?? '') : '${label ?? ''}',
    outputSchema: strategy['output_schema'] is Map ? jsMap(strategy['output_schema']) : const {},
    pluginUniqueIdentifier: provider.id,
    meta: provider.meta,
  );
}

// ---- tool values (use-tool-selector.ts, multiple-tool-selector) --------------------------------------------------

/// `getToolValue`: the agent's value for a tool picked from [provider] (ToolWithProvider JSON).
Json toolValueOf(Json provider, Json tool, String language) {
  final schemas = jsList(tool['parameters']);
  final label = tool['label'], description = tool['description'], providerLabel = provider['label'];
  String text(Object? v) => v is Map ? (jsStr(v[language]) ?? jsStr(v['en_US']) ?? '') : '${v ?? ''}';
  return {
    'provider_name': provider['id'],
    'provider_show_name': text(providerLabel).isEmpty ? provider['name'] : text(providerLabel),
    'plugin_id': provider['plugin_id'],
    'tool_name': tool['name'],
    'tool_label': text(label),
    'tool_description': text(description),
    'settings': generateFormValue(
      const {},
      toolParametersToFormSchemas([
        for (final s in schemas)
          if (jsGet(s, 'form') != 'llm') s,
      ]),
    ),
    'parameters': generateFormValue(
      const {},
      toolParametersToFormSchemas([
        for (final s in schemas)
          if (jsGet(s, 'form') == 'llm') s,
      ]),
      isReasoning: true,
    ),
    'enabled': provider['is_team_authorization'] == true,
    'extra': {'description': text(description)},
    'type': provider['type'],
  };
}

/// Multiple tool selector de-duplication: [value] then [added], each `provider_name` + `tool_name` once.
List<Json> addToolValues(List<Json> value, List<Json> added) {
  final out = <Json>[];
  for (final t in [...value, ...added]) {
    if (!out.any((o) => o['provider_name'] == t['provider_name'] && o['tool_name'] == t['tool_name'])) out.add(t);
  }
  return out;
}

/// `isSupportMCP` (utils/plugin-version-feature.ts): strategy plugin version 0.0.2 or later.
bool isSupportMCP(String? version) {
  if (version == null || version.isEmpty) return false;
  List<int> parts(String v) => [for (final p in v.split('.')) int.tryParse(p.split(RegExp(r'[^0-9]')).first) ?? 0];
  final a = parts(version), b = const [0, 0, 2];
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    if (x != b[i]) return x > b[i];
  }
  return true;
}
