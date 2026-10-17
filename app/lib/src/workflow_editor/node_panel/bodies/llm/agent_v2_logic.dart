/// Agent v2's pure logic, ported from Dify 1.17.1: nodes/agent-v2/types.ts (binding predicates), default.ts
/// (checkValid), output-variables.ts, components/agent-output-variables/utils.ts, the prompt editor's
/// agent-output-block/utils.ts (the `[§output:name:name§]` tokens) and panel.tsx's task / outputs sync. Outputs are
/// Dify's DeclaredOutputConfig JSON.
library;

import 'dart:async';
import 'dart:convert';

import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/node_config.dart' show Json;
import 'llm_config.dart' show jsonClone;
import 'panel_edit.dart' show jsMap;

// ---- types.ts ----------------------------------------------------------------------------------------------------

Json _binding(Json data) => jsMap(data['agent_binding']);
bool _nonEmpty(Object? s) => s is String && s.isNotEmpty;

/// `hasValidRosterAgentBinding`.
bool hasValidRosterAgentBinding(Json data) =>
    _binding(data)['binding_type'] == 'roster_agent' && _nonEmpty(_binding(data)['agent_id']);

/// `hasInlineAgentBinding`.
bool hasInlineAgentBinding(Json data) => _binding(data)['binding_type'] == 'inline_agent';

/// `hasValidInlineAgentBinding`.
bool hasValidInlineAgentBinding(Json data) =>
    hasInlineAgentBinding(data) &&
    _nonEmpty(_binding(data)['agent_id']) &&
    _nonEmpty(_binding(data)['current_snapshot_id']);

/// `needsInlineAgentBindingCreation`.
bool needsInlineAgentBindingCreation(Json data) => hasInlineAgentBinding(data) && !hasValidInlineAgentBinding(data);

/// `hasValidAgentBinding`.
bool hasValidAgentBinding(Json data) => hasValidInlineAgentBinding(data) || hasValidRosterAgentBinding(data);

// ---- default.ts --------------------------------------------------------------------------------------------------

/// `metaData.helpLinkUri`.
const agentV2HelpLinkUri = 'agent#new-agent';

/// `defaultValue`.
const Json agentV2DefaultValue = {
  'agent_binding': {'binding_type': 'inline_agent'},
  'agent_node_kind': 'dify_agent',
  'version': '2',
};

/// `checkValid`: "Agent is required" without a valid binding. [t] is Dify's `t(ns, key, params)`.
({bool isValid, String errorMessage}) checkValidAgentV2(
  Json payload,
  String Function(String ns, String key, [Map<String, Object?> params]) t,
) {
  if (!hasValidAgentBinding(payload)) {
    return (
      isValid: false,
      errorMessage: t('workflow', 'errorMsg.fieldRequired', {'field': t('workflow', 'nodes.agent.roster.label')}),
    );
  }
  return (isValid: true, errorMessage: '');
}

// ---- output-variables.ts -----------------------------------------------------------------------------------------

/// `agentV2SystemTextOutput`.
const Json agentV2SystemTextOutput = {
  'name': 'text',
  'type': 'string',
  'required': false,
  'description': 'Free-form text answer.',
};

/// `AGENT_V2_RESERVED_OUTPUT_NAMES`.
const agentV2ReservedOutputNames = {'text', 'switch', '_session'};

/// `getAgentV2CustomDeclaredOutputs`.
List<Json> getAgentV2CustomDeclaredOutputs(List<Object?> outputs) => [
  for (final o in outputs)
    if (o is Map && !agentV2ReservedOutputNames.contains(o['name'])) jsMap(o),
];

/// `normalizeAgentV2DeclaredOutputs`: `text` first, then the custom outputs.
List<Json> normalizeAgentV2DeclaredOutputs(List<Object?> outputs) => [
  agentV2SystemTextOutput,
  ...getAgentV2CustomDeclaredOutputs(outputs),
];

/// `getAgentV2DeclaredOutputs`.
List<Json> getAgentV2DeclaredOutputs(Json data) =>
    normalizeAgentV2DeclaredOutputs(jsList(data['agent_declared_outputs']));

// ---- agent-output-block/utils.ts ---------------------------------------------------------------------------------

