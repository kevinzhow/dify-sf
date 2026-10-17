/// What the variable reference picker works on, and its pure helpers: ported from Dify 1.17.1
/// `nodes/_base/components/variable/var-reference-picker.helpers.ts`, `var-reference-vars.helpers.ts`, `utils.ts`
/// (`removeFileVars`, `varTypeToStructType`, `isSpecialVar`) and `web/utils/var.ts` (`checkKey(s)`).
library;

import 'package:collab_client/collab_client.dart';

import '../../cards/variable_label.dart';
import '../../workflow/var_types.dart';

/// A variable the picker lists (Dify's `Var`): [children] is a `List<PickerVar>` (object / file members) or a
/// structured-output map `{schema: {type, properties}}` (plain JSON).
final class PickerVar {
  const PickerVar(
    this.variable,
    this.type, {
    this.children,
    this.schemaType,
    this.des,
    this.isException = false,
    this.isRagVariable = false,
  });

  /// One of the app's computed variables (output_vars.dart).
  factory PickerVar.of(DifyVar v) => PickerVar(
    v.variable,
    v.type,
    children: switch (v.children) {
      final List<Object?> list => [for (final c in list.whereType<DifyVar>()) PickerVar.of(c)],
      final other => other,
    },
    schemaType: v.schemaType,
    isException: v.isException,
    isRagVariable: v.variable.startsWith('rag.'),
  );

  final String variable;
  final String? type;
  final Object? children;
  final String? schemaType;
  final String? des;
  final bool isException;
  final bool isRagVariable;

  List<PickerVar> get childVars => children is List<PickerVar> ? children as List<PickerVar> : const [];

  /// The structured-output schema's `properties`, when [children] is one.
  Map<String, Object?>? get schemaProperties => switch (children) {
    {'schema': {'properties': final Map<String, Object?> p}} => p,
    _ => null,
  };

  @override
  String toString() => 'PickerVar($variable: $type)';
}

/// One group of the picker (Dify's `NodeOutPutVar`): a node's variables, or ENVIRONMENT, CONVERSATION, SYSTEM, ...
/// [isFlat] groups (the code generator's `current`, ...) have no title row; [isLoop] marks a loop's variables.
final class VarGroup {
  const VarGroup({
    required this.nodeId,
    required this.title,
    required this.vars,
    this.isStartNode = false,
    this.isFlat = false,
    this.isLoop = false,
  });

  factory VarGroup.of(NodeOutputVars g) => VarGroup(
    nodeId: g.nodeId,
    title: g.title,
    vars: [for (final v in g.vars) PickerVar.of(v)],
    isStartNode: g.isStartNode,
  );

  final String nodeId, title;
  final List<PickerVar> vars;
  final bool isStartNode, isFlat, isLoop;

  VarGroup withVars(List<PickerVar> vars) =>
      VarGroup(nodeId: nodeId, title: title, vars: vars, isStartNode: isStartNode, isFlat: isFlat, isLoop: isLoop);
}

/// Dify's `filterVar(payload, valueSelector)`.
typedef VarFilter = bool Function(PickerVar v, List<String> selector);

/// Everything a picker needs about the workflow around the node it edits: the variables on offer ([vars], Dify's
/// `availableVars`), the nodes they come from ([lookup], `availableNodes`; [start] for system variables), the
/// iteration / loop the node sits in ([parent]) and the type shown for a selected variable ([typeOf],
/// `getCurrentVariableType`). [validateSpecialVars] is Dify's `isWorkflowDataLoaded`: env / conversation / rag
/// selectors are checked against [vars].
final class VarScope {
  const VarScope({
    this.vars = const [],
    this.lookup = _none,
    this.start,
    this.parent,
    this.typeOf,
    this.validateSpecialVars = true,
  });

