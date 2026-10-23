/// The Loop node's single-run form parameters (loop/use-single-run-form-params(.helpers).ts) as pure functions; see
/// container_single_run.dart for what is passed in.
library;

import '../../../../../workflow/dify_json.dart';
import '../iteration/container_interactions.dart' show RfNode;
import '../iteration/container_single_run.dart';

export '../iteration/container_single_run.dart' show buildUsedOutVars, createInputVarValues, dedupeInputVars;

List<Map<String, Object?>> _maps(Object? v) => [
  for (final e in jsList(v))
    if (e is Map) e.cast<String, Object?>(),
];

List<String> _sel(Object? v) => [for (final s in jsList(v)) '$s'];

/// `getVarSelectorsFromCase`.
List<List<String>> getVarSelectorsFromCase(Map<String, Object?> caseItem) => [
  for (final c in _maps(caseItem['conditions'])) ...getVarSelectorsFromCondition(c),
];

/// `getVarSelectorsFromCondition`: the condition's variable, then its sub-conditions' ones.
List<List<String>> getVarSelectorsFromCondition(Map<String, Object?> condition) => [
  if (condition['variable_selector'] != null) _sel(condition['variable_selector']),
  if (jsList(jsGet(condition['sub_variable_condition'], 'conditions')).isNotEmpty)
    ...getVarSelectorsFromCase((condition['sub_variable_condition']! as Map).cast<String, Object?>()),
];

/// `getDependentVarsFromLoopPayload`: what the run depends on, without the loop's own variables.
List<List<String>> getDependentVarsFromLoopPayload({
  required String nodeId,
  required List<RunVar> usedOutVars,
  Object? breakConditions,
  Object? loopVariables,
}) => [
  for (final s in [
    for (final v in usedOutVars) '${v['variable']}'.split('.'),
    for (final c in _maps(breakConditions)) ...getVarSelectorsFromCondition(c),
    for (final v in _maps(loopVariables))
      if (v['value_type'] == 'variable') _sel(v['value']),
  ])
    if (s.isEmpty || s[0] != nodeId) s,
];

/// The loop's single-run parameters (use-single-run-form-params.ts).
class LoopSingleRunParams {
  LoopSingleRunParams({
    required this.id,
    required this.payload,
    required this.runInputData,
    required this.setRunInputData,
    required this.toVarInputs,
    required this.varSelectorsToVarInputs,
    required this.childrenNodes,
    required this.beforeNodes,
    required this.isNodeInLoop,
    required this.usedVars,
    required this.passToServerKey,
    this.isSystemVar = isSystemSelector,
    this.formatTracing,
    this.runResult,
    this.loopRunResult = const [],
  }) {
    final built = buildUsedOutVars(
      childrenNodes: childrenNodes,
      currentNodeId: id,
      canChooseVarNodes: [...beforeNodes, ...childrenNodes],
      isNodeInContainer: isNodeInLoop,
      toVarInputs: toVarInputs,
      usedVars: usedVars,
      passToServerKey: passToServerKey,
      isSystemVar: isSystemVar,
    );
    usedOutVars = built.usedOutVars;
    allVarObject = built.allVarObject;
  }

  final String id;
  final Map<String, Object?> payload;
  final Map<String, Object?> runInputData;
  final void Function(Map<String, Object?> data) setRunInputData;
  final List<RunVar> Function(List<RunVar> variables) toVarInputs;
  final List<RunVar> Function(List<List<String>> selectors) varSelectorsToVarInputs;
  final List<RfNode> childrenNodes, beforeNodes;
  final bool Function(String nodeId) isNodeInLoop;
  final UsedVarsOf usedVars;
  final PassToServerKeyOf passToServerKey;
  final bool Function(List<String>) isSystemVar;
  final List<Object?> Function(List<Object?> result)? formatTracing;
  final Map<String, Object?>? runResult;
  final List<Object?> loopRunResult;

  late final List<RunVar> usedOutVars;
  late final Map<String, Map<String, String>> allVarObject;

  /// The formatted trace, with the run result's execution metadata under its own.
  Object? get nodeInfo {
    final formatted = formatTracing?.call(loopRunResult).firstOrNull;
    if (runResult == null || formatted is! Map) return formatted;
    return {
      ...formatted,
      'execution_metadata': {
        ...?(runResult!['execution_metadata'] as Map?),
        ...?(formatted['execution_metadata'] as Map?),
      },
    };
  }

  List<SingleRunForm> get forms {
    final selectors = [
      for (final c in _maps(payload['break_conditions'])) ...getVarSelectorsFromCondition(c),
      for (final v in _maps(payload['loop_variables']))
        if (v['value_type'] == 'variable') _sel(v['value']),
    ];
    return [
      (
        label: null,
        inputs: [...usedOutVars, ...dedupeInputVars(varSelectorsToVarInputs(selectors))],
        values: createInputVarValues(runInputData),
        onChange: setRunInputData,
      ),
    ];
  }

  List<List<String>> getDependentVars() => getDependentVarsFromLoopPayload(
    nodeId: id,
    usedOutVars: usedOutVars,
    breakConditions: payload['break_conditions'],
    loopVariables: payload['loop_variables'],
  );
}
