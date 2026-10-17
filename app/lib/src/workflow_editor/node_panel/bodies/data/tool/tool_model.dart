/// The tool node's data logic, ported from Dify 1.17.1: tools/utils/to-form-schema.ts (`toType`,
/// `toolParametersToFormSchemas`, `getConfiguredValue`), nodes/_base/components/form-input-item.helpers.ts,
/// nodes/tool/{default.ts (checkValid, getOutputVars), auth.ts, output-schema-utils.ts, hooks/use-config.ts,
/// hooks/use-current-tool-collection.ts, hooks/use-single-run-form-params.ts, components/tool-date-range-value.ts},
/// workflow/utils/tool.ts (`getToolCheckParams`, `wrapStructuredVarItem`), utils `canFindTool` and
/// variable/use-match-schema-type.ts (`getMatchedSchemaType`).
///
/// Everything works on plain JSON as Dify has it (the node's `data`, `ToolWithProvider` collections, form schemas).
library;

import 'dart:convert';

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/match_schema_type.dart';
import '../../../../../workflow/output_vars.dart';
import '../../../../panel_fields/var_picker_model.dart' show PickerVar, VarFilter;

typedef JsonMap = Map<String, Object?>;

/// `CollectionType` (tools/types.ts).
abstract final class CollectionType {
  static const builtIn = 'builtin';
  static const custom = 'api';
  static const workflow = 'workflow';
  static const mcp = 'mcp';
}

/// `VarKindType` (nodes/_base/types.ts) as stored in `tool_parameters` / `tool_configurations` entries.
abstract final class ToolVarKind {
  static const variable = 'variable';
  static const constant = 'constant';
  static const mixed = 'mixed';
}

/// `FormTypeEnum` (model-provider-page/declarations.ts), the values the tool form reads.
abstract final class FormType {
  static const textInput = 'text-input';
  static const textNumber = 'number-input';
  static const secretInput = 'secret-input';
  static const select = 'select';
  static const radio = 'radio';
  static const checkbox = 'checkbox';
  static const boolean = 'boolean';
  static const files = 'files';
  static const file = 'file';
  static const modelSelector = 'model-selector';
  static const toolSelector = 'tool-selector';
  static const multiToolSelector = 'array[tools]';
  static const appSelector = 'app-selector';
  static const any = 'any';
  static const object = 'object';
  static const array = 'array';
  static const dynamicSelect = 'dynamic-select';
  static const date = 'date';
  static const dateRange = 'date-range';
}

/// `label[language] || label.en_US` of an i18n object (a plain string stays).
String i18nText(Object? label, String language) => switch (label) {
  final String s => s,
  final Map m => jsStr(m[language]).orEmptyOr(jsStr(m['en_US'])) ?? '',
  _ => '',
};

extension on String? {
  String? orEmptyOr(String? other) => this == null || this!.isEmpty ? other : this;
}

// ---- to-form-schema.ts ---------------------------------------------------------------------------------------------

/// `toType`.
String toType(String type) => switch (type) {
  'string' => FormType.textInput,
  'number' => FormType.textNumber,
  'boolean' => FormType.checkbox,
  _ => type,
};