final _tokenRegex = RegExp(r'\[§output:([^:§\]]+):([^:§\]]+)§\]');
final _legacyTokenRegex = RegExp(r'§output:([^:§\]]+):([^:§\]]+)§');

/// `getAgentOutputToken`.
String getAgentOutputToken(String name) => '[§output:$name:$name§]';

/// `extractAgentOutputNames`: the names of the output tokens in [text] (bracketed and legacy).
Set<String> extractAgentOutputNames(String text) => {
  for (final m in _tokenRegex.allMatches(text)) m[1]!,
  for (final m in _legacyTokenRegex.allMatches(text)) m[1]!,
};

/// `replaceAgentOutputName`: [oldName]'s tokens renamed to [nextName], each keeping its form.
String replaceAgentOutputName(String text, String oldName, String nextName) {
  String replace(Match m) {
    if (m[1] != oldName) return m[0]!;
    return m[0]!.startsWith('[') ? getAgentOutputToken(nextName) : '§output:$nextName:$nextName§';
  }

  return text.replaceAllMapped(_tokenRegex, replace).replaceAllMapped(_legacyTokenRegex, replace);
}

// ---- agent-output-variables/utils.ts -----------------------------------------------------------------------------

/// `OutputTypeOption`.
typedef OutputTypeOption = ({String value, String label, String type, String? arrayItemType});

/// `OUTPUT_TYPE_OPTIONS`.
const List<OutputTypeOption> outputTypeOptions = [
  (value: 'string', label: 'string', type: 'string', arrayItemType: null),
  (value: 'number', label: 'number', type: 'number', arrayItemType: null),
  (value: 'boolean', label: 'boolean', type: 'boolean', arrayItemType: null),
  (value: 'object', label: 'object', type: 'object', arrayItemType: null),
  (value: 'file', label: 'file', type: 'file', arrayItemType: null),
  (value: 'array[string]', label: 'array[string]', type: 'array', arrayItemType: 'string'),
  (value: 'array[number]', label: 'array[number]', type: 'array', arrayItemType: 'number'),
  (value: 'array[boolean]', label: 'array[boolean]', type: 'array', arrayItemType: 'boolean'),
  (value: 'array[object]', label: 'array[object]', type: 'array', arrayItemType: 'object'),
  (value: 'array[file]', label: 'array[file]', type: 'array', arrayItemType: 'file'),
];

/// `OUTPUT_NAME_PATTERN`.
final outputNamePattern = RegExp(r'^[a-z_]\w*$', caseSensitive: false);

/// `getOutputTypeOptionValue`.
String getOutputTypeOptionValue(Json output) {
  if (output['type'] != 'array') return jsKey(output['type']);
  final item = jsStr(jsGet(output['array_item'], 'type'));
  return 'array[${item == null || item.isEmpty ? 'object' : item}]';
}

/// `getOutputTypeOption`.
OutputTypeOption getOutputTypeOption(String value) =>
    outputTypeOptions.where((o) => o.value == value).firstOrNull ?? outputTypeOptions.first;

/// `OutputDraft`.
typedef OutputDraft = ({
  String defaultValue,
  String description,
  String name,
  bool required,
  String type,
  List<Json> children,
});

/// [d] with some fields changed.
OutputDraft draftWith(
  OutputDraft d, {
  String? defaultValue,
  String? description,
  String? name,
  bool? required,
  String? type,
}) => (
  defaultValue: defaultValue ?? d.defaultValue,
  description: description ?? d.description,
  name: name ?? d.name,
  required: required ?? d.required,
  type: type ?? d.type,
  children: d.children,
);

/// `EditingState`: which output (and child path / parent path for a new child) the editor edits.
typedef OutputEditingState = ({OutputDraft draft, int? outputIndex, List<int>? childPath, List<int>? parentPath});

String _outputDefaultValue(Json output) {
  if (!output.containsKey('failure_strategy')) return '';
  final v = jsGet(output['failure_strategy'], 'default_value');
  if (v == null) return '';
  if (v is String) return v;
  return jsonEncode(v);
}

/// `createDraft`.
OutputDraft createDraft([Json? output]) {
  if (output == null) {
    return (defaultValue: '', description: '', name: '', required: false, type: 'string', children: const []);
  }
  return (
    defaultValue: _outputDefaultValue(output),
    description: jsStr(output['description']) ?? '',
    name: jsKey(output['name']),
    required: output['required'] is bool ? output['required']! as bool : true,
    type: getOutputTypeOptionValue(output),
    children: getOutputChildren(output),
  );
}

