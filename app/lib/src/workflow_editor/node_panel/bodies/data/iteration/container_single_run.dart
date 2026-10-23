/// The single-run form parameters of Iteration and Loop (iteration/use-single-run-form-params.ts,
/// loop/use-single-run-form-params(.helpers).ts) as pure functions. dify-sf has no single run yet; what Dify gets
/// from hooks and services (the variables a node uses, the run form's inputs, the trace formatter) is passed in.
library;

import '../../../../../workflow/dify_json.dart';
import 'container_interactions.dart' show RfNode;

/// `VALUE_SELECTOR_DELIMITER`.
const valueSelectorDelimiter = '@@@';

/// An input of a run form (`InputVar`) or a variable to make one from (`Variable`), as JSON.
typedef RunVar = Map<String, Object?>;

/// One form of the single-run panel.
typedef SingleRunForm = ({
  String? label,
  List<RunVar> inputs,
  Map<String, Object?> values,
  void Function(Map<String, Object?> values) onChange,
});

/// What Dify's variable utils give for a node (`getNodeUsedVars`, `getNodeUsedVarPassToServerKey`).
typedef UsedVarsOf = List<List<String>> Function(RfNode node);
typedef PassToServerKeyOf = Object Function(RfNode node, List<String> selector);

/// `isSystemVar` (variable/utils.ts).
bool isSystemSelector(List<String> v) => v.isNotEmpty && (v[0] == 'sys' || (v.length > 1 && v[1] == 'sys'));

/// `buildUsedOutVars`: the variables the container's children use from outside it (not the container's own
/// [currentNodeId] ones, not those of nodes inside it), as run inputs through [toVarInputs], and the keys they are
/// passed to the server with. [nodeNameFallback] is the loop's `|| ''` (the iteration has none).
({List<RunVar> usedOutVars, Map<String, Map<String, String>> allVarObject}) buildUsedOutVars({
  required List<RfNode> childrenNodes,
  required String currentNodeId,
  required List<RfNode> canChooseVarNodes,
  required bool Function(String nodeId) isNodeInContainer,
  required List<RunVar> Function(List<RunVar> variables) toVarInputs,
  required UsedVarsOf usedVars,
  required PassToServerKeyOf passToServerKey,
  bool Function(List<String> selector) isSystemVar = isSystemSelector,
  String? nodeNameFallback = '',
}) {
  final vars = <List<String>>[];
  final seen = <String>{};
  final all = <String, Map<String, String>>{};
  for (final node in childrenNodes) {
    for (final selector in usedVars(node).where((s) => s.isNotEmpty)) {
      if (selector[0] == currentNodeId || isNodeInContainer(selector[0])) continue;
      final str = selector.join('.');
      if (seen.add(str)) vars.add(selector);
      final keys = switch (passToServerKey(node, selector)) {
        final String s => [s],
        final List l => [for (final k in l) '$k'],
        _ => const <String>[],
      };
      for (final (i, key) in keys.indexed) {
        all[[str, node['id'], i].join(valueSelectorDelimiter)] = {'inSingleRunPassedKey': key};
      }
    }
  }
  RfNode? info(String id) => canChooseVarNodes.where((n) => n['id'] == id).firstOrNull;
  final usedOutVars = toVarInputs([
    for (final s in vars)
      {
        'label': {
          'nodeType': jsGet(info(s[0])?['data'], 'type'),
          'nodeName': _title(info(s[0])) ?? _title(canChooseVarNodes.firstOrNull) ?? nodeNameFallback,
          'variable': isSystemVar(s) ? s.join('.') : s.last,
        },
        'variable': s.join('.'),
        'value_selector': s,
      },
  ]);
  return (usedOutVars: usedOutVars, allVarObject: all);
}

/// A node's title when truthy.
String? _title(RfNode? n) => switch (jsGet(n?['data'], 'title')) {
  final String t when t.isNotEmpty => t,
  _ => null,
};

/// `createInputVarValues`: a copy of the run's input values.
Map<String, Object?> createInputVarValues(Map<String, Object?> runInputData) => {...runInputData};

/// `dedupeInputVars`: the first input per variable, nulls dropped.
List<RunVar> dedupeInputVars(List<RunVar?> inputVars) {
  final seen = <Object?>{};
  return [
    for (final v in inputVars)
      if (v != null && seen.add(v['variable'])) v,
  ];
}

/// The iteration's single-run parameters (use-single-run-form-params.ts).
class IterationSingleRunParams {
  IterationSingleRunParams({
    required this.id,
    required this.payload,
    required this.runInputData,
    required this.setRunInputData,
    required this.toVarInputs,
    required this.childrenNodes,
    required this.beforeNodes,
    required this.isNodeInIteration,
    required this.usedVars,
    required this.passToServerKey,
    required this.inputLabel,
    this.isSystemVar = isSystemSelector,
    this.formatTracing,
    this.iterationRunResult = const [],
  }) {
    final built = buildUsedOutVars(
      childrenNodes: childrenNodes,
      currentNodeId: id,
      canChooseVarNodes: [...beforeNodes, ...childrenNodes],
      isNodeInContainer: isNodeInIteration,
      toVarInputs: toVarInputs,
      usedVars: usedVars,
      passToServerKey: passToServerKey,
      isSystemVar: isSystemVar,
      nodeNameFallback: null,
    );
    usedOutVars = built.usedOutVars;
    allVarObject = built.allVarObject;
  }

  final String id;
  final Map<String, Object?> payload;
  final Map<String, Object?> runInputData;
  final void Function(Map<String, Object?> data) setRunInputData;
  final List<RunVar> Function(List<RunVar> variables) toVarInputs;
  final List<RfNode> childrenNodes, beforeNodes;
  final bool Function(String nodeId) isNodeInIteration;
  final UsedVarsOf usedVars;
  final PassToServerKeyOf passToServerKey;
  final bool Function(List<String>) isSystemVar;

  /// `t('nodes.iteration.input')`.
  final String inputLabel;

  /// `formatTracing(result, t)`.
  final List<Object?> Function(List<Object?> result)? formatTracing;
  final List<Object?> iterationRunResult;

  late final List<RunVar> usedOutVars;
  late final Map<String, Map<String, String>> allVarObject;

  String get iteratorInputKey => '$id.input_selector';

  List<SingleRunForm> get forms => [
    (label: null, inputs: [...usedOutVars], values: createInputVarValues(runInputData), onChange: setRunInputData),
    (
      label: inputLabel,
      inputs: [
        {
          'label': '',
          'variable': iteratorInputKey,
          'type': 'iterator',
          'required': false,
          'getVarValueFromDependent': true,
          'isFileItem': payload['iterator_input_type'] == 'array[file]',
        },
      ],
      values: {iteratorInputKey: runInputData[iteratorInputKey]},
      onChange: (kv) => setRunInputData({...runInputData, iteratorInputKey: kv[iteratorInputKey]}),
    ),
  ];

  Object? get nodeInfo => formatTracing?.call(iterationRunResult).firstOrNull;

  List<Object?> getDependentVars() => [payload['iterator_selector']];
  Object? getDependentVar(String variable) => variable == iteratorInputKey ? payload['iterator_selector'] : null;
}
