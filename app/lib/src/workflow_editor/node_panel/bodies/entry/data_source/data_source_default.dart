/// The data source nodes' data logic: nodes/data-source (default.ts, constants.ts, hooks/use-config.ts,
/// workflow/utils/data-source.ts, block-selector/constants.tsx) and nodes/data-source-empty/default.ts.
library;

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/match_schema_type.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../header/checklist/node_validators.dart' show ChecklistTranslate;
import '../../../../panel_fields/node_config.dart' show Json;
import '../trigger_plugin/trigger_plugin_default.dart' show labelOf, toolParametersToFormSchemas;

/// `defaultValue` (default.ts); the pipeline's block list adds `_dataSourceStartToAdd: true`.
const Json dataSourceDefaultValue = {
  'datasource_parameters': <String, Object?>{},
  'datasource_configurations': <String, Object?>{},
};

/// `DataSourceClassification.localFile`.
const localFileProviderType = 'local_file';

/// `DEFAULT_FILE_EXTENSIONS_IN_LOCAL_FILE_DATA_SOURCE` (block-selector/constants.tsx): what a new `langgenius/file`
/// data source accepts.
const defaultLocalFileExtensions = [
  'txt', 'markdown', 'mdx', 'pdf', 'html', 'xlsx', 'xls', 'vtt', 'properties', 'doc', 'docx', 'csv', 'eml', 'msg', //
  'pptx', 'xml', 'epub', 'ppt', 'md',
];

typedef OutputSubItem = ({String name, String type, String description});
typedef OutputItem = ({String name, String type, String description, List<OutputSubItem> subItems});

/// `COMMON_OUTPUT`.
const List<OutputItem> commonOutput = [
  (
    name: 'datasource_type',
    type: VarType.string,
    description: 'local_file, online_document, website_crawl',
    subItems: [],
  ),
];

/// `LOCAL_FILE_OUTPUT`.
const List<OutputItem> localFileOutput = [
  (
    name: 'file',
    type: VarType.file,
    description: 'file',
    subItems: [
      (name: 'name', type: VarType.string, description: 'file name'),
      (name: 'size', type: VarType.number, description: 'file size'),
      (name: 'type', type: VarType.string, description: 'file type'),
      (name: 'extension', type: VarType.string, description: 'file extension'),
      (name: 'mime_type', type: VarType.string, description: 'file mime type'),
      (name: 'transfer_method', type: VarType.string, description: 'file transfer method'),
      (name: 'url', type: VarType.string, description: 'file url'),
      (name: 'related_id', type: VarType.string, description: 'file related id'),
    ],
  ),
];

/// The node's data source in the host's `dataSourceList` (by `plugin_id`).
Json? findDataSource(List<Json>? dataSourceList, Json data) =>
    dataSourceList?.where((ds) => ds['plugin_id'] == data['plugin_id']).firstOrNull;

/// The data source's tool named `datasource_name`.
Json? findDataSourceItem(Json? dataSource, Json data) {
  for (final t in jsList(dataSource?['tools'])) {
    if (t is Map && t['name'] == data['datasource_name']) return t.cast<String, Object?>();
  }
  return null;
}