Object? _coerceDefaultValue(String value, OutputTypeOption option) {
  final trimmed = value.trim();
  if (option.type == 'number') return num.tryParse(trimmed) ?? trimmed;
  if (option.type == 'boolean') return trimmed == 'true';
  if (option.type == 'object' || option.type == 'array') {
    try {
      return jsonDecode(trimmed);
    } on FormatException {
      return trimmed;
    }
  }
  return trimmed;
}

/// `createOutputFromDraft`.
Json createOutputFromDraft(OutputDraft draft, {bool includeDefaultValue = true}) {
  final option = getOutputTypeOption(draft.type);
  final output = <String, Object?>{'name': draft.name.trim(), 'type': option.type, 'required': draft.required};
  if (draft.description.trim().isNotEmpty) output['description'] = draft.description.trim();
  if (option.type == 'array') output['array_item'] = {'type': option.arrayItemType ?? 'object'};
  if (draft.children.isNotEmpty && draft.type == 'object') output['children'] = draft.children;
  if (draft.children.isNotEmpty && draft.type == 'array[object]') {
    output['array_item'] = {'type': 'object', 'children': draft.children};
  }
  if (option.type == 'file') output['file'] = {'extensions': <String>[], 'mime_types': <String>[]};
  if (includeDefaultValue && draft.defaultValue.trim().isNotEmpty) {
    output['failure_strategy'] = {
      'on_failure': 'default_value',
      'default_value': _coerceDefaultValue(draft.defaultValue, option),
    };
  }
  return output;
}

/// `createAgentOutputConfig` (agent-output-block/utils.ts).
Json createAgentOutputConfig(String name, String type) {
  final option = getOutputTypeOption(type);
  return {
    'name': name.trim(),
    'type': option.type,
    'required': false,
    if (option.type == 'array') 'array_item': {'type': option.arrayItemType ?? 'object'},
    if (option.type == 'file') 'file': {'extensions': <String>[], 'mime_types': <String>[]},
  };
}

/// `toDeclaredOutputChild`.
Json toDeclaredOutputChild(Json output) => {
  'name': output['name'],
  'type': output['type'],
  'required': output['required'],
  if (jsTruthy(output['description'])) 'description': output['description'],
  if (jsTruthy(output['file'])) 'file': output['file'],
  if (jsTruthy(output['children'])) 'children': output['children'],
  if (jsTruthy(output['array_item'])) 'array_item': output['array_item'],
};

List<Json> _children(Object? children) => [for (final c in jsList(children)) jsMap(c)];

/// `getOutputChildren`.
List<Json> getOutputChildren(Json output) {
  if (getOutputTypeOptionValue(output) == 'array[object]') return _children(jsGet(output['array_item'], 'children'));
  if (output['type'] == 'object') return _children(output['children']);
  return const [];
}

/// `canOutputHaveChildren`.
bool canOutputHaveChildren(Json output) {
  final t = getOutputTypeOptionValue(output);
  return t == 'object' || t == 'array[object]';
}

Json _withChildren(Json output, List<Json> children) {
  if (getOutputTypeOptionValue(output) == 'array[object]') {
    final item = {'type': 'object', ...jsMap(output['array_item'])};
    if (children.isEmpty) {
      item.remove('children');
    } else {
      item['children'] = children;
    }
    return {...output, 'array_item': item};
  }
  if (output['type'] == 'object') {
    final next = {...output};
    if (children.isEmpty) {
      next.remove('children');
    } else {
      next['children'] = children;
    }
    return next;
  }
  return output;
}

Json _updateChildrenAtPath(Json output, List<int> parentPath, List<Json> Function(List<Json>) updater) {
  if (parentPath.isEmpty) return _withChildren(output, updater(getOutputChildren(output)));
  final head = parentPath.first;
  return _withChildren(output, [
    for (final (i, c) in getOutputChildren(output).indexed)
      i == head ? _updateChildrenAtPath(c, parentPath.sublist(1), updater) : c,
  ]);
}

