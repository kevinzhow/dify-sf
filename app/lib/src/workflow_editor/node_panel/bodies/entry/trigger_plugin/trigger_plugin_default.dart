/// The plugin trigger's data logic (nodes/trigger-plugin/default.ts, use-config.ts, workflow/utils/trigger.ts) and the
/// plugin form schemas both it and the data source build (tools/utils/to-form-schema.ts), on plain JSON.
library;

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/model_catalog.dart' show renderI18nObject;
import '../../../../header/checklist/node_validators.dart' show ChecklistTranslate;
import '../../../../panel_fields/node_config.dart' show Json;
import '../../../../panel_fields/tool_form_schema.dart';

export '../../../../panel_fields/node_config.dart' show Json;

/// `defaultValue` (default.ts).
const Json triggerPluginDefaultValue = {
  'plugin_id': '',
  'event_name': '',
  'event_parameters': <String, Object?>{},
  'config': <String, Object?>{},
};

/// `metaData` (default.ts): sort 1, isStart.
const triggerPluginHelpLink = 'trigger/plugin-trigger';

Json _map(Object? v) => v is Map ? v.cast<String, Object?>() : <String, Object?>{};

/// An `I18nObject` (`{en_US: …}`) from JSON; a plain string counts for every language.
String i18nTextOf(Object? obj, String language) => switch (obj) {
  final String s => s,
  final Map m => renderI18nObject({
    for (final e in m.entries) '${e.key}': e.value is String ? e.value as String : null,
  }, language),
  _ => '',
};

/// `label[language] || label.en_US` (no other fallback).
String labelOf(Object? obj, String language) {
  if (obj is String) return obj;
  if (obj is! Map) return '';
  final own = obj[language];
  if (own is String && own.isNotEmpty) return own;
  final en = obj['en_US'];
  return en is String ? en : '';
}

// ---- tools/utils/to-form-schema.ts -----------------------------------------------------------------------------

// ---- use-config.ts ---------------------------------------------------------------------------------------------

/// `normalizeEventParameters`: the `{type, value}` entries (`mixed` read as `constant`), dropping empty ones; with
/// [allowScalars] (legacy `config`) strings, numbers and booleans become constants and string lists variables.
Json normalizeEventParameters(Object? params, {bool allowScalars = false}) {
  if (params is! Map) return {};
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in params.entries) {
    if (!jsTruthy(value) && value != 0 && value != false) continue;
    if (value is Map && value.containsKey('type') && value.containsKey('value')) {
      final entry = value.cast<String, Object?>();
      out['$key'] = entry['type'] == 'mixed' ? {...entry, 'type': 'constant'} : {...entry};
      continue;
    }
    if (!allowScalars) continue;
    if (value is String || value is num || value is bool) {
      out['$key'] = {'type': 'constant', 'value': value};
    } else if (value is List && value.every((i) => i is String)) {
      out['$key'] = {'type': 'variable', 'value': value};
    }
  }
  return out;
}

/// `currentProvider`: the provider named `provider_name`, or with id `provider_id`, or of plugin `provider_id`.
Json? findTriggerProvider(List<Object?>? providers, Json data) {
  final id = data['provider_id'];
  for (final p in providers ?? const []) {
    if (p is! Map) continue;
    if (p['name'] == data['provider_name'] || p['id'] == id || (jsTruthy(id) && p['plugin_id'] == id)) {
      return p.cast<String, Object?>();
    }
  }
  return null;
}

/// `currentEvent`: the provider's event named `event_name`.
Json? findTriggerEvent(Json? provider, Object? eventName) {
  for (final e in jsList(provider?['events'])) {
    if (e is Map && e['name'] == eventName) return e.cast<String, Object?>();
  }
  return null;
}

/// `triggerParameterSchema`: the event's form schemas, one per `variable || name` (a later one replaces an earlier
/// one in its place).
List<Json> triggerParameterSchemaOf(Json? event) {
  if (event == null) return const [];
  final byKey = <Object?, Json>{};
  for (final s in toolParametersToFormSchemas(event['parameters'])) {
    byKey[jsTruthy(s['variable']) ? s['variable'] : s['name']] = s;
  }
  return byKey.values.toList();
}

