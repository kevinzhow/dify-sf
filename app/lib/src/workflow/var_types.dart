/// The type Dify shows after a variable reference (e.g. the End node's `VariableLabelInNode variableType=...`) and the
/// variables a picker offers, ported from Dify 1.17.1 `web/app/components/workflow/nodes/_base/components/variable/
/// utils.ts` (`getVarType`, `toNodeOutputVars`, `toNodeAvailableVars`, `getIterationItemType`, `getLoopItemType`).
/// The per-node outputs (`formatItem`) are in output_vars.dart, `getNodeUsedVars` / `updateNodeVars` in
/// node_used_vars.dart.
///
/// Pure Dart. The port works on plain JSON (the node config converted with [plainOf]) so Dify's JavaScript semantics
/// can be mirrored one to one, quirks included. Where Dify would throw while rendering (it reads a property of
/// `undefined`), [VarTypes.typeOf] returns null.
library;

import 'package:collab_client/collab_client.dart';

import 'dify_json.dart';
import 'output_vars.dart';

export 'dify_json.dart' show plainOf, selectorOf;
export 'node_used_vars.dart';
export 'output_vars.dart';

// ---- inputs ------------------------------------------------------------------------------------------------------

/// An environment or conversation variable declaration (the workflow's `environment_variables` /
/// `conversation_variables`: `{name, value_type, ...}`).
final class DeclaredVar {
  const DeclaredVar(this.name, this.valueType);

  final String name;
  final String? valueType;

  /// Parses Dify's declaration list, as a [Value] (keyed or atomic list of maps) or plain JSON.
  static List<DeclaredVar> listOf(Object? declarations) => [
    for (final d in jsList(declarations is Value ? plainOf(declarations) : declarations))
      if (d is Map && d['name'] is String) DeclaredVar(d['name'] as String, jsStr(d['value_type'])),
  ];
}

/// The label text Dify renders for a type (variable-label/base/variable-label.tsx: es-toolkit `capitalize`, which
/// also lower-cases the rest): `array[file]` -> `Array[file]`. Null or empty: no label.
String? varTypeLabel(String? type) =>
    (type == null || type.isEmpty) ? null : type[0].toUpperCase() + type.substring(1).toLowerCase();