/// `${s.slice(0, 1).toLocaleUpperCase()}${s.slice(1)}` and the lower-case variant.
String _upperFirst(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
String _lowerFirst(String s) => s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';

/// One `outputSchema` entry of use-config: objects keep their schema as `value`, the rest get the display type
/// (`Array[String]`, `Number`, …) and description.
typedef DataSourceOutput = ({String name, Json? value, String? type, String? description});

/// use-config's `outputSchema`: the data source tool's `output_schema.properties`.
List<DataSourceOutput> dataSourceOutputSchema(List<Json>? dataSourceList, Json data) {
  if (dataSourceList == null) return const [];
  final schema = findDataSourceItem(findDataSource(dataSourceList, data), data)?['output_schema'];
  return [
    for (final MapEntry(:key, :value) in jsEntries(jsGet(schema, 'properties')))
      if (jsGet(value, 'type') == 'object')
        (name: key, value: (value! as Map).cast<String, Object?>(), type: null, description: null)
      else
        (
          name: key,
          value: null,
          type: jsGet(value, 'type') == 'array'
              ? 'Array[${_upperFirst(jsStr(jsGet(jsGet(value, 'items'), 'type')) ?? '')}]'
              : _upperFirst(jsStr(jsGet(value, 'type')) ?? ''),
          description: jsStr(jsGet(value, 'description')),
        ),
  ];
}

/// use-config's `hasObjectOutput`.
bool dataSourceHasObjectOutput(List<Json>? dataSourceList, Json data) {
  if (dataSourceList == null) return false;
  final schema = findDataSourceItem(findDataSource(dataSourceList, data), data)?['output_schema'];
  return jsEntries(jsGet(schema, 'properties')).any((e) => jsGet(e.value, 'type') == 'object');
}

/// `getMatchedSchemaType` (use-match-schema-type.ts): the name of the first schema type definition (`{name,
/// schema}`) [obj] matches, '' for none.
String getMatchedSchemaType(Object? obj, List<Json>? definitions) {
  if (definitions == null || obj == null) return '';
  for (final d in definitions) {
    if (matchTheSchemaType(obj, d['schema'])) return '${d['name']}';
  }
  return '';
}

/// `wrapStructuredVarItem` (utils/tool.ts).
Json wrapStructuredVarItem(DataSourceOutput item, String matchedSchemaType) => {
  'schema': {
    'type': 'object',
    'properties': {
      item.name: {...?item.value, 'schemaType': matchedSchemaType},
    },
    'additionalProperties': false,
  },
};

/// `handleLocalFileDataSourceInit`: a local-file data source just added gets `_dataSourceStartToAdd: false`; null
/// when nothing is to be written.
Json? dataSourceLocalFileInit(Json data) =>
    jsTruthy(data['_dataSourceStartToAdd']) && data['provider_type'] == localFileProviderType
    ? {...data, '_dataSourceStartToAdd': false}
    : null;

/// `getOutputVars` (default.ts): datasource_type, the local file, the pipeline's [ragVars] of this node, then the
/// tool's output schema (lower-cased types, `object` of schema type `file` as `file`).
List<Json> dataSourceOutputVars(
  Json data,
  List<Json>? dataSourceList, {
  List<Json> ragVars = const [],
  List<Json>? schemaTypeDefinitions,
}) {
  final schema = findDataSourceItem(findDataSource(dataSourceList, data), data)?['output_schema'];
  final dynamicVars = <Json>[];
  for (final MapEntry(:key, :value) in jsEntries(jsGet(schema, 'properties'))) {
    final dataType = jsStr(jsGet(value, 'type')) ?? '';
    var type = dataType == 'array'
        ? 'array[${_lowerFirst(jsStr(jsGet(jsGet(value, 'items'), 'type')) ?? '')}]'
        : _lowerFirst(dataType);
    final schemaType = getMatchedSchemaType(value, schemaTypeDefinitions);
    if (type == 'object' && schemaType == 'file') type = 'file';
    dynamicVars.add({
      'variable': key,
      'type': type,
      'description': jsGet(value, 'description'),
      'schemaType': schemaType,
      'children': dataType == 'object'
          ? {
              'schema': {'type': 'object', 'properties': jsGet(value, 'properties')},
            }
          : null,
    });
  }
  return [
    for (final o in commonOutput) {'variable': o.name, 'type': o.type},
    if (data['provider_type'] == localFileProviderType)
      for (final o in localFileOutput) {'variable': o.name, 'type': o.type},
    ...ragVars,
    ...dynamicVars,
  ];
}

/// `getDataSourceCheckParams` (utils/data-source.ts): the tool's parameters as `{label, variable, type, required,
/// hide}` and whether the (non-local) data source still needs authorizing.
Json getDataSourceCheckParams(Json data, List<Json> dataSourceList, String language) {
  final ds = findDataSource(dataSourceList, data);
  final item = findDataSourceItem(ds, data);
  final schemas = item == null ? const <Json>[] : toolParametersToFormSchemas(item['parameters']);
  return {
    'dataSourceInputsSchema': [
      for (final s in schemas)
        {
          'label': labelOf(s['label'], language),
          'variable': s['variable'],
          'type': s['type'],
          'required': s['required'],
          'hide': s['hide'],
        },
    ],
    'notAuthed':
        data['provider_type'] != localFileProviderType &&
        jsTruthy(ds?['allow_delete']) &&
        !jsTruthy(ds?['is_authorized']),
    'language': language,
  };
}

/// `checkValid` (default.ts): authorization, then each required parameter. As in Dify, a missing parameter
/// overwrites an earlier message while an empty one does not.
String checkValidDataSource(Json data, ChecklistTranslate t, Json? moreData) {
  String required(Object? field) => t('workflow', 'errorMsg.fieldRequired', {'field': jsGet(field, 'label')});
  if (jsTruthy(moreData?['notAuthed'])) return t('workflow', 'errorMsg.authRequired');
  var error = '';
  for (final field in jsList(moreData?['dataSourceInputsSchema'])) {
    if (!jsTruthy(jsGet(field, 'required'))) continue;
    final target = jsGet(data['datasource_parameters'], '${jsGet(field, 'variable')}');
    if (!jsTruthy(target)) {
      error = required(field);
      continue;
    }
    final value = jsGet(target, 'value');
    final empty = jsGet(target, 'type') == 'variable'
        ? !jsTruthy(value) || (value is List && value.isEmpty)
        : value == null || value == '';
    if (error.isEmpty && empty) error = required(field);
  }
  return error;
}

/// The empty data source (data-source-empty/default.ts): `defaultValue` `{}`, always valid.
const Json dataSourceEmptyDefaultValue = {};

String checkValidDataSourceEmpty(Json data, ChecklistTranslate t, Json? moreData) => '';