/// `triggerParameterValue`: the stored `event_parameters` (else the legacy `config`) with the defaults filled in.
Json triggerParameterValueOf(Json data, List<Json> schema) {
  if (schema.isEmpty) return {};
  final stored = normalizeEventParameters(data['event_parameters'] ?? <String, Object?>{});
  final base = stored.isNotEmpty
      ? stored
      : normalizeEventParameters(data['config'] ?? <String, Object?>{}, allowScalars: true);
  return normalizeEventParameters(getConfiguredValue(base, schema));
}

/// The mount effect: with a schema, no stored parameters and a derivable value, the data with both
/// `event_parameters` and `config` set to it; null when nothing is to be written.
Json? triggerPluginInitialFill(Json data, List<Json> schema) {
  if (schema.isEmpty) return null;
  if (normalizeEventParameters(data['event_parameters'] ?? <String, Object?>{}).isNotEmpty) return null;
  final value = triggerParameterValueOf(data, schema);
  if (value.isEmpty) return null;
  return {...data, 'event_parameters': value, 'config': value};
}

/// `setTriggerParameterValue`: the data with the sanitized [value] as both `event_parameters` and `config`.
Json setTriggerParameterValue(Json data, Json value) {
  final sanitized = normalizeEventParameters(value);
  return {...data, 'event_parameters': sanitized, 'config': sanitized};
}

/// `hasObjectOutput`: an output property is an object.
bool hasObjectOutputOf(Json outputSchema) =>
    _map(outputSchema['properties']).values.any((p) => p is Map && p['type'] == 'object');

// ---- default.ts checkValid, utils/trigger.ts ---------------------------------------------------------------------

/// `getTriggerCheckParams`: the event's parameters as `{variable, label, required}` (label in [language], else
/// en_US, else the name); not ready while the providers are not loaded (null).
Json getTriggerCheckParams(Json data, List<Object?>? providers, String language) {
  if (providers == null) return {'triggerInputsSchema': const <Object?>[], 'isReadyForCheckValid': false};
  final event = findTriggerEvent(findTriggerProvider(providers, data), data['event_name']);
  return {
    'triggerInputsSchema': [
      for (final p in jsList(event?['parameters']))
        if (p is Map)
          {
            'variable': p['name'],
            'label': () {
              final l = jsGet(p['label'], language);
              if (jsTruthy(l)) return l;
              final en = jsGet(p['label'], 'en_US');
              return jsTruthy(en) ? en : p['name'];
            }(),
            'required': p['required'],
          },
    ],
    'isReadyForCheckValid': true,
  };
}

/// `checkValid` (default.ts): a subscription, then (once the providers are loaded) each required event parameter.
String checkValidTriggerPlugin(Json data, ChecklistTranslate t, Json? moreData) {
  var error = '';
  if (!jsTruthy(data['subscription_id'])) error = t('workflow', 'nodes.triggerPlugin.subscriptionRequired');
  final schema = jsList(moreData?['triggerInputsSchema']);
  // `{ isReadyForCheckValid = true } = moreDataForCheckValid`: only a missing key takes the default.
  final ready =
      moreData == null || !moreData.containsKey('isReadyForCheckValid') || jsTruthy(moreData['isReadyForCheckValid']);
  if (error.isNotEmpty || !ready) return error;
  String required(Object? field) => t('workflow', 'errorMsg.fieldRequired', {'field': jsGet(field, 'label')});
  for (final field in schema) {
    if (!jsTruthy(jsGet(field, 'required'))) continue;
    final variable = '${jsGet(field, 'variable')}';
    final raw = jsGet(data['event_parameters'], variable) ?? jsGet(data['config'], variable);
    if (!jsTruthy(raw)) return required(field);
    final (type, value) = raw is Map && raw.containsKey('type') ? (raw['type'], raw['value']) : ('constant', raw);
    final empty = type == 'variable'
        ? !jsTruthy(value) || (value is List && value.isEmpty)
        : value == null || value == '' || (value is List && value.isEmpty);
    if (empty) return required(field);
  }
  return error;
}
