/// The Loop panel's logic (nodes/loop/use-config.ts, use-config.helpers.ts, use-is-var-file-attribute.ts): pure
/// updates of the node's data (plain JSON; the inputs are never changed) and the config the panel binds to.
library;

import 'dart:math';

import 'package:collab_client/collab_client.dart';

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart' show childrenOf;
import 'loop_utils.dart';
import '../../../panel_edit.dart' show NodeVars;
import '../../../panel_edit.dart' as edit;

final _random = Random.secure();

/// `uuid4()`.
String uuid4() {
  String hex(int n) => [for (var i = 0; i < n; i++) _random.nextInt(16).toRadixString(16)].join();
  final variant = '89ab'[_random.nextInt(4)];
  return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
}

List<Json> _list(Object? v) => [
  for (final e in jsList(v))
    if (e is Map) e.cast<String, Object?>(),
];

/// `canUseAsLoopInput`.
bool canUseAsLoopInput(String? type) => const {
  VarType.array,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.arrayObject,
  VarType.arrayFile,
}.contains(type);

/// `updateErrorHandleMode`.
Json updateErrorHandleMode(Json inputs, String mode) => {...inputs, 'error_handle_mode': mode};

/// `addBreakCondition`: a condition on [valueSelector] (a variable of [type]) with the type's first operator, or
/// the file attribute's when [isVarFileAttribute].
Json addBreakCondition({
  required Json inputs,
  required List<String> valueSelector,
  required String? type,
  required bool isVarFileAttribute,
  String Function() uuid = uuid4,
}) => {
  ...inputs,
  'break_conditions': [
    ..._list(inputs['break_conditions']),
    {
      'id': uuid(),
      'varType': type,
      'variable_selector': valueSelector,
      'comparison_operator': getOperators(type, fileKey: isVarFileAttribute ? valueSelector.last : null).firstOrNull,
      'value': type == VarType.boolean ? false : '',
    },
  ],
};

/// `removeBreakCondition`.
Json removeBreakCondition(Json inputs, String conditionId) => {
  ...inputs,
  'break_conditions': [
    for (final c in _list(inputs['break_conditions']))
      if (c['id'] != conditionId) c,
  ],
};

List<Json> _mapWhere(Object? list, bool Function(Json) test, Json Function(Json) change) => [
  for (final c in _list(list)) test(c) ? change(c) : c,
];

/// `updateBreakCondition`: [condition]'s fields assigned onto the one with [conditionId].
Json updateBreakCondition(Json inputs, String conditionId, Json condition) => {
  ...inputs,
  'break_conditions': _mapWhere(inputs['break_conditions'], (c) => c['id'] == conditionId, (c) => {...c, ...condition}),
};

String _flip(Object? op) => op == 'and' ? 'or' : 'and';

/// `toggleConditionOperator`.
Json toggleConditionOperator(Json inputs) => {...inputs, 'logical_operator': _flip(inputs['logical_operator'])};

Json _withCondition(Json inputs, String conditionId, Json? Function(Json condition) change) {
  final conditions = _list(inputs['break_conditions']);
  final i = conditions.indexWhere((c) => c['id'] == conditionId);
  if (i < 0) return inputs;
  final next = change(conditions[i]);
  if (next == null) return inputs;
  return {
    ...inputs,
    'break_conditions': [...conditions]..[i] = next,
  };
}

/// `addSubVariableCondition`: a sub-condition on the file attribute [key] (none: '').
Json addSubVariableCondition(Json inputs, String conditionId, [String? key, String Function() uuid = uuid4]) =>
    _withCondition(inputs, conditionId, (c) {
      final sub = (c['sub_variable_condition'] as Map?)?.cast<String, Object?>() ?? {'logical_operator': 'and'};
      return {
        ...c,
        'sub_variable_condition': {
          ...sub,
          'conditions': [
            ..._list(sub['conditions']),
            {
              'id': uuid(),
              'key': key ?? '',
              'varType': VarType.string,
              'comparison_operator': getOperators(VarType.string, fileKey: key ?? '').firstOrNull,
              'value': '',
            },
          ],
        },
      };
    });

Json? _withSub(Json c, Json Function(Json sub) change) {
  final sub = (c['sub_variable_condition'] as Map?)?.cast<String, Object?>();
  return sub == null ? null : {...c, 'sub_variable_condition': change(sub)};
}

/// `removeSubVariableCondition`.
Json removeSubVariableCondition(Json inputs, String conditionId, String subConditionId) => _withCondition(
  inputs,
  conditionId,
  (c) => _withSub(
    c,
    (sub) => {
      ...sub,
      'conditions': [
        for (final s in _list(sub['conditions']))
          if (s['id'] != subConditionId) s,
      ],
    },
  ),
);

/// `updateSubVariableCondition`.
Json updateSubVariableCondition(Json inputs, String conditionId, String subConditionId, Json condition) =>
    _withCondition(inputs, conditionId, (c) {
      final subs = _list(jsGet(c['sub_variable_condition'], 'conditions'));
      if (!subs.any((s) => s['id'] == subConditionId)) return null;
      return _withSub(
        c,
        (sub) => {
          ...sub,
          'conditions': _mapWhere(sub['conditions'], (s) => s['id'] == subConditionId, (s) => {...s, ...condition}),
        },
      );
    });

