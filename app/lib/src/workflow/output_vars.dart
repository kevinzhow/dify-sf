/// The variables each node offers, ported from Dify 1.17.1
/// `web/app/components/workflow/nodes/_base/components/variable/utils.ts` (`formatItem`, `findExceptVarInObject`) and
/// the per-node output definitions it uses (`workflow/constants.ts`, the nodes' `default.ts` `getOutputVars`).
library;

import 'dart:convert';

import 'dify_json.dart';

// ---- Dify's enums and constants --------------------------------------------------------------------------------

/// `VarType` (workflow/types.ts).
abstract final class VarType {
  static const string = 'string';
  static const number = 'number';
  static const integer = 'integer';
  static const secret = 'secret';
  static const boolean = 'boolean';
  static const object = 'object';
  static const file = 'file';
  static const array = 'array';
  static const arrayString = 'array[string]';
  static const arrayNumber = 'array[number]';
  static const arrayObject = 'array[object]';
  static const arrayBoolean = 'array[boolean]';
  static const arrayFile = 'array[file]';
  static const any = 'any';
  static const arrayAny = 'array[any]';
}

/// One output variable as `formatItem` produces it (`Var` in workflow/types.ts): [children] is either a
/// `List<DifyVar>` (object/file members) or a structured-output map `{schema: {type, properties}}` (plain JSON).
final class DifyVar {
  const DifyVar(this.variable, this.type, {this.children, this.schemaType, this.isException = false});

  final String variable;
  final String? type;
  final Object? children;
  final String? schemaType;

  /// error_message / error_type of a node with an error strategy.
  final bool isException;

  DifyVar _withChildren(Object? children, {String? type}) =>
      DifyVar(variable, type ?? this.type, children: children, schemaType: schemaType, isException: isException);

  /// Deep equality (Dify's specs compare vars with `toEqual`).
  @override
  bool operator ==(Object other) =>
      other is DifyVar &&
      other.variable == variable &&
      other.type == type &&
      other.schemaType == schemaType &&
      other.isException == isException &&
      jsonEquals(other.children, children);

  @override
  int get hashCode => Object.hash(variable, type, schemaType, isException);

  @override
  String toString() => 'DifyVar($variable: $type${children == null ? '' : ' $children'})';
}

/// LLM_OUTPUT_STRUCT (workflow/constants.ts).
const llmOutputStruct = [
  DifyVar('text', VarType.string),
  DifyVar('reasoning_content', VarType.string),
  DifyVar('usage', VarType.object),
];

/// KNOWLEDGE_RETRIEVAL_OUTPUT_STRUCT.
const knowledgeRetrievalOutputStruct = [DifyVar('result', VarType.arrayObject)];

/// TEMPLATE_TRANSFORM_OUTPUT_STRUCT.
const templateTransformOutputStruct = [DifyVar('output', VarType.string)];

/// QUESTION_CLASSIFIER_OUTPUT_STRUCT.
const questionClassifierOutputStruct = [
  DifyVar('class_name', VarType.string),
  DifyVar('class_label', VarType.string),
  DifyVar('usage', VarType.object),
];

/// HTTP_REQUEST_OUTPUT_STRUCT.
const httpRequestOutputStruct = [
  DifyVar('body', VarType.string),
  DifyVar('status_code', VarType.number),
  DifyVar('headers', VarType.object),
  DifyVar('files', VarType.arrayFile),
];

/// TOOL_OUTPUT_STRUCT.
const toolOutputStruct = [
  DifyVar('text', VarType.string),
  DifyVar('files', VarType.arrayFile),
  DifyVar('json', VarType.arrayObject),
];

/// AGENT_OUTPUT_STRUCT.
const agentOutputStruct = [
  DifyVar('text', VarType.string),
  DifyVar('files', VarType.arrayFile),
  DifyVar('json', VarType.object),
];