/// `getOutputChildrenAtPath`.
List<Json> getOutputChildrenAtPath(Json output, List<int> path) {
  Json? current;
  var children = getOutputChildren(output);
  for (final i in path) {
    if (i >= children.length) return getOutputChildren(output);
    current = children[i];
    children = getOutputChildren(current);
  }
  return current == null ? getOutputChildren(output) : getOutputChildren(current);
}

/// `insertOutputChildAtPath`.
Json insertOutputChildAtPath(Json output, List<int> parentPath, Json child) =>
    _updateChildrenAtPath(output, parentPath, (c) => [...c, child]);

/// `updateOutputChildAtPath`.
Json updateOutputChildAtPath(Json output, List<int> childPath, Json child) {
  if (childPath.isEmpty) return output;
  final index = childPath.last;
  return _updateChildrenAtPath(
    output,
    childPath.sublist(0, childPath.length - 1),
    (c) => [
      for (final (i, x) in c.indexed) i == index ? child : x,
    ],
  );
}

/// `deleteOutputChildAtPath`.
Json deleteOutputChildAtPath(Json output, List<int> childPath) {
  if (childPath.isEmpty) return output;
  final index = childPath.last;
  return _updateChildrenAtPath(
    output,
    childPath.sublist(0, childPath.length - 1),
    (c) => [
      for (final (i, x) in c.indexed)
        if (i != index) x,
    ],
  );
}

/// `getDefaultValueErrorKey`: the workflow i18n key of what is wrong with the draft's default value, or null.
String? getDefaultValueErrorKey(OutputDraft draft) {
  final trimmed = draft.defaultValue.trim();
  if (trimmed.isEmpty) return null;
  final option = getOutputTypeOption(draft.type);
  if (option.type == 'file' || option.arrayItemType == 'file') {
    return 'nodes.agent.outputVars.defaultValueFileUnsupported';
  }
  if (option.type == 'number' && num.tryParse(trimmed) == null) {
    return 'nodes.agent.outputVars.defaultValueNumberInvalid';
  }
  if (option.type == 'boolean' && trimmed != 'true' && trimmed != 'false') {
    return 'nodes.agent.outputVars.defaultValueBooleanInvalid';
  }
  if (option.type == 'object' || option.type == 'array') {
    Object? parsed;
    try {
      parsed = jsonDecode(trimmed);
    } on FormatException {
      return option.type == 'object'
          ? 'nodes.agent.outputVars.defaultValueObjectInvalid'
          : 'nodes.agent.outputVars.defaultValueArrayInvalid';
    }
    if (option.type == 'object' && parsed is! Map) return 'nodes.agent.outputVars.defaultValueObjectInvalid';
    if (option.type == 'array' && parsed is! List) return 'nodes.agent.outputVars.defaultValueArrayInvalid';
  }
  return null;
}

/// `isDefaultOutput`: the system `text` output.
bool isDefaultOutput(Json output) =>
    output['name'] == 'text' && output['type'] == 'string' && getOutputTypeOptionValue(output) == 'string';

/// `getOutputDisplayType`.
String getOutputDisplayType(Json output) => getOutputTypeOption(getOutputTypeOptionValue(output)).label;

// ---- panel.tsx: task <-> outputs ---------------------------------------------------------------------------------

/// A one-for-one token swap (one removed, one added, neither reserved): a rename from → to.
({String from, String to})? _tokenRename(Set<String> before, Set<String> after) {
  final removed = before.difference(after), added = after.difference(before);
  if (removed.length != 1 || added.length != 1) return null;
  final from = removed.single, to = added.single;
  if (agentV2ReservedOutputNames.contains(from) || agentV2ReservedOutputNames.contains(to)) return null;
  return (from: from, to: to);
}

/// handleTaskChange: [inputs] with `agent_task` = [value]. An output token taken out of the task deletes its custom
/// output, or renames it when exactly one token was swapped for one other. [promptOutputNames] are the names in the
/// task before (Dify's promptOutputNamesRef). Returns the next data and whether the outputs changed.
({Json inputs, bool outputsChanged}) agentTaskChange(Json inputs, String value, Set<String> promptOutputNames) {
  final current = extractAgentOutputNames(value);
  final removed = promptOutputNames.difference(current);
  final next = jsonClone(inputs)..['agent_task'] = value;
  if (removed.isEmpty) return (inputs: next, outputsChanged: false);
  final outputs = getAgentV2CustomDeclaredOutputs(jsList(next['agent_declared_outputs']));
  final rename = _tokenRename(promptOutputNames, current);
  next['agent_declared_outputs'] = rename != null
      ? [
          for (final o in outputs) o['name'] == rename.from ? {...o, 'name': rename.to} : o,
        ]
      : [
          for (final o in outputs)
            if (!removed.contains(o['name'])) o,
        ];
  return (inputs: next, outputsChanged: true);
}