/// `toolParametersToFormSchemas`: each `ToolParameter` with `variable` (its name), the form `type`, the raw `_type`,
/// empty `show_on`s and its `human_description` as `tooltip`.
List<JsonMap> toolParametersToFormSchemas(Object? parameters) => [
  for (final p in jsList(parameters))
    if (p is Map)
      {
        ...p.cast<String, Object?>(),
        'variable': p['name'],
        'type': toType(jsStr(p['type']) ?? ''),
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

/// `correctInitialData`.
JsonMap _correctInitialData(String type, JsonMap target, Object? defaultValue) {
  if (type == 'text-input' || type == 'secret-input') target['type'] = ToolVarKind.mixed;
  if (type == 'boolean') {
    if (defaultValue is String) target['value'] = defaultValue == 'true' || defaultValue == '1';
    if (defaultValue is bool) target['value'] = defaultValue;
    if (defaultValue is num) target['value'] = defaultValue == 1;
  }
  if (type == 'number-input' && defaultValue is String && defaultValue.isNotEmpty) {
    target['value'] = double.tryParse(defaultValue) ?? double.nan;
  }
  if (type == FormType.date || type == FormType.dateRange) {
    if (defaultValue is String) target['value'] = defaultValue;
    if (defaultValue is Map) target['value'] = jsonEncode(defaultValue);
  }
  if (type == 'app-selector' || type == 'model-selector') target['value'] = defaultValue;
  return target;
}

/// `getConfiguredValue`: [value] with each schema's `default` filled in where the value is missing or empty
/// (`{type: 'constant', value: default}`, corrected per type; `\n` in string defaults escaped).
JsonMap getConfiguredValue(JsonMap value, List<JsonMap> formSchemas) {
  final out = {...value};
  for (final s in formSchemas) {
    final variable = jsKey(s['variable']);
    final item = value[variable];
    if (s.containsKey('default') && (item == null || item == '')) {
      final d = s['default'];
      final initial = <String, Object?>{
        'type': ToolVarKind.constant,
        'value': d is String ? d.replaceAll('\n', r'\n') : d,
      };
      out[variable] = _correctInitialData(jsStr(s['type']) ?? '', initial, d);
    }
  }
  return out;
}

// ---- form-input-item.helpers.ts ------------------------------------------------------------------------------------

/// `getFormInputState`: what a schema field is and how its current entry ([varInput]) is set.
class FormInputState {
  FormInputState(JsonMap schema, Object? varInput)
    : defaultValue = schema['default'],
      options = [
        for (final o in jsList(schema['options']))
          if (o is Map) o.cast<String, Object?>(),
      ],
      placeholder = schema['placeholder'],
      scope = jsStr(schema['scope']),
      variable = jsKey(schema['variable']),
      _type = jsStr(schema['type']),
      _rawType = jsStr(schema['_type']),
      _multiple = schema['multiple'] == true,
      _kind = jsStr(jsGet(varInput, 'type'));

  final Object? defaultValue;
  final List<JsonMap> options;
  final Object? placeholder;
  final String? scope;
  final String variable;
  final String? _type, _rawType, _kind;
  final bool _multiple;

  bool get isDateRange => _type == FormType.dateRange;
  bool get isDate => _type == FormType.date;
  bool get isString => _type == FormType.textInput || _type == FormType.secretInput;
  bool get isNumber => _type == FormType.textNumber;
  bool get isObject => _type == FormType.object;
  bool get isArray => _type == FormType.array;
  bool get isShowJSONEditor => isObject || isArray;
  bool get isFile => _type == FormType.file || _type == FormType.files;
  bool get isFiles => _type == FormType.files;
  bool get isBoolean => _rawType == FormType.boolean;
  bool get isCheckbox => _rawType == FormType.checkbox;
  bool get isSelect => _type == FormType.select;
  bool get isDynamicSelect => _type == FormType.dynamicSelect;
  bool get isAppSelector => _type == FormType.appSelector;
  bool get isModelSelector => _type == FormType.modelSelector;
  bool get showTypeSwitch => isNumber || isBoolean || isObject || isArray || isSelect || isDate;
  bool get isConstant => _kind == ToolVarKind.constant || _kind == null || _kind.isEmpty;
  bool get showVariableSelector => isFile || _kind == ToolVarKind.variable;
  bool get isMultipleSelect => _multiple && (isSelect || isDynamicSelect);
}

/// `getTargetVarType`: the type a variable for the field must have (the picker's placeholder).
String getTargetVarType(FormInputState s) {
  if (s.isString) return VarType.string;
  if (s.isNumber) return VarType.number;
  if (s.isFile) return s.isFiles ? VarType.arrayFile : VarType.file;
  if (s.isSelect && s.isMultipleSelect) return VarType.arrayString;
  if (s.isSelect) return VarType.string;
  if (s.isBoolean) return VarType.boolean;
  if (s.isObject) return VarType.object;
  if (s.isArray) return VarType.arrayObject;
  return VarType.string;
}

/// `getFilterVar`: which variables the field's picker offers (null: all).
VarFilter? getFilterVar(FormInputState s) {
  VarFilter types(Set<String> t) =>
      (PickerVar v, _) => t.contains(v.type);
  if (s.isNumber) return types({VarType.number});
  if (s.isSelect && s.isMultipleSelect) return types({VarType.array, VarType.arrayString});
  if (s.isString || s.isDate) return types({VarType.string, VarType.number, VarType.secret});
  if (s.isFile) return types({VarType.file, VarType.arrayFile});
  if (s.isBoolean) return types({VarType.boolean});
  if (s.isObject) return types({VarType.object});
  if (s.isArray) return types({VarType.array, VarType.arrayString, VarType.arrayNumber, VarType.arrayObject});
  return null;
}

/// `getVarKindType`: the kind a typed value is stored as (null: keep the entry's).
String? getVarKindType(FormInputState s) {
  if (s.isFile) return ToolVarKind.variable;
  if (s.isSelect ||
      s.isDynamicSelect ||
      s.isBoolean ||
      s.isNumber ||
      s.isArray ||
      s.isObject ||
      s.isDate ||
      s.isDateRange) {
    return ToolVarKind.constant;
  }
  if (s.isString) return ToolVarKind.mixed;
  return null;
}

bool _optionMatches(JsonMap values, Object? showOn) {
  final variable = jsKey(jsGet(showOn, 'variable'));
  final want = jsGet(showOn, 'value');
  return jsGet(values[variable], 'value') == want || values[variable] == want;
}

/// `filterVisibleOptions`: options whose `show_on` conditions all hold for [values].
List<JsonMap> filterVisibleOptions(List<JsonMap> options, JsonMap values) => [
  for (final o in options)
    if (jsList(o['show_on']).isEmpty || jsList(o['show_on']).every((c) => _optionMatches(values, c))) o,
];

String _optionLabel(JsonMap option, String language) {
  final label = option['label'];
  if (label is String) return label;
  final text = i18nText(label, language);
  return text.isNotEmpty ? text : jsKey(option['value']);
}

/// A select option as shown (`SelectItem`).
typedef ToolSelectItem = ({String? icon, String name, String value});

/// `mapSelectItems`.
List<ToolSelectItem> mapSelectItems(List<JsonMap> options, String language) => [
  for (final o in options) (icon: jsStr(o['icon']), name: _optionLabel(o, language), value: jsKey(o['value'])),
];

/// `getSelectedLabels`: up to two labels joined, else "N selected".
String getSelectedLabels(List<Object?>? selected, List<JsonMap> options, String language) {
  if (selected == null || selected.isEmpty) return '';
  final chosen = [
    for (final o in options)
      if (selected.contains(o['value'])) o,
  ];
  if (chosen.length <= 2) return chosen.map((o) => _optionLabel(o, language)).join(', ');
  return '${chosen.length} selected';
}

/// `getCheckboxListOptions`.
List<({String label, String value})> getCheckboxListOptions(List<JsonMap> options, String language) => [
  for (final o in options) (label: _optionLabel(o, language), value: jsKey(o['value'])),
];

/// `getCheckboxListValue`: the checked values still among [available].
List<String> getCheckboxListValue(Object? current, Object? defaultValue, List<JsonMap> available) {
  var values = <String>[];
  if (current is List) {
    values = [for (final v in current) jsKey(v)];
  } else if (current is String) {
    values = [current];
  } else if (defaultValue is List) {
    values = [for (final v in defaultValue) jsKey(v)];
  }
  final allowed = {for (final o in available) jsKey(o['value'])};
  return [
    for (final v in values)
      if (allowed.contains(v)) v,
  ];
}

/// `getNumberInputValue`: the number as text ('' for NaN and non-numbers).
String getNumberInputValue(Object? current) => switch (current) {
  final num n => n.isNaN ? '' : _num(n),
  final String s => s,
  _ => '',
};

String _num(num n) => n == n.roundToDouble() ? '${n.round()}' : '$n';

/// `Number.parseFloat(String(x ?? ''))`: the leading number of the text, NaN when there is none.
double parseFloatJs(Object? x) {
  final s = x == null ? '' : '$x';
  final m = RegExp(r'^\s*([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)').firstMatch(s);
  if (m != null) return double.parse(m.group(1)!);
  if (RegExp(r'^\s*[+-]?Infinity').hasMatch(s)) return s.contains('-') ? double.negativeInfinity : double.infinity;
  return double.nan;
}

/// A number as JSON can hold it (NaN and infinities become null, integral values ints).
Object? jsonNumber(double n) {
  if (!n.isFinite) return null;
  return n == n.truncateToDouble() && n.abs() < 9e15 ? n.toInt() : n;
}

// ---- auth.ts / canFindTool / use-current-tool-collection ---------------------------------------------------------

/// `isToolAuthorizationRequired`: a built-in tool whose deletable provider is not authorized for the team.
bool isToolAuthorizationRequired(String? providerType, [JsonMap? collection]) =>
    providerType == CollectionType.builtIn &&
    jsTruthy(collection?['allow_delete']) &&
    collection?['is_team_authorization'] == false;

/// `canFindTool` (web/utils): [providerId] names the tool [oldToolId] (also in its plugin id forms).
bool canFindTool(String? providerId, String? oldToolId) =>
    providerId == oldToolId ||
    providerId == 'langgenius/$oldToolId/$oldToolId' ||
    providerId == 'langgenius/${oldToolId}_tool/$oldToolId';

/// The workspace's tool collections by kind (Dify's `useAllBuiltInTools` & co., the store's `buildInTools` …).
class ToolCollections {
  const ToolCollections({this.builtIn, this.custom, this.workflow, this.mcp});

  final List<JsonMap>? builtIn, custom, workflow, mcp;

  static const empty = ToolCollections();

  /// The collections of [providerType].
  List<JsonMap> of(String? providerType) =>
      switch (providerType) {
        CollectionType.builtIn => builtIn,
        CollectionType.custom => custom,
        CollectionType.workflow => workflow,
        CollectionType.mcp => mcp,
        _ => null,
      } ??
      const [];
}

/// `useCurrentToolCollection`: the collections of [providerType] and the one whose id names [providerId].
({List<JsonMap> currentTools, JsonMap? currCollection}) currentToolCollection(
  String? providerType,
  String? providerId,
  ToolCollections all,
) {
  final tools = all.of(providerType);
  return (
    currentTools: tools,
    currCollection: tools.where((c) => canFindTool(jsStr(c['id']), providerId)).firstOrNull,
  );
}

// ---- output-schema-utils.ts --------------------------------------------------------------------------------------

/// A schema type definition (`SchemaTypeDefinition`, `/spec/schema-definitions`): `{name, schema}`.
typedef SchemaTypeDefinition = ({String name, Object? schema});

/// `getMatchedSchemaType`: the name of the first definition whose schema [obj] matches, else ''.
String getMatchedSchemaType(Object? obj, List<SchemaTypeDefinition>? defs) {
  if (defs == null || obj == null) return '';
  return defs.where((d) => matchTheSchemaType(obj, d.schema)).firstOrNull?.name ?? '';
}

/// How a schema's own schema type is found (Dify's `getMatchedSchemaType` with the definitions bound).
typedef SchemaTypeMatcher = String? Function(Object? schema);

String? _compactType(String s) {
  final m = RegExp(r'^array\[(string|number|integer|boolean|object|file|any)\]$', caseSensitive: false).firstMatch(
    s.trim(),
  );
  if (m == null) return null;
  return const {
    'string': VarType.arrayString,
    'number': VarType.arrayNumber,
    'integer': VarType.arrayNumber,
    'boolean': VarType.arrayBoolean,
    'object': VarType.arrayObject,
    'file': VarType.arrayFile,
    'any': VarType.arrayAny,
  }[m.group(1)!.toLowerCase()];
}

/// `normalizeJsonSchemaType`: the schema's simple type (first non-null of a union, from oneOf / anyOf / allOf,
/// `object` for properties, `array` for items), null when none.
String? normalizeJsonSchemaType(Object? schema) {
  if (schema is! Map || schema.isEmpty) return null;
  final type = schema['type'];
  if (type is List) {
    return jsStr(type.where((t) => t != null && t != 'null').firstOrNull) ?? jsStr(type.firstOrNull);
  }
  if (type is String) return type;
  for (final key in const ['oneOf', 'anyOf', 'allOf']) {
    for (final candidate in jsList(schema[key])) {
      final n = normalizeJsonSchemaType(candidate);
      if (n != null && n.isNotEmpty) return n;
    }
  }
  if (jsTruthy(schema['properties'])) return 'object';
  if (jsTruthy(schema['items'])) return 'array';
  return null;
}

/// `pickItemSchema`: an array schema's item schema (the first of a tuple).
Object? pickItemSchema(Object? schema) {
  final items = jsGet(schema, 'items');
  if (!jsTruthy(items)) return null;
  return items is List ? items.firstOrNull : items;
}

/// `resolveVarType`: the VarType of a JSON schema (and its matched schema type, via [match]).
({String type, String? schemaType}) resolveVarType(Object? schema, {SchemaTypeMatcher? match}) {
  final st = match?.call(schema);
  final schemaType = st == null || st.isEmpty ? null : st;
  if (jsGet(schema, 'type') case final String t) {
    if (_compactType(t) case final c?) return (type: c, schemaType: schemaType);
  }
  switch (normalizeJsonSchemaType(schema)) {
    case 'string':
      return (type: VarType.string, schemaType: schemaType);
    case 'number':
      return (type: VarType.number, schemaType: schemaType);
    case 'integer':
      return (type: VarType.integer, schemaType: schemaType);
    case 'boolean':
      return (type: VarType.boolean, schemaType: schemaType);
    case 'object':
      return (type: schemaType == 'file' ? VarType.file : VarType.object, schemaType: schemaType);
    case 'array':
      final item = pickItemSchema(schema);
      if (item == null) return (type: VarType.array, schemaType: schemaType);
      final r = resolveVarType(item, match: match);
      final resolved = schemaType ?? r.schemaType;
      if (r.schemaType == 'file') return (type: VarType.arrayFile, schemaType: resolved);
      return (
        type: switch (r.type) {
          VarType.string => VarType.arrayString,
          VarType.number || VarType.integer => VarType.arrayNumber,
          VarType.boolean => VarType.arrayBoolean,
          VarType.object => VarType.arrayObject,
          VarType.file => VarType.arrayFile,
          _ => VarType.array,
        },
        schemaType: resolved,
      );
    default:
      return (type: VarType.any, schemaType: schemaType);
  }
}

/// `getOutputVars` (default.ts): TOOL_OUTPUT_STRUCT, then one variable per property of the tool's `output_schema`.
List<DifyVar> toolOutputVars(JsonMap data, ToolCollections all, {SchemaTypeMatcher? match}) {
  final coll = currentToolCollection(jsStr(data['provider_type']), jsStr(data['provider_id']), all).currCollection;
  final tool = jsList(coll?['tools']).where((t) => jsGet(t, 'name') == data['tool_name']).firstOrNull;
  final props = jsGet(jsGet(tool, 'output_schema'), 'properties');
  if (props is! Map) return [...toolOutputStruct];
  return [
    ...toolOutputStruct,
    for (final MapEntry(:key, :value) in props.entries)
      () {
        final r = resolveVarType(value, match: match);
        return DifyVar(
          '$key',
          r.type,
          schemaType: r.schemaType,
          children: jsGet(value, 'type') == 'object'
              ? {
                  'schema': {'type': 'object', 'properties': jsGet(value, 'properties'), 'additionalProperties': false},
                }
              : null,
        );
      }(),
  ];
}

// ---- default.ts checkValid / getToolCheckParams --------------------------------------------------------------------

/// Dify's `t(key, { ns, ...params })`.
typedef ToolTranslate = String Function(String ns, String key, [Map<String, Object?> params]);

bool _emptyValue(Object? v, JsonMap field) =>
    v == null || v == '' || (field['type'] == 'select' && field['multiple'] == true && v is List && v.isEmpty);

/// The tool's `checkValid`: the error message for [data], '' when valid. [more] is `moreDataForCheckValid`
/// (`toolInputsSchema`, `toolSettingSchema`, `language`, `notAuthed`; see [toolCheckParams]).
String checkValidTool(JsonMap data, ToolTranslate t, JsonMap? more) {
  String required(Object? field) => t('workflow', 'errorMsg.fieldRequired', {'field': field});
  if (jsTruthy(more?['notAuthed'])) return t('workflow', 'errorMsg.authRequired');
  final params = jsGet(data, 'tool_parameters');
  for (final field in jsList(more?['toolInputsSchema']).whereType<Map>().map((m) => m.cast<String, Object?>())) {
    if (field['required'] != true) continue;
    final target = jsGet(params, jsKey(field['variable']));
    if (!jsTruthy(target)) return required(field['label']);
    final value = jsGet(target, 'value');
    if (jsGet(target, 'type') == ToolVarKind.variable) {
      if (!jsTruthy(value) || (value is List && value.isEmpty) || (value is String && value.isEmpty)) {
        return required(field['label']);
      }
    } else if (_emptyValue(value, field)) {
      return required(field['label']);
    }
  }
  final configs = jsGet(data, 'tool_configurations');
  final language = jsStr(more?['language']) ?? 'en_US';
  for (final field in jsList(more?['toolSettingSchema']).whereType<Map>().map((m) => m.cast<String, Object?>())) {
    if (field['required'] != true) continue;
    final label = jsGet(field['label'], language);
    final value = jsGet(configs, jsKey(field['variable']));
    if (_emptyValue(value, field)) return required(label);
    if (value is Map && jsTruthy(value['type'])) {
      final v = value['value'];
      if (v == null || v == '' || (v is List && v.isEmpty)) return required(label);
    }
  }
  return '';
}

/// `getToolCheckParams` (utils/tool.ts): the `moreDataForCheckValid` of a tool node. MCP and other types look in the
/// workflow tools, as in Dify.
JsonMap toolCheckParams(JsonMap data, ToolCollections all, String language) {
  final type = jsStr(data['provider_type']);
  final list = type == CollectionType.builtIn
      ? all.builtIn
      : type == CollectionType.custom
      ? all.custom
      : all.workflow;
  final coll = (list ?? const <JsonMap>[])
      .where((c) => canFindTool(jsStr(c['id']), jsStr(data['provider_id'])))
      .firstOrNull;
  return _moreData(coll, data, language);
}

JsonMap _moreData(JsonMap? coll, JsonMap data, String language) {
  final tool = jsList(coll?['tools']).where((t) => jsGet(t, 'name') == data['tool_name']).firstOrNull;
  final schemas = tool == null ? const <JsonMap>[] : toolParametersToFormSchemas(jsGet(tool, 'parameters'));
  return {
    'toolInputsSchema': [
      for (final s in schemas)
        if (s['form'] == 'llm')
          {
            'label': i18nText(s['label'], language),
            'variable': s['variable'],
            'type': s['type'],
            'required': s['required'],
          },
    ],
    'notAuthed': isToolAuthorizationRequired(jsStr(data['provider_type']), coll),
    'toolSettingSchema': [
      for (final s in schemas)
        if (s['form'] != 'llm') s,
    ],
    'language': language,
  };
}

// ---- use-config.ts --------------------------------------------------------------------------------------------------

/// An `output_schema` property as the panel lists it: an object keeps its schema ([value]); others get the display
/// [type] (`String`, `Array[Number]`, …) and [description].
typedef ToolOutputItem = ({String name, String? type, String? description, Object? value});

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

String _displayType(Object? output) => _capitalize(normalizeJsonSchemaType(output) ?? 'Unknown');

/// What `useConfig` derives from the node's data and the workspace's tools.
class ToolConfig {
  ToolConfig._(this.inputs, this.currCollection, this.currTool, this.formSchemas)
    : _isLoading = null,
      _isShowAuthBtn = null,
      _outputSchema = null,
      _hasObjectOutput = null;

  /// A config from parts (hosts that resolve the tool themselves, tests); the overrides replace what is derived.
  ToolConfig.from({
    required this.inputs,
    this.currCollection,
    this.currTool,
    this.formSchemas = const [],
    this._isLoading,
    this._isShowAuthBtn,
    this._outputSchema,
    this._hasObjectOutput,
  });

  factory ToolConfig.of(JsonMap data, ToolCollections all) {
    final coll = currentToolCollection(jsStr(data['provider_type']), jsStr(data['provider_id']), all).currCollection;
    final tool = jsList(coll?['tools']).where((t) => jsGet(t, 'name') == data['tool_name']).firstOrNull;
    return ToolConfig._(
      data,
      coll,
      tool is Map ? tool.cast<String, Object?>() : null,
      tool == null ? const [] : toolParametersToFormSchemas(jsGet(tool, 'parameters')),
    );
  }

  final JsonMap inputs;
  final JsonMap? currCollection;
  final JsonMap? currTool;
  final List<JsonMap> formSchemas;
  final bool? _isLoading, _isShowAuthBtn, _hasObjectOutput;
  final List<ToolOutputItem>? _outputSchema;

  String? get providerType => jsStr(inputs['provider_type']);
  bool get isBuiltIn => providerType == CollectionType.builtIn;

  JsonMap get toolParameters => _map(inputs['tool_parameters']);
  JsonMap get toolConfigurations => _map(inputs['tool_configurations']);
  static JsonMap _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

  /// The llm-form parameters ("Input Variables", stored in `tool_parameters`).
  late final toolInputVarSchema = [
    for (final s in formSchemas)
      if (s['form'] == 'llm') s,
  ];

  /// The other parameters ("Settings", stored in `tool_configurations`).
  late final toolSettingSchema = [
    for (final s in formSchemas)
      if (s['form'] != 'llm') s,
  ];

  bool get isShowAuthBtn => _isShowAuthBtn ?? isToolAuthorizationRequired(providerType, currCollection);

  /// `isLoading` (as written in Dify: true only for a resolved tool without its built-in collection).
  bool get isLoading => _isLoading ?? (currTool != null && isBuiltIn && currCollection == null);

  /// `toolSettingValue`: the settings with schema defaults until the first edit ([notSetDefaultValue]).
  JsonMap toolSettingValue({required bool notSetDefaultValue}) =>
      notSetDefaultValue ? toolConfigurations : getConfiguredValue(toolConfigurations, toolSettingSchema);

  /// The `setInputs` coercion: with a boolean or number-input setting, string / number setting values become booleans
  /// / floats.
  JsonMap coerce(JsonMap value) {
    final needs = toolSettingSchema.any((s) => s['type'] == 'boolean' || s['type'] == 'number-input');
    if (!needs) return value;
    final configs = {..._map(value['tool_configurations'])};
    for (final key in configs.keys.toList()) {
      final schema = formSchemas.where((s) => s['variable'] == key).firstOrNull;
      final v = configs[key];
      if (schema?['type'] == 'boolean') {
        if (v is String) configs[key] = v == 'true' || v == '1';
        if (v is num) configs[key] = v == 1;
      }
      if (schema?['type'] == 'number-input' && v is String && v.isNotEmpty) {
        configs[key] = jsonNumber(parseFloatJs(v));
      }
    }
    return {...value, 'tool_configurations': configs};
  }

  /// `formattingParameters`: the inputs with defaults filled into empty `tool_configurations` / `tool_parameters`;
  /// null when nothing changes (no tool, or nothing to fill).
  JsonMap? formattingParameters() {
    if (currTool == null) return null;
    JsonMap? next;
    if (toolConfigurations.isEmpty) {
      final c = getConfiguredValue(toolConfigurations, toolSettingSchema);
      if (c.isNotEmpty) next = {...?next, 'tool_configurations': c};
    }
    if (toolParameters.isEmpty) {
      final p = getConfiguredValue(toolParameters, toolInputVarSchema);
      if (p.isNotEmpty) next = {...?next, 'tool_parameters': p};
    }
    return next == null ? null : {...inputs, ...next};
  }

  /// `getMoreDataForCheckValid`.
  JsonMap moreDataForCheckValid(String language) => _moreData(currCollection, inputs, language);

  /// `outputSchema`.
  late final List<ToolOutputItem> outputSchema =
      _outputSchema ??
      () {
        final props = jsGet(jsGet(currTool, 'output_schema'), 'properties');
        if (props is! Map) return const <ToolOutputItem>[];
        return [
          for (final MapEntry(:key, :value) in props.entries)
            if (jsGet(value, 'type') == 'object')
              (name: '$key', type: null, description: null, value: value)
            else
              (
                name: '$key',
                type: normalizeJsonSchemaType(value) == 'array'
                    ? 'Array[${jsTruthy(jsGet(value, 'items')) ? _displayType(jsGet(value, 'items')) : 'Unknown'}]'
                    : _displayType(value),
                description: jsStr(jsGet(value, 'description')),
                value: value,
              ),
        ];
      }();

  /// `hasObjectOutput`.
  bool get hasObjectOutput {
    if (_hasObjectOutput != null) return _hasObjectOutput;
    final props = jsGet(jsGet(currTool, 'output_schema'), 'properties');
    return props is Map && props.values.any((p) => jsGet(p, 'type') == 'object');
  }
}

/// `wrapStructuredVarItem` (utils/tool.ts): an object output as a structured output with one property.
JsonMap wrapStructuredVarItem(ToolOutputItem item, String matchedSchemaType) => {
  'schema': {
    'type': 'object',
    'properties': {
      item.name: {...?(item.value as Map?)?.cast<String, Object?>(), 'schemaType': matchedSchemaType},
    },
    'additionalProperties': false,
  },
};

// ---- use-single-run-form-params.ts ----------------------------------------------------------------------------------

/// A single-run form input (`InputVar`) as plain JSON (`type`, `label`, `variable`, `required`, …).
typedef ToolInputVar = JsonMap;

/// `useSingleRunFormParams` for the tool node: the variables the run form asks for, its values, and the selectors
/// it depends on. [getInputVars] is the panel's `getInputVars` (variables referenced in the texts).
class ToolSingleRunParams {
  ToolSingleRunParams({
    required JsonMap inputs,
    required List<ToolInputVar> Function(List<String> texts) getInputVars,
    this.setRunInputData,
    this.runResult,
    this.formatTracing,
  }) : _params = ConfigMap.of(inputs['tool_parameters']) {
    final configs = ConfigMap.of(inputs['tool_configurations']);
    final hadVarParams = [
      for (final e in _params.entries)
        if (jsGet(e.value, 'type') != ToolVarKind.constant) e.value,
    ];
    final hadVarSettings = [
      for (final e in configs.entries)
        if (e.value is Map && jsTruthy(jsGet(e.value, 'type')) && jsGet(e.value, 'type') != ToolVarKind.constant)
          e.value,
    ];
    varInputs = getInputVars([
      for (final p in [...hadVarParams, ...hadVarSettings])
        if (jsGet(p, 'type') == ToolVarKind.variable)
          switch (jsGet(p, 'value')) {
            final List l => '{{#${l.join('.')}#}}',
            final v => '{{#$v#}}',
          }
        else
          jsStr(jsGet(p, 'value')) ?? '${jsGet(p, 'value')}',
    ]);
  }

  final JsonMap _params;
  late final List<ToolInputVar> varInputs;
  final void Function(JsonMap values)? setRunInputData;
  final JsonMap? runResult;

  /// `formatToTracingNodeList([runResult], t)[0]`.
  final JsonMap Function(JsonMap runResult)? formatTracing;

  JsonMap _values = {};

  /// `handleInputVarValuesChange`.
  void onChange(JsonMap values) {
    _values = values;
    setRunInputData?.call(values);
  }

  /// `inputVarValuesWithConstantValue` (the form's values).
  JsonMap get values {
    final out = {..._values};
    for (final e in _params.entries) {
      final type = jsGet(e.value, 'type'), value = jsGet(e.value, 'value');
      if (type == ToolVarKind.constant && value == null) {
        final tp = out['tool_parameters'];
        if (!jsTruthy(tp) || !jsTruthy(jsGet(tp, e.key))) continue;
        out[e.key] = value;
      }
    }
    return out;
  }

  /// The single form (`forms`).
  List<({List<ToolInputVar> inputs, JsonMap values, void Function(JsonMap) onChange})> get forms => [
    (inputs: varInputs, values: values, onChange: onChange),
  ];

  /// `nodeInfo`.
  JsonMap? get nodeInfo => runResult == null ? null : formatTracing?.call(runResult!);

  /// `getDependentVars`: the selectors of the form's variables (`#a.b#` -> `[a, b]`).
  List<List<String>> getDependentVars() => [
    for (final i in varInputs)
      if (i['variable'] case final String v when v.length >= 2) v.substring(1, v.length - 1).split('.'),
  ];
}

/// A JSON object read off a config entry (`{}` for anything else).
abstract final class ConfigMap {
  static JsonMap of(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
}

// ---- tool-date-range-value.ts -------------------------------------------------------------------------------------

/// `parseToolDateRangeValue`: a stored range (JSON object, its string form, or a legacy single date as start).
({String? start, String? end}) parseToolDateRangeValue(Object? raw) {
  if (raw == null || raw == '') return (start: null, end: null);
  if (raw is Map) {
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return (start: s(raw['start']), end: s(raw['end']));
  }
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return (start: null, end: null);
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map) return parseToolDateRangeValue(parsed);
    } on FormatException {
      // a legacy single-day value
    }
    if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(trimmed)) return (start: trimmed, end: null);
  }
  return (start: null, end: null);
}

/// `stringifyToolDateRangeValue`: `{"start","end"}` without empty ends, '' when both are empty.
String stringifyToolDateRangeValue(({String? start, String? end}) v) {
  final out = {
    if (v.start != null && v.start!.isNotEmpty) 'start': v.start,
    if (v.end != null && v.end!.isNotEmpty) 'end': v.end,
  };
  return out.isEmpty ? '' : jsonEncode(out);
}

// ---- tool-form/item.tsx --------------------------------------------------------------------------------------------

/// `renderDescriptionWithLinks`: [text] split into plain parts and `https?://` URLs.
List<({String text, bool isLink})> descriptionParts(String text) {
  final out = <({String text, bool isLink})>[];
  var at = 0;
  for (final m in RegExp(r'(https?://\S+)').allMatches(text)) {
    if (m.start > at) out.add((text: text.substring(at, m.start), isLink: false));
    out.add((text: m.group(0)!, isLink: true));
    at = m.end;
  }
  if (at < text.length) out.add((text: text.substring(at), isLink: false));
  return out;
}