/// HUMAN_INPUT_OUTPUT_STRUCT.
const humanInputOutputStruct = [
  DifyVar('__action_id', VarType.string),
  DifyVar('__action_value', VarType.string),
  DifyVar('__rendered_content', VarType.string),
];

/// PARAMETER_EXTRACTOR_COMMON_STRUCT.
const parameterExtractorCommonStruct = [
  DifyVar('__is_success', VarType.number),
  DifyVar('__reason', VarType.string),
  DifyVar('__usage', VarType.object),
];

/// FILE_STRUCT.
const _fileStruct = {
  'name': VarType.string,
  'size': VarType.number,
  'type': VarType.string,
  'extension': VarType.string,
  'mime_type': VarType.string,
  'transfer_method': VarType.string,
  'url': VarType.string,
  'related_id': VarType.string,
};

/// OUTPUT_FILE_SUB_VARIABLES (nodes/constants.ts): SUB_VARIABLES without `transfer_method`.
const outputFileSubVariables = ['type', 'size', 'name', 'url', 'extension', 'mime_type', 'related_id'];

/// The members of a file var, typed from FILE_STRUCT.
final List<DifyVar> _fileChildren = [
  for (final k in outputFileSubVariables) DifyVar(k, _fileStruct[k] ?? VarType.string),
];

/// SUPPORT_OUTPUT_VARS_NODE (workflow/constants.ts): only these node types contribute variables; a reference to any
/// other node (if-else, answer, end, knowledge-index, trigger-schedule, loop-end, ...) is typed `string`.
const supportOutputVarsNode = {
  'start',
  'trigger-webhook',
  'trigger-plugin',
  'llm',
  'knowledge-retrieval',
  'code',
  'template-transform',
  'http-request',
  'tool',
  'variable-assigner',
  'variable-aggregator',
  'question-classifier',
  'parameter-extractor',
  'iteration',
  'loop',
  'document-extractor',
  'list-operator',
  'agent',
  'agent-v2',
  'datasource',
  'human-input',
};

/// A RAG pipeline input (`RAGPipelineVariable`: `variable`, input `type`, `belong_to_node_id` = 'shared' or the
/// datasource node's id).
final class RagVariable {
  const RagVariable({required this.variable, this.type, required this.belongToNodeId});

  final String variable;
  final String? type;
  final String belongToNodeId;
}

// ---- type mappings -----------------------------------------------------------------------------------------------

/// `inputVarTypeToVarType` (variable/utils.ts): Start / RAG input types; everything else (text-input, paragraph,
/// select, url, json, ...) is `string`.
String inputVarTypeToVarType(Object? type) =>
    const {
      'number': VarType.number,
      'checkbox': VarType.boolean,
      'file': VarType.file,
      'file-list': VarType.arrayFile,
      'json_object': VarType.object,
    }[jsKey(type)] ??
    VarType.string;

// ---- formatItem helpers ------------------------------------------------------------------------------------------

/// `hasValidChildren` (variable/utils.ts).
bool _hasValidChildren(Object? children) =>
    jsTruthy(children) &&
    ((children is List && children.isNotEmpty) ||
        (children is! List && jsKeyCount(jsGet(jsGet(children, 'schema'), 'properties')) > 0));

/// `findExceptVarInStructuredOutput` / `findExceptVarInStructuredProperties` with the always-true filter of
/// toNodeOutputVars: the output is unchanged, but reading `item.type` of a null property throws.
void _checkStructuredProperties(Object? properties) {
  for (final e in jsEntries(properties)) {
    final item = e.value;
    if (item == null) throw JsTypeError('properties.${e.key} is null');
    if (jsGet(item, 'type') == 'object' && jsTruthy(jsGet(item, 'properties'))) {
      _checkStructuredProperties(jsGet(item, 'properties'));
    }
  }
}