  /// The scope of a node whose upstream nodes are [beforeNodes] (with [parent], its container) as Dify's
  /// `useAvailableVarList` builds it: `toNodeAvailableVars` for the list, `getVarType` for the shown type.
  factory VarScope.of({
    required List<Node> beforeNodes,
    Node? parent,
    bool chatMode = false,
    List<DeclaredVar> environmentVariables = const [],
    List<DeclaredVar> conversationVariables = const [],
    List<RagVariable> ragVariables = const [],
    String currentIterationTitle = 'Current Iteration',
  }) {
    final byId = {
      for (final n in [...beforeNodes, ?parent]) n.id: n,
    };
    final start = beforeNodes.where((n) => n.type == 'start').firstOrNull;
    final types = VarTypes(
      lookup: (id) => byId[id],
      start: start,
      chatMode: chatMode,
      environmentVariables: environmentVariables,
      conversationVariables: conversationVariables,
      ragVariables: ragVariables,
    );
    return VarScope(
      vars: [
        for (final g in toNodeAvailableVars(
          beforeNodes: beforeNodes,
          parent: parent,
          chatMode: chatMode,
          environmentVariables: environmentVariables,
          conversationVariables: conversationVariables,
          ragVariables: ragVariables,
          currentIterationTitle: currentIterationTitle,
        ))
          VarGroup.of(g),
      ],
      lookup: (id) => byId[id],
      start: start,
      parent: parent,
      typeOf: (sel) => types.typeOf(sel, parent: parent),
    );
  }

  static Node? _none(String _) => null;

  final List<VarGroup> vars;
  final Node? Function(String id) lookup;
  final Node? start;
  final Node? parent;
  final String? Function(List<String> selector)? typeOf;
  final bool validateSpecialVars;

  VarScope _withVars(List<VarGroup> vars) => VarScope(
    vars: vars,
    lookup: lookup,
    start: start,
    parent: parent,
    typeOf: typeOf,
    validateSpecialVars: validateSpecialVars,
  );

  /// Keeps the variables [filter] accepts (an object or file stays, with only its accepted members, when any member
  /// is accepted), dropping groups left empty.
  VarScope filtered(VarFilter filter) {
    List<PickerVar> keep(List<PickerVar> vars, List<String> path) => [
      for (final v in vars)
        if (filter(v, [...path, ...v.variable.split('.')]))
          v
        else if (v.childVars.isNotEmpty)
          if (keep(v.childVars, [...path, v.variable]) case final kids when kids.isNotEmpty)
            PickerVar(
              v.variable,
              v.type,
              children: kids,
              schemaType: v.schemaType,
              des: v.des,
              isException: v.isException,
              isRagVariable: v.isRagVariable,
            ),
    ];
    return _withVars([
      for (final g in vars)
        if (keep(g.vars, isSpecialVar(g.nodeId) || g.nodeId == 'global' ? const [] : [g.nodeId]) case final kept
            when kept.isNotEmpty)
          g.withVars(kept),
    ]);
  }

  /// `removeFileVars`: without `file` and `array[file]` variables.
  VarScope withoutFileVars() => _withVars(removeFileVars(vars));
}

/// `removeFileVars` (variable/utils.ts).
List<VarGroup> removeFileVars(List<VarGroup> groups) => [
  for (final g in groups)
    if (g.vars.where((v) => v.type != VarType.file && v.type != VarType.arrayFile).toList() case final vars
        when vars.isNotEmpty)
      g.withVars(vars),
];

/// `isSpecialVar` (variable/utils.ts).
bool isSpecialVar(String prefix) => const ['sys', 'env', 'conversation', 'rag'].contains(prefix);

/// `varTypeToStructType` (variable/utils.ts): the JSON-schema type of a VarType (`array[...]` is `array`).
String varTypeToStructType(String? type) =>
    const {
      VarType.string: 'string',
      VarType.number: 'number',
      VarType.boolean: 'boolean',
      VarType.object: 'object',
      VarType.array: 'array',
      VarType.arrayString: 'array',
      VarType.arrayNumber: 'array',
      VarType.arrayObject: 'array',
      VarType.arrayFile: 'array',
    }[type] ??
    'string';

