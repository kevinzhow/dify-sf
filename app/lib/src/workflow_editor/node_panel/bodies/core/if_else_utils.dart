/// The IF/ELSE node's pure logic (nodes/if-else/utils.ts, use-config.helpers.ts, use-config.ts, nodes/constants.ts):
/// operators by variable type, branch names, and the edits of cases and conditions on the node's Dify data.
library;

import 'dart:math';

import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../panel_fields/panel_fields.dart';

// ---- utils.ts ----------------------------------------------------------------------------------------------------

/// The operators shown as they are (not translated).
const _notTranslateKey = {'=', '≠', '>', '≥', '<', '≤'};

/// `isComparisonOperatorNeedTranslate`.
bool isComparisonOperatorNeedTranslate(String? operator) =>
    operator != null && operator.isNotEmpty && !_notTranslateKey.contains(operator);

const _stringOps = ['contains', 'not contains', 'start with', 'end with', 'is', 'is not', 'empty', 'not empty'];

/// `getOperators(type, file)`: the comparison operators of a variable type, or of a file attribute [fileKey].
List<String> getOperators(String? type, {String? fileKey}) {
  if (fileKey != null) {
    return switch (fileKey) {
      'name' || 'mime_type' || 'url' => _stringOps,
      'type' || 'transfer_method' => const ['in', 'not in'],
      'size' => const ['>', '≥', '<', '≤'],
      'extension' => const ['is', 'is not', 'contains', 'not contains'],
      'related_id' => const [
        'is',
        'is not',
        'contains',
        'not contains',
        'start with',
        'end with',
        'empty',
        'not empty',
      ],
      _ => const [],
    };
  }
  return switch (type) {
    VarType.string => _stringOps,
    VarType.number || VarType.integer => const ['=', '≠', '>', '<', '≥', '≤', 'empty', 'not empty'],
    VarType.boolean => const ['is', 'is not'],
    VarType.file => const ['exists', 'not exists'],
    VarType.arrayString || VarType.arrayNumber || VarType.arrayBoolean => const [
      'contains',
      'not contains',
      'empty',
      'not empty',
    ],
    VarType.array || VarType.arrayObject => const ['empty', 'not empty'],
    VarType.arrayFile => const ['contains', 'not contains', 'all of', 'empty', 'not empty'],
    _ => const ['is', 'is not', 'empty', 'not empty'],
  };
}

/// `branchNameCorrect`: two branches are IF / ELSE, more are CASE n / ELSE.
List<Json> branchNameCorrect(List<Json> branches) {
  if (branches.length < 2) throw StateError('if-else node branch number must than 2');
  return [
    for (final (i, b) in branches.indexed)
      {
        ...b,
        'name': b['id'] == 'false' ? 'ELSE' : (branches.length == 2 ? 'IF' : 'CASE ${i + 1}'),
      },
  ];
}

// ---- nodes/constants.ts ------------------------------------------------------------------------------------------

const subVariables = ['type', 'size', 'name', 'url', 'extension', 'mime_type', 'transfer_method', 'related_id'];

/// FILE_TYPE_OPTIONS and TRANSFER_METHOD: value and `nodes.ifElse.optionName` key.
const fileTypeOptions = [('image', 'image'), ('document', 'doc'), ('audio', 'audio'), ('video', 'video')];
const transferMethodOptions = [('local_file', 'localUpload'), ('remote_url', 'url')];

// ---- use-config.helpers.ts ---------------------------------------------------------------------------------------