/// `findExceptVarInObject` (variable/utils.ts) with the always-true filter: the var becomes `object` (or `file`), its
/// member list drops members that have children but are neither object nor file and whose children are empty.
DifyVar _findExceptVarInObject(DifyVar obj, {required bool isFile}) {
  final children = obj.children;
  final Object childrenResult;
  if (jsTruthy(jsGet(jsGet(children, 'schema'), 'properties'))) {
    _checkStructuredProperties(jsGet(jsGet(children, 'schema'), 'properties'));
    childrenResult = children!;
  } else if (children is List) {
    final kept = <DifyVar>[];
    for (final item in children.cast<DifyVar>()) {
      if (item.children == null) {
        kept.add(item);
        continue;
      }
      final filtered = _findExceptVarInObject(item, isFile: false);
      final passes = item.type == VarType.object || item.type == VarType.file || _hasValidChildren(filtered.children);
      if (passes) kept.add(item._withChildren(filtered.children));
    }
    childrenResult = kept;
  } else {
    childrenResult = const <DifyVar>[];
  }
  return DifyVar(
    obj.variable,
    isFile ? VarType.file : VarType.object,
    children: childrenResult,
    schemaType: obj.schemaType,
    isException: obj.isException,
  );
}

// ---- trigger-plugin output schema (nodes/trigger-plugin/default.ts) ---------------------------------------------

/// `normalizeJsonSchemaType` (trigger-plugin/default.ts).
Object? _normalizeJsonSchemaType(Object? schema) {
  if (!jsTruthy(schema)) return null;
  final type = jsGet(schema, 'type');
  if (type is List) {
    final hit = type.firstWhere((t) => jsTruthy(t) && t != 'null', orElse: () => null);
    return jsTruthy(hit) ? hit : (type.isEmpty ? null : type.first);
  }
  if (type is String) return type;
  for (final key in const ['oneOf', 'anyOf', 'allOf']) {
    for (final candidate in jsList(jsGet(schema, key))) {
      final n = _normalizeJsonSchemaType(candidate);
      if (jsTruthy(n)) return n;
    }
  }
  if (jsTruthy(jsGet(schema, 'properties'))) return 'object';
  if (jsTruthy(jsGet(schema, 'items'))) return 'array';
  return null;
}

Object? _pickItemSchema(Object? schema) {
  final items = jsGet(schema, 'items');
  if (!jsTruthy(schema) || !jsTruthy(items)) return null;
  return items is List ? (items.isEmpty ? null : items.first) : items;
}

String? _extractSchemaType(Object? schema) {
  if (!jsTruthy(schema)) return null;
  final t = jsTruthy(jsGet(schema, 'schema_type')) ? jsGet(schema, 'schema_type') : jsGet(schema, 'schemaType');
  return t is String && t.trim().isNotEmpty ? t : null;
}

/// `resolveVarType` (trigger-plugin/default.ts; not the tool variant, which also needs backend schema definitions).
({String type, String? schemaType}) _resolveTriggerVarType(Object? schema) {
  final schemaType = _extractSchemaType(schema);
  switch (_normalizeJsonSchemaType(schema)) {
    case 'string':
      return (type: VarType.string, schemaType: schemaType);
    case 'number':
      return (type: VarType.number, schemaType: schemaType);
    case 'integer':
      return (type: VarType.integer, schemaType: schemaType);
    case 'boolean':
      return (type: VarType.boolean, schemaType: schemaType);
    case 'object':
      return (type: VarType.object, schemaType: schemaType);
    case 'array':
      final itemSchema = _pickItemSchema(schema);
      if (!jsTruthy(itemSchema)) return (type: VarType.array, schemaType: schemaType);
      final item = _resolveTriggerVarType(itemSchema);
      final resolved = schemaType ?? item.schemaType;
      if (item.schemaType == 'file') return (type: VarType.arrayFile, schemaType: resolved);
      final t = switch (item.type) {
        VarType.string => VarType.arrayString,
        VarType.number || VarType.integer => VarType.arrayNumber,
        VarType.boolean => VarType.arrayBoolean,
        VarType.object => VarType.arrayObject,
        VarType.file => VarType.arrayFile,
        _ => VarType.array,
      };
      return (type: t, schemaType: resolved);
    default:
      return (type: VarType.any, schemaType: schemaType);
  }
}