/// `getFieldType` (llm/utils.ts): a schema field's type as shown (`file`, `enum`, `array[<items>]`).
String fieldTypeOf(Map<String, Object?> field) {
  final type = field['type'] as String? ?? 'string';
  if (field['schemaType'] == 'file') return 'file';
  if (field['enum'] case final List<Object?> e when e.isNotEmpty) return 'enum';
  if (type != 'array' || field['items'] is! Map) return type;
  return 'array[${(field['items'] as Map)['type']}]';
}

// ---- web/utils/var.ts -----------------------------------------------------------------------------------------

/// MAX_VAR_KEY_LENGTH (config).
const maxVarKeyLength = 30;

/// `checkKey`: null when valid, else the `appDebug` `varKeyError.<key>` that applies.
String? checkKey(String key, {bool canBeEmpty = false}) {
  if (key.isEmpty && !canBeEmpty) return 'canNoBeEmpty';
  if (canBeEmpty && key.isEmpty) return null;
  if (key.length > maxVarKeyLength) return 'tooLong';
  if (RegExp(r'^\w+$').hasMatch(key)) return RegExp(r'\d').hasMatch(key[0]) ? 'notStartWithNumber' : null;
  return 'notValid';
}

/// `checkKeys`: the first invalid key and its error, or null.
({String key, String error})? checkKeys(List<String> keys, {bool canBeEmpty = false}) {
  for (final k in keys) {
    final e = checkKey(k, canBeEmpty: canBeEmpty);
    if (e != null) return (key: k, error: e);
  }
  return null;
}

// ---- var-reference-picker.helpers.ts --------------------------------------------------------------------------

/// The picker's two modes (tool/types.ts `VarType`): a variable reference or a constant typed in.
enum VarKindType { variable, constant }

/// `getVarKindOptions`.
List<({String label, VarKindType value})> varKindOptions({
  String variable = 'Variable',
  String constant = 'Constant',
}) => [(label: variable, value: VarKindType.variable), (label: constant, value: VarKindType.constant)];

/// `getHasValue`.
bool pickerHasValue(bool isConstant, List<String> value) => !isConstant && value.isNotEmpty;

/// `getIsIterationVar` / `getIsLoopVar`: `item` / `index` of the container [parentId].
bool isContainerVar(bool inContainer, List<String> value, String? parentId) =>
    inContainer && value.length > 1 && value[0] == parentId && const ['item', 'index'].contains(value[1]);

/// `getOutputVarNode`: the node a selected variable comes from (Start for system variables, the container for its
/// item / index), or null.
Node? outputVarNodeOf({
  required bool hasValue,
  required bool isConstant,
  required List<String> value,
  required Node? Function(String id) lookup,
  bool isIterationVar = false,
  bool isLoopVar = false,
  Node? iterationNode,
  Node? loopNode,
  Node? startNode,
}) {
  if (!hasValue || isConstant) return null;
  if (isIterationVar) return iterationNode;
  if (isLoopVar) return loopNode;
  if (isSystemVar(value)) return startNode;
  return lookup(value.first);
}

/// `getVarDisplayName`: `query` / `files` for sys.query / sys.files, else the last segment (`sys.` in front of
/// system variables).
String pickerVarDisplayName(bool hasValue, List<String> value) {
  if (!hasValue) return '';
  const showName = {'sys.query': 'query', 'sys.files': 'files'};
  final shown = showName[value.join('.')];
  if (shown != null) return shown;
  return '${isSystemVar(value) ? 'sys.' : ''}${value.isEmpty ? '' : value.last}';
}

/// `getVariableMeta`: what kind of variable [value] is and whether it still exists. Special variables (env,
/// conversation, rag) are valid when [canValidateSpecialVars] is false or [availableVars] has them.
({bool isEnv, bool isChatVar, bool isGlobal, bool isRagVar, bool isValidVar, bool isException}) pickerVariableMeta(
  String? outputVarNodeType,
  List<String> value,
  String varName, {
  List<VarGroup> availableVars = const [],
  bool canValidateSpecialVars = false,
  bool hasOutputVarNode = false,
}) {
  final isEnv = isEnvVar(value), isChat = isConversationVar(value), isGlobal = isGlobalVar(value);
  final isRag = isRagVariableVar(value);
  final joined = value.join('.');
  final hasSpecial = !canValidateSpecialVars || availableVars.any((g) => g.vars.any((v) => v.variable == joined));
  return (
    isEnv: isEnv,
    isChatVar: isChat,
    isGlobal: isGlobal,
    isRagVar: isRag,
    isValidVar: hasOutputVarNode || isGlobal || ((isEnv || isChat || isRag) && hasSpecial),
    isException: varName.isNotEmpty && outputVarNodeType != null,
  );
}