/// handleDeclaredOutputsChange: [inputs] with the custom part of [outputs] (and [agentTask] when given). When the new
/// task swaps one token for another, the new output takes the old one's place; when only the list renamed one output
/// that the task references, the task's tokens follow. Returns the next data and the full output list (with `text`).
({Json inputs, List<Json> outputs}) agentDeclaredOutputsChange(
  Json inputs,
  List<Json> outputs, {
  String? agentTask,
  required Set<String> promptOutputNames,
}) {
  final previous = getAgentV2DeclaredOutputs(inputs);
  var nextTask = agentTask;
  var nextOutputs = normalizeAgentV2DeclaredOutputs(outputs);
  if (agentTask != null) {
    final rename = _tokenRename(promptOutputNames, extractAgentOutputNames(agentTask));
    if (rename != null) {
      final oldIndex = previous.indexWhere((o) => o['name'] == rename.from);
      final nextOutput = nextOutputs.where((o) => o['name'] == rename.to).firstOrNull;
      if (oldIndex >= 0 && nextOutput != null) {
        nextOutputs = [for (final (i, o) in previous.indexed) i == oldIndex ? nextOutput : o];
      }
    }
  }
  if (nextTask == null && previous.length == nextOutputs.length) {
    final renamed = [
      for (final (i, p) in previous.indexed)
        if (nextOutputs[i]['name'] != null && nextOutputs[i]['name'] != p['name'])
          (old: jsKey(p['name']), next: jsKey(nextOutputs[i]['name'])),
    ];
    if (renamed.length == 1) {
      final task = jsStr(inputs['agent_task']) ?? '';
      if (extractAgentOutputNames(task).contains(renamed.single.old)) {
        nextTask = replaceAgentOutputName(task, renamed.single.old, renamed.single.next);
      }
    }
  }
  final next = jsonClone(inputs)..['agent_declared_outputs'] = getAgentV2CustomDeclaredOutputs(nextOutputs);
  if (nextTask != null) next['agent_task'] = nextTask;
  return (inputs: next, outputs: nextOutputs);
}

// ---- hooks.ts useWorkflowInlineAgentDetail -----------------------------------------------------------------------

/// `INLINE_AGENT_CREATION_REFETCH_INTERVAL` / `INLINE_AGENT_CREATION_RETRY_COUNT`.
const inlineAgentRefetchInterval = Duration(milliseconds: 1000);
const inlineAgentRetryCount = 5;

/// The inline agent composer query (useWorkflowInlineAgentDetail with `pollUntilReady`): loads through [fetch];
/// while polling, a result without `agent` is fetched again every second; a failed load is retried five times,
/// then the query is in error and stops polling.
class InlineAgentQuery {
  InlineAgentQuery({required this.fetch, required this.onChange});

  final Future<Json?> Function() fetch;
  final void Function() onChange;

  Json? data;
  bool isError = false, isFetching = false, isPending = true;
  bool pollUntilReady = false;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  Future<void> refetch() => _load(++_generation, 0);

  Future<void> _load(int gen, int attempt) async {
    _timer?.cancel();
    isFetching = true;
    onChange();
    Json? result;
    var failed = false;
    try {
      result = await fetch();
    } on Object {
      failed = true;
    }
    if (_disposed || gen != _generation) return;
    if (failed) {
      if (pollUntilReady && attempt < inlineAgentRetryCount) return _load(gen, attempt + 1);
      isError = true;
      isFetching = false;
      isPending = data == null;
      onChange();
      return;
    }
    data = result;
    isError = false;
    isFetching = false;
    isPending = false;
    onChange();
    if (pollUntilReady && jsGet(result, 'agent') == null) {
      _timer = Timer(inlineAgentRefetchInterval, () => _load(gen, 0));
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