/// `toFieldType` (trigger-plugin/default.ts): the llm `Type` of a converted field.
String _toFieldType(Object? normalized, String? schemaType) {
  if (schemaType == 'file') return normalized == 'array' ? 'array' : 'file';
  return switch (normalized) {
    'number' || 'integer' => 'number',
    'boolean' => 'boolean',
    'object' => 'object',
    'array' => 'array',
    _ => 'string',
  };
}

/// `convertJsonSchemaToField` (trigger-plugin/default.ts), reduced to what typing reads (type, properties, items).
Map<String, Object?> _convertJsonSchemaToField(Object? schema) {
  final fieldType = _toFieldType(_normalizeJsonSchemaType(schema), _extractSchemaType(schema));
  final field = <String, Object?>{'type': fieldType};
  if (fieldType == 'object') {
    field['properties'] = {
      for (final e in jsEntries(jsTruthy(jsGet(schema, 'properties')) ? jsGet(schema, 'properties') : const {}))
        e.key: _convertJsonSchemaToField(e.value),
    };
  }
  if (fieldType == 'array') {
    final itemSchema = _pickItemSchema(schema);
    if (jsTruthy(itemSchema)) {
      final item = _convertJsonSchemaToField(itemSchema);
      field['items'] = {...item, 'type': item['type'] == 'array' ? 'object' : item['type']};
    }
  }
  return field;
}

/// `buildOutputVars` (trigger-plugin/default.ts).
List<DifyVar> _triggerPluginOutputVars(Object? outputSchema) {
  final schema = jsTruthy(outputSchema) ? outputSchema : const <String, Object?>{};
  if (schema is! Map && schema is! List) return const [];
  final properties = jsGet(schema, 'properties');
  if (!jsTruthy(properties)) return const [];
  return [
    for (final e in jsEntries(properties))
      () {
        final r = _resolveTriggerVarType(e.value);
        final isObject = _normalizeJsonSchemaType(e.value) == 'object';
        final props = jsGet(e.value, 'properties');
        return DifyVar(
          e.key,
          r.type,
          schemaType: r.schemaType,
          children: isObject
              ? {
                  'schema': {
                    'type': 'object',
                    'properties': {
                      for (final p in jsEntries(jsTruthy(props) ? props : const {}))
                        p.key: _convertJsonSchemaToField(p.value),
                    },
                    'additionalProperties': false,
                  },
                }
              : null,
        );
      }(),
  ];
}

// ---- formatItem --------------------------------------------------------------------------------------------------