/// `getVariableCategory` (var-reference-picker.helpers.ts).
String pickerVariableCategory({
  bool isChatVar = false,
  bool isEnv = false,
  bool isGlobal = false,
  bool isLoopVar = false,
  bool isRagVar = false,
}) {
  if (isEnv) return 'environment';
  if (isChatVar) return 'conversation';
  if (isGlobal) return 'global';
  if (isLoopVar) return 'loop';
  if (isRagVar) return 'rag';
  return 'system';
}

/// `getWidthAllocations`: how the trigger's width (less 56 px of chrome) is shared between node title, variable
/// name and type, by text length.
({int maxNodeNameWidth, int maxTypeWidth, int maxVarNameWidth}) pickerWidthAllocations(
  double triggerWidth,
  String nodeTitle,
  String varName,
  String type,
) {
  final available = triggerWidth - 56;
  final joined = nodeTitle + varName + type;
  final total = joined.isEmpty ? 1 : joined.length;
  final priority = nodeTitle.isNotEmpty ? 15 : 0;
  final minVarName = varName.isNotEmpty ? 16 : 0;
  return (
    maxNodeNameWidth: priority + (nodeTitle.length / total * available).floor(),
    maxTypeWidth: (type.length / total * available).floor(),
    maxVarNameWidth: [minVarName, -priority + (varName.length / total * available).floor()].reduce(
      (a, b) => a > b ? a : b,
    ),
  );
}

/// What the trigger shows on hover: the full path of a nested variable, or "invalid variable".
enum PickerHover { fullPath, invalidVariable }

/// `getTooltipContent`.
PickerHover? pickerTooltipContent(bool hasValue, bool isShowAPart, bool isValidVar) {
  if (isValidVar && isShowAPart) return PickerHover.fullPath;
  if (!isValidVar && hasValue) return PickerHover.invalidVariable;
  return null;
}

/// `getOutputVarNodeId`.
String pickerOutputVarNodeId(bool hasValue, List<String> value) => hasValue && value.isNotEmpty ? value.first : '';

/// `isShowAPartSelector`: a nested path (more than two segments, not rag).
bool isShowAPartSelector(List<String> value) => value.length > 2 && !isRagVariableVar(value);

/// A constant field's form (CredentialFormSchema's `type` and `options`): `text-input`, `number-input`, `select`,
/// `dynamic-select`, ...
final class ConstantSchema {
  const ConstantSchema({required this.type, this.options = const []});
  final String type;
  final List<({String value, String label})> options;

  ConstantSchema withOptions(List<({String value, String label})> options) =>
      ConstantSchema(type: type, options: options);
}

/// `getDynamicSelectSchema`: a dynamic select gets the fetched options; while loading, the current value alone.
ConstantSchema? dynamicSelectSchema({
  required List<({String value, String label})>? dynamicOptions,
  required bool isLoading,
  required ConstantSchema? schema,
  required String value,
}) {
  if (schema?.type != 'dynamic-select') return schema;
  if (dynamicOptions != null) return schema!.withOptions(dynamicOptions);
  if (isLoading && value.isNotEmpty) return schema!.withOptions([(value: value, label: value)]);
  return schema!.withOptions(const []);
}

/// `handleVarReferenceChange`: system variables are stored without their node (`[node, 'sys.query']` becomes
/// `['sys', 'query']`).
List<String> normalizeSysSelector(List<String> value) {
  if (value.length > 1 && value[1].startsWith('sys.')) return [...value[1].split('.'), ...value.skip(2)];
  return value;
}

