/// The type Dify shows after a variable reference (e.g. the End node's `VariableLabelInNode variableType=...`), ported
/// from Dify 1.17.1 `web/app/components/workflow/nodes/_base/components/variable/utils.ts` (`getVarType`, `formatItem`,
/// `toNodeOutputVars`, `getIterationItemType`, `getLoopItemType`) and the per-node output definitions it uses
/// (`workflow/constants.ts`, the nodes' `default.ts` `getOutputVars`).
///
/// Pure Dart. The port works on plain JSON (the node config converted with [plainOf]) so Dify's JavaScript semantics
/// (truthiness, `a?.b`, `Object.keys`) can be mirrored one to one, quirks included. Where Dify would throw while
/// rendering (it reads a property of `undefined`), [VarTypes.typeOf] returns null.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';

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

/// OUTPUT_FILE_SUB_VARIABLES (nodes/constants.ts): SUB_VARIABLES without `transfer_method`, typed from FILE_STRUCT.
final List<DifyVar> _fileChildren = [
  for (final k in const ['type', 'size', 'name', 'url', 'extension', 'mime_type', 'related_id'])
    DifyVar(k, _fileStruct[k] ?? VarType.string),
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

// ---- inputs ------------------------------------------------------------------------------------------------------

/// An environment or conversation variable declaration (the workflow's `environment_variables` /
/// `conversation_variables`: `{name, value_type, ...}`).
final class DeclaredVar {
  const DeclaredVar(this.name, this.valueType);

  final String name;
  final String? valueType;

  /// Parses Dify's declaration list, as a [Value] (keyed or atomic list of maps) or plain JSON.
  static List<DeclaredVar> listOf(Object? declarations) => [
    for (final d in _list(declarations is Value ? plainOf(declarations) : declarations))
      if (d is Map && d['name'] is String) DeclaredVar(d['name'] as String, _str(d['value_type'])),
  ];
}

/// A RAG pipeline input (`RAGPipelineVariable`: `variable`, input `type`, `belong_to_node_id` = 'shared' or the
/// datasource node's id).
final class RagVariable {
  const RagVariable({required this.variable, this.type, required this.belongToNodeId});

  final String variable;
  final String? type;
  final String belongToNodeId;
}

// ---- value helpers -----------------------------------------------------------------------------------------------

/// A config value as plain JSON, the shape Dify's node `data` has: keyed lists become lists, references (live or
/// broken) become their value selector `[node, output]`.
Object? plainOf(Value? v) => switch (v) {
  null || VNull() => null,
  VBool(:final value) => value,
  VInt(:final value) => value,
  VDouble(:final value) => value,
  VString(:final value) => value,
  VRef(:final ref) || VBroken(:final ref) => [ref.node, ref.output],
  VList(:final items) => [for (final i in items) plainOf(i)],
  VItems(:final items) => [for (final i in items) plainOf(i.value)],
  VMap(:final entries) => {for (final e in entries.entries) e.key: plainOf(e.value)},
};

/// The value selector stored at a config value (`value_selector`, `variable_selector`, ...): a reference (live or
/// broken) or a plain list of strings (sys/env/conversation variables, deeper paths); null for anything else.
List<String>? selectorOf(Value? v) => switch (v) {
  VRef(:final ref) || VBroken(:final ref) => [ref.node, ref.output],
  VList(:final items) => [for (final i in items) ?(i is VString ? i.value : null)],
  _ => null,
};

/// The label text Dify renders for a type (variable-label/base/variable-label.tsx: es-toolkit `capitalize`, which
/// also lower-cases the rest): `array[file]` -> `Array[file]`. Null or empty: no label.
String? varTypeLabel(String? type) =>
    (type == null || type.isEmpty) ? null : type[0].toUpperCase() + type.substring(1).toLowerCase();

/// What Dify's render would throw (a property read on `undefined`); surfaces as a null type.
final class _JsTypeError implements Exception {
  const _JsTypeError(this.what);
  final String what;
  @override
  String toString() => 'TypeError: $what';
}

bool _truthy(Object? x) => switch (x) {
  null => false,
  final bool b => b,
  final num n => n != 0 && !n.isNaN,
  final String s => s.isNotEmpty,
  _ => true,
};

String? _str(Object? x) => x is String ? x : null;

Object? _get(Object? o, String key) => o is Map ? o[key] : null;

List<Object?> _list(Object? x) => x is List ? x.cast<Object?>() : const [];

/// Number of `Object.keys(x)`.
int _keyCount(Object? x) => switch (x) {
  final Map m => m.length,
  final List l => l.length,
  final String s => s.length,
  _ => 0,
};

/// `Object.entries(x)` for objects and arrays.
Iterable<MapEntry<String, Object?>> _entries(Object? x) => switch (x) {
  final Map m => m.entries.map((e) => MapEntry('${e.key}', e.value)),
  final List l => [for (final (i, v) in l.indexed) MapEntry('$i', v)],
  _ => const [],
};

/// A JS property key as `String(x)` makes it (`['number']` is the key `number`).
String _jsKey(Object? x) => switch (x) {
  null => 'undefined',
  final List l => l.map((e) => e == null ? '' : _jsKey(e)).join(','),
  _ => '$x',
};

String _capitalizeFirst(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

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
    }[_jsKey(type)] ??
    VarType.string;

/// `structTypeToVarType` (variable/utils.ts), as getVarType calls it (never with `isArray`): JSON-schema `integer`,
/// `file`, `enum` and unknown types are `string`; arrays are plain `array`.
String _structTypeToVarType(Object? type) =>
    const {
      'string': VarType.string,
      'number': VarType.number,
      'boolean': VarType.boolean,
      'object': VarType.object,
      'array': VarType.array,
    }[_jsKey(type)] ??
    VarType.string;

// ---- formatItem helpers ------------------------------------------------------------------------------------------

/// `hasValidChildren` (variable/utils.ts).
bool _hasValidChildren(Object? children) =>
    _truthy(children) &&
    ((children is List && children.isNotEmpty) ||
        (children is! List && _keyCount(_get(_get(children, 'schema'), 'properties')) > 0));

/// `findExceptVarInStructuredOutput` / `findExceptVarInStructuredProperties` with the always-true filter of
/// toNodeOutputVars: the output is unchanged, but reading `item.type` of a null property throws.
void _checkStructuredProperties(Object? properties) {
  for (final e in _entries(properties)) {
    final item = e.value;
    if (item == null) throw _JsTypeError('properties.${e.key} is null');
    if (_get(item, 'type') == 'object' && _truthy(_get(item, 'properties'))) {
      _checkStructuredProperties(_get(item, 'properties'));
    }
  }
}

/// `findExceptVarInObject` (variable/utils.ts) with the always-true filter: the var becomes `object` (or `file`), its
/// member list drops members that have children but are neither object nor file and whose children are empty.
DifyVar _findExceptVarInObject(DifyVar obj, {required bool isFile}) {
  final children = obj.children;
  final Object childrenResult;
  if (_truthy(_get(_get(children, 'schema'), 'properties'))) {
    _checkStructuredProperties(_get(_get(children, 'schema'), 'properties'));
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
  if (!_truthy(schema)) return null;
  final type = _get(schema, 'type');
  if (type is List) {
    final hit = type.firstWhere((t) => _truthy(t) && t != 'null', orElse: () => null);
    return _truthy(hit) ? hit : (type.isEmpty ? null : type.first);
  }
  if (type is String) return type;
  for (final key in const ['oneOf', 'anyOf', 'allOf']) {
    for (final candidate in _list(_get(schema, key))) {
      final n = _normalizeJsonSchemaType(candidate);
      if (_truthy(n)) return n;
    }
  }
  if (_truthy(_get(schema, 'properties'))) return 'object';
  if (_truthy(_get(schema, 'items'))) return 'array';
  return null;
}

Object? _pickItemSchema(Object? schema) {
  final items = _get(schema, 'items');
  if (!_truthy(schema) || !_truthy(items)) return null;
  return items is List ? (items.isEmpty ? null : items.first) : items;
}

String? _extractSchemaType(Object? schema) {
  if (!_truthy(schema)) return null;
  final t = _truthy(_get(schema, 'schema_type')) ? _get(schema, 'schema_type') : _get(schema, 'schemaType');
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
      if (!_truthy(itemSchema)) return (type: VarType.array, schemaType: schemaType);
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
      for (final e in _entries(_truthy(_get(schema, 'properties')) ? _get(schema, 'properties') : const {}))
        e.key: _convertJsonSchemaToField(e.value),
    };
  }
  if (fieldType == 'array') {
    final itemSchema = _pickItemSchema(schema);
    if (_truthy(itemSchema)) {
      final item = _convertJsonSchemaToField(itemSchema);
      field['items'] = {...item, 'type': item['type'] == 'array' ? 'object' : item['type']};
    }
  }
  return field;
}