/// `formatItem` (variable/utils.ts) as toNodeOutputVars calls it, with its always-true `filterVar`: the variables of
/// the node [id] whose Dify `data` (type, title and config as plain JSON) is [data]. [chatMode] is `advanced-chat`;
/// [ragVariables] are the pipeline's inputs (the datasource node lists its own). Throws [JsTypeError] where Dify's code
/// throws.
List<DifyVar> formatItem(
  String id,
  Map<String, Object?> data, {
  bool chatMode = false,
  List<RagVariable> ragVariables = const [],
}) {
  var vars = <DifyVar>[];
  switch (data['type']) {
    case 'start':
      for (final v in jsList(data['variables'])) {
        final type = inputVarTypeToVarType(jsGet(v, 'type'));
        Object? children;
        final schema = jsGet(v, 'json_schema');
        if (type == VarType.object && jsTruthy(schema)) {
          try {
            children = {'schema': schema is String ? jsonDecode(schema) : schema};
          } on FormatException {
            children = null; // console.error, no children
          }
        }
        vars.add(DifyVar(jsKey(jsGet(v, 'variable')), type, children: children));
      }
      if (chatMode) vars.add(const DifyVar('sys.query', VarType.string));
      vars.add(const DifyVar('sys.files', VarType.arrayFile));

    case 'trigger-webhook':
      vars = [
        for (final v in jsList(data['variables']))
          DifyVar(
            jsKey(jsGet(v, 'variable')),
            jsTruthy(jsGet(v, 'value_type')) ? jsStr(jsGet(v, 'value_type')) : VarType.string,
          ),
      ];

    case 'llm':
      vars = [...llmOutputStruct];
      final so = data['structured_output'];
      if (jsTruthy(data['structured_output_enabled']) && jsKeyCount(jsGet(jsGet(so, 'schema'), 'properties')) > 0) {
        vars.add(DifyVar('structured_output', VarType.object, children: so));
      }

    case 'knowledge-retrieval':
      vars = [...knowledgeRetrievalOutputStruct];

    case 'code':
      // Dify's `outputs` is a map name -> {type, children}; a keyed list of {name, type} (this document model's own
      // form) is read the same way.
      final outputs = data['outputs'];
      if (outputs is Map) {
        for (final e in outputs.entries) {
          if (e.value == null) throw JsTypeError('outputs.${e.key} is null');
          vars.add(DifyVar('${e.key}', jsStr(jsGet(e.value, 'type'))));
        }
      } else if (outputs is List) {
        for (final o in outputs) {
          final name = jsGet(o, 'name') ?? jsGet(o, 'variable');
          if (name is String) vars.add(DifyVar(name, jsStr(jsGet(o, 'type'))));
        }
      }

    case 'template-transform':
      vars = [...templateTransformOutputStruct];

    case 'question-classifier':
      vars = [...questionClassifierOutputStruct];

    case 'http-request':
      vars = [...httpRequestOutputStruct];

    case 'variable-assigner' || 'variable-aggregator':
      final adv = data['advanced_settings'];
      if (!jsTruthy(jsGet(adv, 'group_enabled'))) {
        vars = [DifyVar('output', jsStr(data['output_type']))];
      } else {
        final groups = jsGet(adv, 'groups');
        if (groups is! List) throw const JsTypeError('advanced_settings.groups is undefined');
        vars = [
          for (final g in groups)
            DifyVar(
              jsKey(jsGet(g, 'group_name')),
              VarType.object,
              children: [DifyVar('output', jsStr(jsGet(g, 'output_type')))],
            ),
        ];
      }

    case 'tool':
      // ToolNodeDefault.getOutputVars: the tool's output_schema comes from the tool lists (backend); without it
      // Dify returns TOOL_OUTPUT_STRUCT.
      vars = [...toolOutputStruct];

    case 'parameter-extractor':
      vars = [
        for (final p in jsList(data['parameters'])) DifyVar(jsKey(jsGet(p, 'name')), jsStr(jsGet(p, 'type'))),
        ...parameterExtractorCommonStruct,
      ];

    case 'iteration':
      final t = data['output_type'];
      vars = [DifyVar('output', jsTruthy(t) ? jsStr(t) : VarType.arrayString)];

    case 'loop':
      vars = [
        for (final v in jsList(data['loop_variables'])) DifyVar(jsKey(jsGet(v, 'label')), jsStr(jsGet(v, 'var_type'))),
      ];

    case 'document-extractor':
      vars = [DifyVar('text', jsTruthy(data['is_array_file']) ? VarType.arrayString : VarType.string)];

    case 'list-operator':
      if (jsTruthy(data['var_type'])) {
        final item = jsStr(data['item_var_type']);
        vars = [
          DifyVar('result', jsStr(data['var_type'])),
          DifyVar('first_record', item),
          DifyVar('last_record', item),
        ];
      }

    case 'agent':
      if (data['agent_node_kind'] == 'dify_agent' && data['version'] == '2') {
        vars = _agentV2OutputVars(data);
        break;
      }
      for (final e in jsEntries(jsGet(data['output_schema'], 'properties'))) {
        final output = e.value;
        if (output == null) throw JsTypeError('output_schema.properties.${e.key} is null');
        String cap(Object? t) {
          if (!jsTruthy(t)) return 'Unknown';
          if (t is! String) throw const JsTypeError('type.slice(...).toLocaleUpperCase is not a function');
          return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
        }

        final type = jsGet(output, 'type');
        vars.add(DifyVar(e.key, type == 'array' ? 'Array[${cap(jsGet(jsGet(output, 'items'), 'type'))}]' : cap(type)));
      }
      vars = [...vars, ...toolOutputStruct, ...agentOutputStruct];

    case 'agent-v2':
      vars = _agentV2OutputVars(data);

    case 'datasource':
      // DataSourceNodeDefault.getOutputVars: COMMON_OUTPUT, LOCAL_FILE_OUTPUT for local files, the node's RAG inputs,
      // then the plugin's output_schema (from the datasource list: backend, not available here).
      vars = [
        const DifyVar('datasource_type', VarType.string),
        if (data['provider_type'] == 'local_file') const DifyVar('file', VarType.file),
        for (final r in ragVariables)
          if (r.belongToNodeId == id) DifyVar('rag.$id.${r.variable}', inputVarTypeToVarType(r.type)),
      ];

    case 'trigger-plugin':
      vars = _triggerPluginOutputVars(data['output_schema']);

    case 'human-input':
      final inputs = data['inputs'];
      if (inputs is! List) throw const JsTypeError('inputs is undefined');
      vars = [
        for (final i in inputs)
          DifyVar(jsKey(jsGet(i, 'output_variable_name')), switch (jsGet(i, 'type')) {
            'file' => VarType.file,
            'file-list' => VarType.arrayFile,
            _ => VarType.string,
          }),
        ...humanInputOutputStruct,
      ];
  }

  // Any truthy error_strategy, `none` included, adds the exception variables.
  if (jsTruthy(data['error_strategy'])) {
    vars = [
      ...vars,
      const DifyVar('error_message', VarType.string, isException: true),
      const DifyVar('error_type', VarType.string, isException: true),
    ];
  }

  return [
    for (final v in vars)
      if (v.type == VarType.file)
        _findExceptVarInObject(v._withChildren(_fileChildren), isFile: true)
      else if (v.children != null)
        _findExceptVarInObject(v, isFile: false)
      else
        v,
  ];
}