/// A uuid v4 (the `uuid` package's `v4`).
String uuid4() {
  final r = Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// immer's `produce`: a deep copy of plain JSON to change.
Object? _copy(Object? x) => switch (x) {
  final Map m => <String, Object?>{for (final e in m.entries) '${e.key}': _copy(e.value)},
  final List l => [for (final v in l) _copy(v)],
  _ => x,
};

Json produce(Json inputs, void Function(Json draft) recipe) {
  final draft = _copy(inputs)! as Json;
  recipe(draft);
  return draft;
}

List<Json> _maps(Object? x) => [
  for (final v in jsList(x))
    if (v is Map) v as Json,
];

Json? _case(Json draft, String caseId) => _maps(draft['cases']).where((c) => c['case_id'] == caseId).firstOrNull;

Json? _condition(Json draft, String caseId, String conditionId) {
  final c = _case(draft, caseId);
  return c == null ? null : _maps(c['conditions']).where((x) => x['id'] == conditionId).firstOrNull;
}

bool filterAllVars() => true;

bool filterNumberVars(PickerVar v) => v.type == VarType.number;

/// `getVarsIsVarFileAttribute`: whether each condition's variable is a file attribute.
Map<String, bool> getVarsIsVarFileAttribute(Object? cases, bool Function(List<String> selector) isFileAttribute) => {
  for (final c in _maps(cases))
    for (final cond in _maps(c['conditions']))
      if (cond['variable_selector'] is List)
        jsKey(cond['id']): isFileAttribute([for (final s in jsList(cond['variable_selector'])) jsKey(s)]),
};

List<Json>? _targetBranchesWithNewCase(Object? targetBranches, String caseId) {
  if (targetBranches is! List) return null;
  final branches = _maps(targetBranches);
  final elseIndex = branches.indexWhere((b) => b['id'] == 'false');
  if (elseIndex < 0) return branches;
  return branchNameCorrect([
    ...branches.sublist(0, elseIndex),
    {'id': caseId, 'name': ''},
    ...branches.sublist(elseIndex),
  ]);
}

Json addCase(Json inputs, {String Function() uuid = uuid4}) => produce(inputs, (draft) {
  if (draft['cases'] is! List) return;
  final caseId = uuid();
  (draft['cases']! as List).add(<String, Object?>{'case_id': caseId, 'logical_operator': 'and', 'conditions': []});
  draft['_targetBranches'] = _targetBranchesWithNewCase(draft['_targetBranches'], caseId);
});

Json removeCase(Json inputs, String caseId) => produce(inputs, (draft) {
  if (draft['cases'] is List) {
    draft['cases'] = [
      for (final c in _maps(draft['cases']))
        if (c['case_id'] != caseId) c,
    ];
  }
  if (draft['_targetBranches'] is List) {
    draft['_targetBranches'] = branchNameCorrect([
      for (final b in _maps(draft['_targetBranches']))
        if (b['id'] != caseId) b,
    ]);
  }
});

/// `sortCases`: [newCases] carry an `id` (their case id, ReactSortable's), kept on each case.
Json sortCases(Json inputs, List<Json> newCases) => produce(inputs, (draft) {
  draft['cases'] = [
    for (final c in newCases)
      {
        'id': c['id'],
        'case_id': c['case_id'],
        'logical_operator': c['logical_operator'],
        'conditions': _copy(c['conditions']),
      },
  ];
  draft['_targetBranches'] = branchNameCorrect([
    for (final c in newCases) {'id': c['case_id'], 'name': ''},
    {'id': 'false', 'name': ''},
  ]);
});

Json addCondition({
  required Json inputs,
  required String caseId,
  required List<String> valueSelector,
  required String? varType,
  required bool isVarFileAttribute,
  String Function() uuid = uuid4,
}) => produce(inputs, (draft) {
  final c = _case(draft, caseId);
  if (c == null) return;
  final ops = getOperators(varType, fileKey: isVarFileAttribute ? valueSelector.last : null);
  (c['conditions']! as List).add(<String, Object?>{
    'id': uuid(),
    'varType': varType,
    'variable_selector': valueSelector,
    'comparison_operator': ops.firstOrNull,
    'value': varType == VarType.boolean || varType == VarType.arrayBoolean ? false : '',
  });
});

Json removeCondition(Json inputs, String caseId, String conditionId) => produce(inputs, (draft) {
  final c = _case(draft, caseId);
  if (c != null) {
    c['conditions'] = [
      for (final x in _maps(c['conditions']))
        if (x['id'] != conditionId) x,
    ];
  }
});

/// `Object.assign(condition, next)`.
Json updateCondition(Json inputs, String caseId, String conditionId, Json next) => produce(inputs, (draft) {
  _condition(draft, caseId, conditionId)?.addAll(_copy(next)! as Json);
});

String _toggled(Object? op) => op == 'and' ? 'or' : 'and';

Json toggleConditionLogicalOperator(Json inputs, String caseId) => produce(inputs, (draft) {
  final c = _case(draft, caseId);
  if (c != null) c['logical_operator'] = _toggled(c['logical_operator']);
});

Json addSubVariableCondition(
  Json inputs,
  String caseId,
  String conditionId, [
  String? key,
  String Function() uuid = uuid4,
]) => produce(inputs, (draft) {
  final condition = _condition(draft, caseId, conditionId);
  if (condition == null) return;
  if (condition['sub_variable_condition'] is! Map) {
    condition['sub_variable_condition'] = <String, Object?>{
      'case_id': uuid(),
      'logical_operator': 'and',
      'conditions': [],
    };
  }
  ((condition['sub_variable_condition']! as Json)['conditions']! as List).add(<String, Object?>{
    'id': uuid(),
    'key': key ?? '',
    'varType': VarType.string,
    'value': '',
  });
});

Json? _sub(Json draft, String caseId, String conditionId) => switch (_condition(
  draft,
  caseId,
  conditionId,
)?['sub_variable_condition']) {
  final Json s => s,
  _ => null,
};

Json removeSubVariableCondition(Json inputs, String caseId, String conditionId, String subConditionId) =>
    produce(inputs, (draft) {
      final s = _sub(draft, caseId, conditionId);
      if (s != null) {
        s['conditions'] = [
          for (final x in _maps(s['conditions']))
            if (x['id'] != subConditionId) x,
        ];
      }
    });

Json updateSubVariableCondition(
  Json inputs,
  String caseId,
  String conditionId,
  String subConditionId,
  Json next,
) => produce(inputs, (draft) {
  final s = _sub(draft, caseId, conditionId);
  if (s == null) return;
  _maps(s['conditions']).where((x) => x['id'] == subConditionId).firstOrNull?.addAll(_copy(next)! as Json);
});

Json toggleSubVariableConditionLogicalOperator(Json inputs, String caseId, String conditionId) =>
    produce(inputs, (draft) {
      final s = _sub(draft, caseId, conditionId);
      if (s != null) s['logical_operator'] = _toggled(s['logical_operator']);
    });

// ---- use-config.ts -----------------------------------------------------------------------------------------------

/// use-config.ts: the panel's handlers over the node's data. [inputs] reads the data as it is now (`inputsRef`),
/// [setInputs] writes it; [deleteBranch] is `handleEdgeDeleteByDeleteBranch`, [updateNodeInternals] React Flow's
/// re-layout of the handles, [isVarFileAttribute] `useIsVarFileAttribute`'s check.
class IfElseConfig {
  IfElseConfig({
    required this.nodeId,
    required this.inputs,
    required this.setInputs,
    required this.readOnly,
    this.deleteBranch,
    this.updateNodeInternals,
    this.isVarFileAttribute = _never,
    this.uuid = uuid4,
  });

  final String nodeId;
  final Json Function() inputs;
  final void Function(Json inputs) setInputs;
  final bool readOnly;
  final void Function(String nodeId, String caseId)? deleteBranch;
  final void Function(String nodeId)? updateNodeInternals;
  final bool Function(List<String> selector) isVarFileAttribute;
  final String Function() uuid;

  static bool _never(List<String> _) => false;

  bool filterVar() => filterAllVars();
  bool filterNumberVar(PickerVar v) => filterNumberVars(v);

  Map<String, bool> get varsIsVarFileAttribute => getVarsIsVarFileAttribute(inputs()['cases'], isVarFileAttribute);

  void handleAddCase() => setInputs(addCase(inputs(), uuid: uuid));

  void handleRemoveCase(String caseId) {
    deleteBranch?.call(nodeId, caseId);
    setInputs(removeCase(inputs(), caseId));
  }

  void handleSortCase(List<Json> newCases) {
    setInputs(sortCases(inputs(), newCases));
    updateNodeInternals?.call(nodeId);
  }

  void handleAddCondition(String caseId, List<String> valueSelector, PickerVar variable) => setInputs(
    addCondition(
      inputs: inputs(),
      caseId: caseId,
      valueSelector: valueSelector,
      varType: variable.type,
      isVarFileAttribute: isVarFileAttribute(valueSelector),
      uuid: uuid,
    ),
  );

  void handleRemoveCondition(String caseId, String conditionId) =>
      setInputs(removeCondition(inputs(), caseId, conditionId));

  void handleUpdateCondition(String caseId, String conditionId, Json condition) =>
      setInputs(updateCondition(inputs(), caseId, conditionId, condition));

  void handleToggleConditionLogicalOperator(String caseId) =>
      setInputs(toggleConditionLogicalOperator(inputs(), caseId));

  void handleAddSubVariableCondition(String caseId, String conditionId, [String? key]) =>
      setInputs(addSubVariableCondition(inputs(), caseId, conditionId, key, uuid));

  void handleRemoveSubVariableCondition(String caseId, String conditionId, String subConditionId) =>
      setInputs(removeSubVariableCondition(inputs(), caseId, conditionId, subConditionId));

  void handleUpdateSubVariableCondition(String caseId, String conditionId, String subConditionId, Json condition) =>
      setInputs(updateSubVariableCondition(inputs(), caseId, conditionId, subConditionId, condition));

  void handleToggleSubVariableConditionLogicalOperator(String caseId, String conditionId) =>
      setInputs(toggleSubVariableConditionLogicalOperator(inputs(), caseId, conditionId));
}