/// `toggleSubVariableConditionOperator`.
Json toggleSubVariableConditionOperator(Json inputs, String conditionId) => _withCondition(
  inputs,
  conditionId,
  (c) => _withSub(c, (sub) => {...sub, 'logical_operator': _flip(sub['logical_operator'])}),
);

/// `updateLoopCount`.
Json updateLoopCount(Json inputs, num value) => {...inputs, 'loop_count': value};

/// `addLoopVariable`: a new constant string variable without a name.
Json addLoopVariable(Json inputs, [String Function() uuid = uuid4]) => {
  ...inputs,
  'loop_variables': [
    ..._list(inputs['loop_variables']),
    {'id': uuid(), 'label': '', 'var_type': VarType.string, 'value_type': 'constant', 'value': ''},
  ],
};

/// `removeLoopVariable`.
Json removeLoopVariable(Json inputs, String id) => {
  ...inputs,
  'loop_variables': [
    for (final v in _list(inputs['loop_variables']))
      if (v['id'] != id) v,
  ],
};

/// `updateLoopVariable`: [update] merged into the variable with [id] (unchanged when there is none).
Json updateLoopVariable(Json inputs, String id, Json update) {
  final vars = _list(inputs['loop_variables']);
  if (!vars.any((v) => v['id'] == id)) return inputs;
  return {
    ...inputs,
    'loop_variables': _mapWhere(vars, (v) => v['id'] == id, (v) => {...v, ...update}),
  };
}

/// useConfig of the Loop node. Each handler starts from the latest inputs it produced (Dify's `inputsRef`), so quick
/// successive edits compose.
class LoopConfig {
  LoopConfig({
    required this.id,
    required Json inputs,
    required this.setInputs,
    this.readOnly = false,
    this.loopChildrenNodes = const [],
    this.childrenNodeVars = const VarScope(),
    this.getIsVarFileAttribute = _never,
    this.uuid = uuid4,
  }) : _inputs = {...inputs};

  /// The panel's config for [props]' node: conditions may reference the loop's own variables, its children's
  /// outputs and conversation variables.
  factory LoopConfig.of(NodePanelProps props) {
    final doc = props.controller.doc;
    final nodes = [props.node, ...childrenOf(doc, props.id)];
    final types = NodeVars.of(props).scope.typeOf;
    return LoopConfig(
      id: props.id,
      inputs: props.data,
      setInputs: (next) => edit.setInputs(props, next),
      readOnly: props.readOnly,
      loopChildrenNodes: nodes,
      childrenNodeVars: NodeVars.scopeOver(props, nodes, environment: false),
      getIsVarFileAttribute: (selector) => selector.length == 3 && types?.call(selector.sublist(0, 2)) == VarType.file,
    );
  }

  static bool _never(List<String> _) => false;

  final String id;
  Json _inputs;
  final void Function(Json next) setInputs;
  final bool readOnly;

  /// The loop node and its children (the condition variables' nodes).
  final List<Node> loopChildrenNodes;
  final VarScope childrenNodeVars;

  /// `useIsVarFileAttribute`: [selector] is an attribute (`[node, var, attr]`) of a file variable.
  final bool Function(List<String> selector) getIsVarFileAttribute;
  final String Function() uuid;

  Json get inputs => _inputs;

  void _change(Json next) {
    _inputs = next;
    setInputs(next);
  }

  bool filterInputVar(PickerVar v) => canUseAsLoopInput(v.type);

  void changeErrorResponseMode(String mode) => _change(updateErrorHandleMode(_inputs, mode));

  void handleAddCondition(List<String> valueSelector, PickerVar variable) => _change(
    addBreakCondition(
      inputs: _inputs,
      valueSelector: valueSelector,
      type: variable.type,
      isVarFileAttribute: getIsVarFileAttribute(valueSelector),
      uuid: uuid,
    ),
  );

  void handleRemoveCondition(String conditionId) => _change(removeBreakCondition(_inputs, conditionId));

  void handleUpdateCondition(String conditionId, Json condition) =>
      _change(updateBreakCondition(_inputs, conditionId, condition));

  void handleToggleConditionLogicalOperator() => _change(toggleConditionOperator(_inputs));

  void handleAddSubVariableCondition(String conditionId, [String? key]) =>
      _change(addSubVariableCondition(_inputs, conditionId, key, uuid));

  void handleRemoveSubVariableCondition(String conditionId, String subConditionId) =>
      _change(removeSubVariableCondition(_inputs, conditionId, subConditionId));

  void handleUpdateSubVariableCondition(String conditionId, String subConditionId, Json condition) =>
      _change(updateSubVariableCondition(_inputs, conditionId, subConditionId, condition));

  void handleToggleSubVariableConditionLogicalOperator(String conditionId) =>
      _change(toggleSubVariableConditionOperator(_inputs, conditionId));

  void handleUpdateLoopCount(num value) => _change(updateLoopCount(_inputs, value));

  void handleAddLoopVariable() => _change(addLoopVariable(_inputs, uuid));

  void handleRemoveLoopVariable(String id) => _change(removeLoopVariable(_inputs, id));

  void handleUpdateLoopVariable(String id, Json update) => _change(updateLoopVariable(_inputs, id, update));
}