// ---- var-reference-vars.helpers.ts ----------------------------------------------------------------------------

/// `getVariableDisplayName`.
String varsDisplayName(String variable, bool isFlat, {bool isInCodeGeneratorInstructionEditor = false}) {
  const showName = {'sys.query': 'query', 'sys.files': 'files'};
  if (showName[variable] case final s?) return s;
  if (!isFlat) return variable;
  if (variable == 'current') return isInCodeGeneratorInstructionEditor ? 'current_code' : 'current_prompt';
  return variable;
}

/// `getVariableCategory` (var-reference-vars.helpers.ts).
String varsVariableCategory({
  required bool isEnv,
  required bool isChatVar,
  bool isLoopVar = false,
  bool isRagVariable = false,
}) {
  if (isEnv) return 'environment';
  if (isChatVar) return 'conversation';
  if (isLoopVar) return 'loop';
  if (isRagVariable) return 'rag';
  return 'system';
}

/// `getValueSelector`: the selector choosing [item] gives, or null (a file when files are not supported).
List<String>? varsValueSelector({
  required PickerVar item,
  bool isFlat = false,
  bool isSupportFileVar = false,
  required bool isFile,
  required bool isSys,
  required bool isEnv,
  required bool isChatVar,
  bool isRagVariable = false,
  required String nodeId,
  required List<String> objPath,
}) {
  if (!isSupportFileVar && isFile) return null;
  if (isFlat) return [item.variable];
  if (isSys || isEnv || isChatVar || isRagVariable) return [...objPath, ...item.variable.split('.')];
  return [nodeId, ...objPath, item.variable];
}

/// `resolveValueSelector` (var-reference-vars.tsx): [varsValueSelector] with the flags read off [item].
List<String>? resolveValueSelector(
  PickerVar item, {
  bool isFlat = false,
  bool isSupportFileVar = false,
  required String nodeId,
  List<String> objPath = const [],
}) {
  final isStructured = item.type == VarType.object && item.schemaProperties != null;
  return varsValueSelector(
    item: item,
    isFlat: isFlat,
    isSupportFileVar: isSupportFileVar,
    isFile: item.type == VarType.file && !isStructured,
    isSys: item.variable.startsWith('sys.'),
    isEnv: item.variable.startsWith('env.'),
    isChatVar: item.variable.startsWith('conversation.'),
    isRagVariable: item.isRagVariable,
    nodeId: nodeId,
    objPath: objPath,
  );
}

List<PickerVar> _visible(List<PickerVar> vars) => [
  for (final v in vars)
    if (checkKey(v.variable) == null || isSpecialVar(v.variable.split('.').first)) v,
];

bool _has(String? s, String q) => s != null && s.toLowerCase().contains(q);

bool _matchesField(String name, Object? field, String q) {
  if (_has(name, q)) return true;
  if (field is! Map) return false;
  if (field['properties'] case final Map<String, Object?> props) {
    return props.entries.any((e) => _matchesField(e.key, e.value, q));
  }
  if (field['items'] case final Map items) return _matchesField('${items['type']}', items, q);
  return false;
}

bool _matches(PickerVar v, String q) {
  if (_has(v.variable, q) || _has(v.des, q) || _has(v.schemaType, q)) return true;
  if (v.children is List<PickerVar>) return _visible(v.childVars).any((c) => _matches(c, q));
  if (v.schemaProperties case final props?) return props.entries.any((e) => _matchesField(e.key, e.value, q));
  return false;
}

/// `filterReferenceVars`: variables with valid names only, then those matching [searchText] (in name, description,
/// schema type or any member); a group whose title matches keeps all its variables.
List<VarGroup> filterReferenceVars(List<VarGroup> vars, String searchText) {
  final q = searchText.toLowerCase();
  return [
    for (final g in vars)
      if (_visible(g.vars) case final visible when visible.isNotEmpty)
        if (q.isEmpty || g.title.toLowerCase().contains(q))
          g.withVars(visible)
        else if (visible.where((v) => _matches(v, q)).toList() case final hits when hits.isNotEmpty)
          g.withVars(hits),
  ];
}