/// `structTypeToVarType` (variable/utils.ts), as getVarType calls it (never with `isArray`): JSON-schema `integer`,
/// `file`, `enum` and unknown types are `string`; arrays are plain `array`.
String _structTypeToVarType(Object? type) =>
    const {
      'string': VarType.string,
      'number': VarType.number,
      'boolean': VarType.boolean,
      'object': VarType.object,
      'array': VarType.array,
    }[jsKey(type)] ??
    VarType.string;

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
    } on JsTypeError {
      return null;
    }
  }

  /// The variables a node offers (`formatItem` in variable/utils.ts, as toNodeOutputVars calls it), or null when Dify
  /// would list none: an unsupported node type or no variables. Throws [StateError] where Dify's own code throws.
  List<DifyVar>? outputVarsOf(Node node) {
    try {
      return _nodeVars(node);
    } on JsTypeError catch (e) {
      throw StateError('Dify cannot format ${node.id}: $e');
    }
  }

  /// `toNodeOutputVars` (variable/utils.ts) with its always-true `filterVar`, for the available [nodes]: one entry
  /// per node with variables, most recent (largest x) first and the Start node last, then ENVIRONMENT, CONVERSATION,
  /// SYSTEM and SHARED INPUTS. Throws [StateError] where Dify's own code throws.
  List<NodeOutputVars> toNodeOutputVars(List<Node> nodes) {
    // Dify's comparator puts Start after everything and orders the rest by x, descending; its sort is stable.
    final sorted = nodes.indexed.toList()
      ..sort((a, b) {
        final byStart = (a.$2.type == 'start' ? 1 : 0) - (b.$2.type == 'start' ? 1 : 0);
        if (byStart != 0) return byStart;
        final byX = b.$2.x.compareTo(a.$2.x);
        return byX != 0 ? byX : a.$1.compareTo(b.$1);
      });
    return [
      for (final (_, node) in sorted)
        if (outputVarsOf(node) case final vars?)
          NodeOutputVars(node.id, node.title, vars, isStartNode: node.type == 'start'),
      for (final (id, title) in const [
        ('env', 'ENVIRONMENT'),
        ('conversation', 'CONVERSATION'),
        ('global', 'SYSTEM'),
        ('rag', 'SHARED INPUTS'),
      ])
        if (_specialVars(id) case final vars?) NodeOutputVars(id, title, vars),
    ];
  }

  List<DifyVar>? _nodeVars(Node node) {
    if (!supportOutputVarsNode.contains(node.type)) return null;
    final vars = formatItem(node.id, difyDataOf(node), chatMode: chatMode, ragVariables: ragVariables);
    return vars.isEmpty ? null : vars;
  }

  /// `beforeNodesOutputVars.find((v) => v.nodeId === id)?.vars`.
  List<DifyVar>? _group(String? id) {
    if (id == null) return null;
    if (_cache.containsKey(id)) return _cache[id];
    final node = lookup(id);
    return _cache[id] = (node == null ? null : _nodeVars(node)) ?? _specialVars(id);
  }

  /// The ENV, CONVERSATION, SYSTEM and SHARED INPUTS entries of toNodeOutputVars; null when absent or empty.
  List<DifyVar>? _specialVars(String id) {
    final vars = switch (id) {
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
    return vars == null || vars.isEmpty ? null : vars;
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
    if (jsTruthy(jsGet(jsGet(target.children, 'schema'), 'properties'))) {
      if (sel.length == 2) return preferSchemaType && target.schemaType != null ? target.schemaType : VarType.object;
      Object? props = jsGet(target.children, 'schema');
      var type = VarType.string;
      for (var i = 0; i < sel.length - 2; i++) {
        if (!jsTruthy(props)) continue;
        final properties = jsGet(props, 'properties');
        if (properties == null) throw JsTypeError('properties of ${sel.sublist(0, i + 2).join('.')} is undefined');
        props = jsGet(properties, sel[i + 2]);
        if (i == sel.length - 3) type = _structTypeToVarType(jsGet(props, 'type'));
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
          throw const JsTypeError('curr.find is not a function');
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
    final Map m => jsStr(m['type']),
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

/// One entry of Dify's variable lists (`NodeOutPutVar`): the variables of one node, or of ENVIRONMENT, CONVERSATION,
/// SYSTEM, SHARED INPUTS (node ids `env`, `conversation`, `global`, `rag`), or of the current iteration.
final class NodeOutputVars {
  const NodeOutputVars(this.nodeId, this.title, this.vars, {this.isStartNode = false});

  final String nodeId;
  final String title;
  final List<DifyVar> vars;
  final bool isStartNode;

  @override
  String toString() => 'NodeOutputVars($nodeId: $vars)';
}

/// `toNodeAvailableVars` (variable/utils.ts) with an always-true `filterVar`: the variables a picker offers from
/// [beforeNodes], led, inside an iteration ([parent]), by its `item` and `index`. [currentIterationTitle] is the
/// translated `nodes.iteration.currentIteration` (en-US by default). Throws [StateError] where Dify's own code throws.
List<NodeOutputVars> toNodeAvailableVars({
  required List<Node> beforeNodes,
  Node? parent,
  bool chatMode = false,
  List<DeclaredVar> environmentVariables = const [],
  List<DeclaredVar> conversationVariables = const [],
  List<RagVariable> ragVariables = const [],
  bool inWorkflowPage = true,
  String currentIterationTitle = 'Current Iteration',
}) {
  final byId = <String, Node>{};
  for (final n in beforeNodes) {
    byId.putIfAbsent(n.id, () => n);
  }
  final types = VarTypes(
    lookup: (id) => byId[id],
    start: beforeNodes.where((n) => n.type == 'start').firstOrNull,
    chatMode: chatMode,
    environmentVariables: environmentVariables,
    conversationVariables: conversationVariables,
    ragVariables: ragVariables,
    inWorkflowPage: inWorkflowPage,
  );
  final vars = types.toNodeOutputVars(beforeNodes);
  if (parent?.type != 'iteration') return vars;

  final itemType = types.typeOf(
    selectorOf(parent!.config['iterator_selector']) ?? const [],
    parent: parent,
    isIterationItem: true,
  );
  final replaced = vars.indexWhere((v) => v.nodeId == parent.id);
  return [
    NodeOutputVars(parent.id, currentIterationTitle, [
      DifyVar(
        'item',
        itemType,
        children: itemType == VarType.file
            ? [for (final k in outputFileSubVariables) DifyVar(k, k == 'size' ? VarType.number : VarType.string)]
            : null,
      ),
      const DifyVar('index', VarType.number),
    ]),
    for (final (i, v) in vars.indexed)
      if (i != replaced) v,
  ];
}
