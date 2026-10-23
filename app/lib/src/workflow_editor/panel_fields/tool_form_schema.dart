/// tools/utils/to-form-schema.ts as the tool, agent, trigger-plugin and data-source panels share it: tool parameters
/// as form schemas and their default values.
library;

import 'dart:convert';

import '../../workflow/dify_json.dart';
import 'node_config.dart' show Json;

/// `toType`: a parameter type as the form names it.
String toFormType(String type) => switch (type) {
  'string' => 'text-input',
  'number' => 'number-input',
  'boolean' => 'checkbox',
  _ => type,
};

/// `toolParametersToFormSchemas`: each parameter with `variable` (its name), the form `type`, the raw `_type`, empty
/// `show_on`s and the `human_description` as `tooltip`.
List<Json> toolParametersToFormSchemas(Object? parameters) => [
  for (final p in jsList(parameters))
    if (p is Map)
      {
        ...p.cast<String, Object?>(),
        'variable': p['name'],
        'type': toFormType(jsStr(p['type']) ?? ''),
        '_type': p['type'],
        'show_on': const <Object?>[],
        'options': p['options'] == null
            ? null
            : [
                for (final o in jsList(p['options']))
                  if (o is Map) {...o.cast<String, Object?>(), 'show_on': const <Object?>[]},
              ],
        'tooltip': p['human_description'],
      },
];

/// JavaScript's `Number.parseFloat(String(x))`: the leading number of the text; null where JavaScript has NaN.
num? parseFloatJs(Object? x) {
  final m = RegExp(r'^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').firstMatch(x == null ? '' : '$x');
  if (m == null) return null;
  final v = double.parse(m[0]!.trim());
  return v == v.truncateToDouble() && v.abs() < 9e15 ? v.toInt() : v;
}

/// `correctInitialData`: [target] (`{type, value}`) corrected for the field [type] given its [defaultValue].
Json correctInitialData(String type, Json target, Object? defaultValue) {
  if (type == 'text-input' || type == 'secret-input') target['type'] = 'mixed';
  if (type == 'boolean') {
    if (defaultValue is String) target['value'] = defaultValue == 'true' || defaultValue == '1';
    if (defaultValue is bool) target['value'] = defaultValue;
    if (defaultValue is num) target['value'] = defaultValue == 1;
  }
  if (type == 'number-input' && defaultValue is String && defaultValue.isNotEmpty) {
    target['value'] = parseFloatJs(defaultValue);
  }
  if (type == 'date' || type == 'date-range') {
    if (defaultValue is String) target['value'] = defaultValue;
    if (defaultValue is Map) target['value'] = jsonEncode(defaultValue);
  }
  if (type == 'app-selector' || type == 'model-selector') target['value'] = defaultValue;
  return target;
}

/// `getConfiguredValue`: [value] with each empty field that has a default set to `{type: constant, value: default}`
/// (newlines escaped, then corrected for the field's type).
Json getConfiguredValue(Json value, List<Json> formSchemas) {
  final next = {...value};
  for (final s in formSchemas) {
    final variable = jsKey(s['variable']);
    final item = value[variable];
    if (s.containsKey('default') && (item == null || item == '')) {
      final d = s['default'];
      next[variable] = correctInitialData(jsStr(s['type']) ?? '', {
        'type': 'constant',
        'value': d is String ? d.replaceAll('\n', r'\n') : d,
      }, d);
    }
  }
  return next;
}

/// `generateFormValue`: the defaults of [schemas] missing from [value] (`{value: {type: constant, value}}`, or
/// `{auto: 1, value: null}` for reasoning parameters).
Json generateFormValue(Json value, List<Json> schemas, {bool isReasoning = false}) {
  final out = <String, Object?>{};
  for (final s in schemas) {
    final name = '${s['variable']}';
    final v = value[name];
    if (s.containsKey('default') && s['default'] != null && (v == null || v == '')) {
      out[name] = isReasoning
          ? {'auto': 1, 'value': null}
          : {
              'value': correctInitialData('${s['type']}', {'type': 'constant', 'value': s['default']}, s['default']),
            };
    }
  }
  return out;
}