/// `buildOutputVars` (trigger-plugin/default.ts).
List<DifyVar> _triggerPluginOutputVars(Object? outputSchema) {
  final schema = _truthy(outputSchema) ? outputSchema : const <String, Object?>{};
  if (schema is! Map && schema is! List) return const [];
  final properties = _get(schema, 'properties');
  if (!_truthy(properties)) return const [];
  return [
    for (final e in _entries(properties))
      () {
        final r = _resolveTriggerVarType(e.value);
        final isObject = _normalizeJsonSchemaType(e.value) == 'object';
        final props = _get(e.value, 'properties');
        return DifyVar(
          e.key,
          r.type,
          schemaType: r.schemaType,
          children: isObject
              ? {
                  'schema': {
                    'type': 'object',
                    'properties': {
                      for (final p in _entries(_truthy(props) ? props : const {}))
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

// ---- the lookup --------------------------------------------------------------------------------------------------

/// Answers "what type does Dify show for the variable at this value selector" for one workflow.
///
/// [lookup] stands for Dify's `availableNodes` (for the End node: `getBeforeNodesInSameBranch(id)`); return null for
/// nodes Dify would not consider (deleted, not upstream) and they type as `string`, as in Dify. [start] is the Start
/// node among them (system variables `sys.query` / `sys.files` live under it). [chatMode] is `advanced-chat`.
/// [environmentVariables] / [conversationVariables] are the workflow's declarations (conversation variables only count
/// in chat mode, as in `toNodeOutputVars`). [inWorkflowPage] is Dify's `isInWorkflowPage()` (the editor URL), which
/// adds `sys.timestamp` in workflow mode.
///
/// Tool nodes type with Dify's static TOOL_OUTPUT_STRUCT and datasource nodes without their plugin output schema:
/// both need backend data (the tool / datasource lists) that Dify fetches separately.
final class VarTypes {
  VarTypes({
    required this.lookup,
    Node? start,
    this.chatMode = false,
    this.environmentVariables = const [],
    this.conversationVariables = const [],
    this.ragVariables = const [],
    this.inWorkflowPage = true,
  }) : start = start?.type == 'start' ? start : null;

  final Node? Function(String id) lookup;
  final Node? start;
  final bool chatMode;
  final List<DeclaredVar> environmentVariables;
  final List<DeclaredVar> conversationVariables;
  final List<RagVariable> ragVariables;
  final bool inWorkflowPage;

  /// Per-node variables, computed once: make a new [VarTypes] when the workflow changes.
  final Map<String, List<DifyVar>?> _cache = {};

  /// `getVarType` (variable/utils.ts) as `useWorkflowVariables().getCurrentVariableType` calls it: the VarType string
  /// Dify shows for [selector], or null when it shows none (Dify's `undefined`, or where its render would throw).
  ///
  /// [parent] is the enclosing iteration/loop node (`parentNode`) for variables used inside one: `[x, 'item']` is then
  /// the item type of the parent's `iterator_selector` and `[x, 'index']` a number. [isIterationItem] /
  /// [isLoopItem] type [selector] as the item of the array it points to. [isConstant] is always `string`.
  String? typeOf(
    List<String> selector, {
    Node? parent,
    bool isIterationItem = false,
    bool isLoopItem = false,
    bool isConstant = false,
    bool preferSchemaType = false,
  }) {
    try {
      return _getVarType(selector, parent, isIterationItem, isLoopItem, isConstant, preferSchemaType);
    } on _JsTypeError {
      return null;
    }
  }

  /// The variables a node offers (`formatItem` in variable/utils.ts, as toNodeOutputVars calls it), or null when Dify
  /// would list none: an unsupported node type or no variables. Throws [StateError] where Dify's own code throws.
  List<DifyVar>? outputVarsOf(Node node) {
    try {
      return _nodeVars(node);
    } on _JsTypeError catch (e) {
      throw StateError('Dify cannot format ${node.id}: $e');
    }
  }

  // -- toNodeOutputVars: one entry per available node with variables, then ENV, CONVERSATION, SYSTEM, SHARED INPUTS.

  List<DifyVar>? _nodeVars(Node node) {
    if (!supportOutputVarsNode.contains(node.type)) return null;
    final vars = _formatItem(node.id, {
      for (final e in node.config.entries) e.key: plainOf(e.value),
      'type': node.type,
      'title': node.title,
    });
    return vars.isEmpty ? null : vars;
  }

  /// `beforeNodesOutputVars.find((v) => v.nodeId === id)?.vars`.
  List<DifyVar>? _group(String? id) {
    if (id == null) return null;
    if (_cache.containsKey(id)) return _cache[id];
    List<DifyVar>? vars;
    final node = lookup(id);
    if (node != null) vars = _nodeVars(node);
    vars ??= switch (id) {
      'env' when environmentVariables.isNotEmpty => [
        for (final e in environmentVariables)
          if (e.valueType != 'llm') DifyVar('env.${e.name}', e.valueType),
      ],
      'conversation' when chatMode && conversationVariables.isNotEmpty => [
        for (final c in conversationVariables) DifyVar('conversation.${c.name}', c.valueType),
      ],
      'global' => _globalVars(),
      'rag' => [
        for (final r in ragVariables)
          if (r.belongToNodeId == 'shared') DifyVar('rag.shared.${r.variable}', inputVarTypeToVarType(r.type)),
      ],
      _ => null,
    };
    if (vars != null && vars.isEmpty) vars = null;
    return _cache[id] = vars;
  }

  /// The Start node's entry (`beforeNodesOutputVars.find((v) => v.isStartNode)`).
  List<DifyVar>? _startGroup() => start == null ? null : _group(start!.id) ?? _nodeVars(start!);

  /// `getGlobalVars` (workflow/constants.ts).
  List<DifyVar> _globalVars() => [
    if (chatMode) ...[
      const DifyVar('sys.dialogue_count', VarType.number),
      const DifyVar('sys.conversation_id', VarType.string),
    ],
    const DifyVar('sys.user_id', VarType.string),
    const DifyVar('sys.app_id', VarType.string),
    const DifyVar('sys.workflow_id', VarType.string),
    const DifyVar('sys.workflow_run_id', VarType.string),
    if (inWorkflowPage && !chatMode) const DifyVar('sys.timestamp', VarType.number),
  ];

  // -- formatItem

  List<DifyVar> _formatItem(String id, Map<String, Object?> data) {
    var vars = <DifyVar>[];
    switch (data['type']) {
      case 'start':
        for (final v in _list(data['variables'])) {
          final type = inputVarTypeToVarType(_get(v, 'type'));
          Object? children;
          final schema = _get(v, 'json_schema');
          if (type == VarType.object && _truthy(schema)) {
            try {
              children = {'schema': schema is String ? jsonDecode(schema) : schema};
            } on FormatException {
              children = null; // console.error, no children
            }
          }
          vars.add(DifyVar(_jsKey(_get(v, 'variable')), type, children: children));
        }
        if (chatMode) vars.add(const DifyVar('sys.query', VarType.string));
        vars.add(const DifyVar('sys.files', VarType.arrayFile));

      case 'trigger-webhook':
        vars = [
          for (final v in _list(data['variables']))
            DifyVar(
              _jsKey(_get(v, 'variable')),
              _truthy(_get(v, 'value_type')) ? _str(_get(v, 'value_type')) : VarType.string,
            ),
        ];

      case 'llm':
        vars = [...llmOutputStruct];
        final so = data['structured_output'];
        if (_truthy(data['structured_output_enabled']) && _keyCount(_get(_get(so, 'schema'), 'properties')) > 0) {
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
            if (e.value == null) throw _JsTypeError('outputs.${e.key} is null');
            vars.add(DifyVar('${e.key}', _str(_get(e.value, 'type'))));
          }
        } else if (outputs is List) {
          for (final o in outputs) {
            final name = _get(o, 'name') ?? _get(o, 'variable');
            if (name is String) vars.add(DifyVar(name, _str(_get(o, 'type'))));
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
        if (!_truthy(_get(adv, 'group_enabled'))) {
          vars = [DifyVar('output', _str(data['output_type']))];
        } else {
          final groups = _get(adv, 'groups');
          if (groups is! List) throw const _JsTypeError('advanced_settings.groups is undefined');
          vars = [
            for (final g in groups)
              DifyVar(
                _jsKey(_get(g, 'group_name')),
                VarType.object,
                children: [DifyVar('output', _str(_get(g, 'output_type')))],
              ),
          ];
        }

      case 'tool':
        // ToolNodeDefault.getOutputVars: the tool's output_schema comes from the tool lists (backend); without it
        // Dify returns TOOL_OUTPUT_STRUCT.
        vars = [...toolOutputStruct];

      case 'parameter-extractor':
        vars = [
          for (final p in _list(data['parameters'])) DifyVar(_jsKey(_get(p, 'name')), _str(_get(p, 'type'))),
          ...parameterExtractorCommonStruct,
        ];

      case 'iteration':
        final t = data['output_type'];
        vars = [DifyVar('output', _truthy(t) ? _str(t) : VarType.arrayString)];

      case 'loop':
        vars = [
          for (final v in _list(data['loop_variables'])) DifyVar(_jsKey(_get(v, 'label')), _str(_get(v, 'var_type'))),
        ];

      case 'document-extractor':
        vars = [DifyVar('text', _truthy(data['is_array_file']) ? VarType.arrayString : VarType.string)];

      case 'list-operator':
        if (_truthy(data['var_type'])) {
          final item = _str(data['item_var_type']);
          vars = [
            DifyVar('result', _str(data['var_type'])),
            DifyVar('first_record', item),
            DifyVar('last_record', item),
          ];
        }

      case 'agent':
        if (data['agent_node_kind'] == 'dify_agent' && data['version'] == '2') {
          vars = _agentV2OutputVars(data);
          break;
        }
        for (final e in _entries(_get(data['output_schema'], 'properties'))) {
          final output = e.value;
          if (output == null) throw _JsTypeError('output_schema.properties.${e.key} is null');
          String cap(Object? t) {
            if (!_truthy(t)) return 'Unknown';
            if (t is! String) throw const _JsTypeError('type.slice(...).toLocaleUpperCase is not a function');
            return _capitalizeFirst(t);
          }

          final type = _get(output, 'type');
          vars.add(DifyVar(e.key, type == 'array' ? 'Array[${cap(_get(_get(output, 'items'), 'type'))}]' : cap(type)));
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
        if (inputs is! List) throw const _JsTypeError('inputs is undefined');
        vars = [
          for (final i in inputs)
            DifyVar(_jsKey(_get(i, 'output_variable_name')), switch (_get(i, 'type')) {
              'file' => VarType.file,
              'file-list' => VarType.arrayFile,
              _ => VarType.string,
            }),
          ...humanInputOutputStruct,
        ];
    }

    // Any truthy error_strategy, `none` included, adds the exception variables.
    if (_truthy(data['error_strategy'])) {
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
      for (final o in _list(data['agent_declared_outputs']))
        if (!const {'text', 'switch', '_session'}.contains(_get(o, 'name')))
          DifyVar(
            _jsKey(_get(o, 'name')),
            _get(o, 'type') == 'array'
                ? (_truthy(_get(o, 'array_item'))
                      ? arrayItemVarTypes[_jsKey(_get(_get(o, 'array_item'), 'type'))]
                      : VarType.arrayObject)
                : outputVarTypes[_jsKey(_get(o, 'type'))],
          ),
    ];
  }

  // -- getVarType

  String? _getVarType(
    List<String> sel,
    Node? parent,
    bool isIterationItem,
    bool isLoopItem,
    bool isConstant,
    bool preferSchemaType,
  ) {
    if (isConstant) return VarType.string;
    String? at(int i) => i < sel.length ? sel[i] : null;

    if (isIterationItem) return _iterationItemType(sel);
    if (parent?.type == 'iteration') {
      if (at(1) == 'item') return _iterationItemType(selectorOf(parent!.config['iterator_selector']) ?? const []);
      if (at(1) == 'index') return VarType.number;
    }
    if (isLoopItem) return _loopItemType(sel);
    if (parent?.type == 'loop') {
      if (at(1) == 'item') return _loopItemType(selectorOf(parent!.config['iterator_selector']) ?? const []);
      if (at(1) == 'index') return VarType.number;
    }

    final isSystem = _isSystemVar(sel);
    final isGlobal = isSystem && !const ['query', 'files'].contains(at(1));
    final isInStartNodeSysVar = isSystem && !isGlobal;
    final isEnv = at(0) == 'env';
    final isChatVar = at(0) == 'conversation';
    final isRag = at(0) == 'rag';
    final isSharedRag = isRag && at(1) == 'shared';
    final isInNodeRag = isRag && at(1) != 'shared';

    final vars = isInStartNodeSysVar
        ? _startGroup()
        : _group(
            isGlobal
                ? 'global'
                : isInNodeRag
                ? at(1)
                : at(0),
          );
    if (vars == null) return VarType.string;

    final joined = sel.join('.');
    if (isInStartNodeSysVar || isEnv || isChatVar || isSharedRag || isGlobal) {
      return _findVar(vars, joined)?.type;
    }
    final target = _findVar(vars, isInNodeRag ? joined : at(1));
    if (target == null) return VarType.string;
    if (isInNodeRag) return target.type;

    // Structured output (LLM structured_output, Start json_object with a schema, trigger-plugin objects).
    if (_truthy(_get(_get(target.children, 'schema'), 'properties'))) {
      if (sel.length == 2) return preferSchemaType && target.schemaType != null ? target.schemaType : VarType.object;
      Object? props = _get(target.children, 'schema');
      var type = VarType.string;
      for (var i = 0; i < sel.length - 2; i++) {
        if (!_truthy(props)) continue;
        final properties = _get(props, 'properties');
        if (properties == null) throw _JsTypeError('properties of ${sel.sublist(0, i + 2).join('.')} is undefined');
        props = _get(properties, sel[i + 2]);
        if (i == sel.length - 3) type = _structTypeToVarType(_get(props, 'type'));
      }
      return type;
    }

    Object? curr = vars;
    String? type = VarType.string;
    for (var i = 0; i < sel.length - 1; i++) {
      if (curr is List) curr = _findVar(curr.cast<DifyVar>(), sel[i + 1]);
      if (i == sel.length - 2) {
        final schemaType = curr is DifyVar ? curr.schemaType : null;
        type = preferSchemaType && schemaType != null ? schemaType : _typeOfJs(curr);
      } else {
        final t = _typeOfJs(curr);
        if (t == VarType.object || t == VarType.file) curr = _childrenOfJs(curr);
      }
    }
    return type;
  }

  /// `getIterationItemType` (variable/utils.ts).
  String _iterationItemType(List<String> sel) {
    final isSystem = _isSystemVar(sel);
    final isChatVar = sel.isNotEmpty && sel[0] == 'conversation';
    final vars = isSystem ? _startGroup() : _group(sel.isEmpty ? null : sel[0]);
    if (vars == null) return VarType.string;

    Object? arrayType = VarType.string;
    Object? curr = vars;
    if (isSystem || isChatVar) {
      arrayType = _findVar(vars, sel.join('.'))?.type;
    } else {
      for (var i = 1; i < sel.length; i++) {
        curr = curr is List ? _findVar(curr.cast<DifyVar>(), sel[i]) : const <DifyVar>[];
        if (i == sel.length - 1) {
          arrayType = _typeOfJs(curr);
        } else {
          final t = _typeOfJs(curr);
          if (t == VarType.object || t == VarType.file) curr = _childrenOfJs(curr) ?? const <DifyVar>[];
        }
      }
    }
    return switch (arrayType) {
      VarType.arrayString => VarType.string,
      VarType.arrayNumber => VarType.number,
      VarType.arrayBoolean => VarType.boolean,
      VarType.arrayObject => VarType.object,
      VarType.array => VarType.arrayObject,
      VarType.arrayFile => VarType.file,
      _ => VarType.string,
    };
  }

  /// `getLoopItemType` (variable/utils.ts); unlike the iteration variant, `array` items are `any` and a step into a
  /// non-list throws (`curr.find is not a function`).
  String _loopItemType(List<String> sel) {
    final isSystem = _isSystemVar(sel);
    final vars = isSystem ? _startGroup() : _group(sel.isEmpty ? null : sel[0]);
    if (vars == null) return VarType.string;

    Object? arrayType = VarType.string;
    Object? curr = vars;
    if (isSystem) {
      arrayType = _findVar(vars, sel.join('.'))?.type;
    } else {
      for (var i = 0; i < sel.length - 1; i++) {
        if (curr is List) {
          curr = _findVar(curr.cast<DifyVar>(), sel[i + 1]);
        } else if (curr != null) {
          throw const _JsTypeError('curr.find is not a function');
        }
        if (i == sel.length - 2) {
          arrayType = _typeOfJs(curr);
        } else {
          final t = _typeOfJs(curr);
          if (t == VarType.object || t == VarType.file) curr = _childrenOfJs(curr);
        }
      }
    }
    return switch (arrayType) {
      VarType.arrayString => VarType.string,
      VarType.arrayNumber => VarType.number,
      VarType.arrayObject => VarType.object,
      VarType.arrayBoolean => VarType.boolean,
      VarType.array => VarType.any,
      VarType.arrayFile => VarType.file,
      _ => VarType.string,
    };
  }

  /// `isSystemVar` (variable/utils.ts): `sys` first, or second.
  static bool _isSystemVar(List<String> sel) =>
      (sel.isNotEmpty && sel[0] == 'sys') || (sel.length > 1 && sel[1] == 'sys');

  static DifyVar? _findVar(List<DifyVar> vars, String? name) {
    for (final v in vars) {
      if (v.variable == name) return v;
    }
    return null;
  }

  /// `curr?.type` for whatever `curr` is (a var, a structured-output map, a list, undefined).
  static String? _typeOfJs(Object? curr) => switch (curr) {
    final DifyVar v => v.type,
    final Map m => _str(m['type']),
    _ => null,
  };

  static Object? _childrenOfJs(Object? curr) => switch (curr) {
    final DifyVar v => v.children,
    final Map m => m['children'],
    _ => null,
  };
}

/// One-shot form of [VarTypes.typeOf].
String? varTypeOf(
  List<String> selector, {
  required Node? Function(String id) lookup,
  Node? start,
  bool chatMode = false,
  List<DeclaredVar> environmentVariables = const [],
  List<DeclaredVar> conversationVariables = const [],
  Node? parent,
}) => VarTypes(
  lookup: lookup,
  start: start,
  chatMode: chatMode,
  environmentVariables: environmentVariables,
  conversationVariables: conversationVariables,
).typeOf(selector, parent: parent);