/// `getAgentV2OutputVars` (nodes/agent-v2/output-variables.ts): `text`, then the declared outputs other than the
/// reserved text / switch / _session.
List<DifyVar> _agentV2OutputVars(Map<String, Object?> data) {
  const outputVarTypes = {
    'array': VarType.array,
    'boolean': VarType.boolean,
    'file': VarType.file,
    'number': VarType.number,
    'object': VarType.object,
    'string': VarType.string,
  };
  const arrayItemVarTypes = {
    'array': VarType.array,
    'boolean': VarType.arrayBoolean,
    'file': VarType.arrayFile,
    'number': VarType.arrayNumber,
    'object': VarType.arrayObject,
    'string': VarType.arrayString,
  };
  return [
    const DifyVar('text', VarType.string),
    for (final o in jsList(data['agent_declared_outputs']))
      if (!const {'text', 'switch', '_session'}.contains(jsGet(o, 'name')))
        DifyVar(
          jsKey(jsGet(o, 'name')),
          jsGet(o, 'type') == 'array'
              ? (jsTruthy(jsGet(o, 'array_item'))
                    ? arrayItemVarTypes[jsKey(jsGet(jsGet(o, 'array_item'), 'type'))]
                    : VarType.arrayObject)
              : outputVarTypes[jsKey(jsGet(o, 'type'))],
        ),
  ];
}
