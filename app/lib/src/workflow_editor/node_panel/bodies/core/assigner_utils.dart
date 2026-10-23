/// The Variable Assigner's pure logic (nodes/assigner/types.ts, utils.ts, use-config.helpers.ts, hooks.ts
/// `useHandleAddOperationItem`, use-single-run-form-params.ts), on Dify's plain JSON.
library;

import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';

/// `WriteMode`.
abstract final class WriteMode {
  static const overwrite = 'over-write';
  static const clear = 'clear';
  static const append = 'append';
  static const extend = 'extend';
  static const set = 'set';
  static const increment = '+=';
  static const decrement = '-=';
  static const multiply = '*=';
  static const divide = '/=';
  static const removeFirst = 'remove-first';
  static const removeLast = 'remove-last';

  static const values = [
    overwrite,
    clear,
    append,
    extend,
    set,
    increment,
    decrement,
    multiply,
    divide,
    removeFirst,
    removeLast,
  ];
}

/// `AssignerNodeInputType`.
abstract final class AssignerNodeInputType {
  static const variable = 'variable';
  static const constant = 'constant';
}

/// `writeModeTypesNum`.
const writeModeTypesNum = [WriteMode.increment, WriteMode.decrement, WriteMode.multiply, WriteMode.divide];

/// use-config.ts `writeModeTypesArr`.
const writeModeTypesArr = [
  WriteMode.overwrite,
  WriteMode.clear,
  WriteMode.append,
  WriteMode.extend,
  WriteMode.removeFirst,
  WriteMode.removeLast,
];

/// use-config.ts `writeModeTypes`.
const writeModeTypes = [WriteMode.overwrite, WriteMode.clear, WriteMode.set];

/// The divider between the plain and the arithmetic operations of a number variable.
const operationDivider = 'divider';

/// `Item`: an operation (its value is its i18n name, `nodes.assigner.operations.<name>`) or the [operationDivider].
typedef OperationItem = ({String value, String name});

/// `getOperationItems`.
List<OperationItem> getOperationItems(
  String? assignedVarType, [
  List<String>? writeModeTypes,
  List<String>? writeModeTypesArr,
  List<String>? writeModeTypesNum,
]) {
  if ((assignedVarType?.startsWith('array') ?? false) && writeModeTypesArr != null) {
    return [for (final t in writeModeTypesArr) (value: t, name: t)];
  }
  if (assignedVarType == VarType.number && writeModeTypes != null && writeModeTypesNum != null) {
    return [
      for (final t in writeModeTypes) (value: t, name: t),
      (value: operationDivider, name: operationDivider),
      for (final t in writeModeTypesNum) (value: t, name: t),
    ];
  }
  if (writeModeTypes != null && const ['string', 'boolean', 'object'].contains(assignedVarType ?? '')) {
    return [for (final t in writeModeTypes) (value: t, name: t)];
  }
  return const [];
}

/// `isOperationItem`.
bool isOperationItem(OperationItem item) => item.value != operationDivider;

String _convertOldWriteMode(Object? old) => switch (old) {
  'over-write' => WriteMode.overwrite,
  'append' => WriteMode.append,
  'clear' => WriteMode.clear,
  _ => WriteMode.overwrite,
};

List<Object?> _selector(Object? v) => v is List ? [...v] : <Object?>[];

/// `normalizeOperationItems`: a selector that is no array becomes `[]`, an unknown operation `over-write`, the input
/// type `variable` unless it is `constant` (then the value is kept, else it is a selector too).
List<Map<String, Object?>> normalizeOperationItems(Object? items) {
  if (items is! List) return [];
  return [
    for (final raw in items)
      () {
        final item = raw is Map ? raw : const {};
        final inputType = item['input_type'] == AssignerNodeInputType.constant
            ? AssignerNodeInputType.constant
            : AssignerNodeInputType.variable;
        return <String, Object?>{
          'variable_selector': _selector(item['variable_selector']),
          'input_type': inputType,
          'operation': WriteMode.values.contains(item['operation']) ? item['operation'] : WriteMode.overwrite,
          'value': inputType == AssignerNodeInputType.variable ? _selector(item['value']) : item['value'],
        };
      }(),
  ];
}

/// `convertV1ToV2`: version 2 data with normalized items; legacy data as one item.
Map<String, Object?> convertV1ToV2(Map<String, Object?> payload) {
  if (payload['version'] == '2' && payload['items'] != null) {
    return {...payload, 'items': normalizeOperationItems(payload['items'])};
  }
  return {
    ...payload,
    'version': '2',
    'items': normalizeOperationItems([
      {
        'variable_selector': jsTruthy(payload['assigned_variable_selector'])
            ? payload['assigned_variable_selector']
            : <Object?>[],
        'input_type': AssignerNodeInputType.variable,
        'operation': _convertOldWriteMode(payload['write_mode']),
        'value': jsTruthy(payload['input_variable_selector']) ? payload['input_variable_selector'] : <Object?>[],
      },
    ]),
  };
}

/// `filterVarByType`.
bool Function(String? type) filterVarByType(String varType) =>
    (type) => varType == VarType.any || type == VarType.any || type == varType;

/// `normalizeAssignedVarType`: the type a value assigned with [writeMode] has.
String normalizeAssignedVarType(String? assignedVarType, String? writeMode) {
  if (const [
    WriteMode.overwrite,
    WriteMode.increment,
    WriteMode.decrement,
    WriteMode.multiply,
    WriteMode.divide,
    WriteMode.extend,
  ].contains(writeMode)) {
    return assignedVarType ?? VarType.string;
  }
  if (writeMode == WriteMode.append) {
    return switch (assignedVarType) {
      VarType.arrayString => VarType.string,
      VarType.arrayNumber => VarType.number,
      VarType.arrayObject => VarType.object,
      _ => VarType.string,
    };
  }
  return VarType.string;
}

/// `canAssignVar`: only conversation variables can be assigned.
bool canAssignVar(List<String> selector) => selector.join('.').startsWith('conversation');

/// `canAssignToVar`: whether a variable of [type] can be assigned to one of [assignedVarType] with [writeMode].
bool canAssignToVar(String? type, String? assignedVarType, String? writeMode) {
  if (const [
    WriteMode.overwrite,
    WriteMode.extend,
    WriteMode.increment,
    WriteMode.decrement,
    WriteMode.multiply,
    WriteMode.divide,
  ].contains(writeMode)) {
    return type == assignedVarType;
  }
  if (writeMode == WriteMode.append) {
    return switch (assignedVarType) {
      VarType.arrayString => type == VarType.string,
      VarType.arrayNumber => type == VarType.number,
      VarType.arrayObject => type == VarType.object,
      _ => false,
    };
  }
  return true;
}

/// `ensureAssignerVersion`.
Map<String, Object?> ensureAssignerVersion(Map<String, Object?> inputs) =>
    inputs['version'] == '2' ? inputs : {...inputs, 'version': '2'};

/// `updateOperationItems`.
Map<String, Object?> updateOperationItems(Map<String, Object?> inputs, List<Object?> items) => {
  ...inputs,
  'items': normalizeOperationItems(items),
};

/// `useHandleAddOperationItem`: [list] with a blank operation (keyed `write_mode`, as Dify writes it).
List<Object?> handleAddOperationItem(List<Object?> list) => [
  ...list,
  {
    'variable_selector': <Object?>[],
    'write_mode': WriteMode.overwrite,
    'input_type': AssignerNodeInputType.variable,
    'value': '',
  },
];

/// Whether [operation] takes its value from a variable (not clear, set, remove first / last or arithmetic).
bool operationTakesVariable(Object? operation) =>
    operation != WriteMode.clear &&
    operation != WriteMode.set &&
    operation != WriteMode.removeFirst &&
    operation != WriteMode.removeLast &&
    !writeModeTypesNum.contains(operation);

/// use-single-run-form-params.ts `vars` (`getDependentVars`): the values of the items assigning a variable.
List<Object?> assignerDependentVars(Map<String, Object?> inputs) => [
  for (final item in jsList(inputs['items']))
    if (operationTakesVariable(jsGet(item, 'operation'))) jsGet(item, 'value'),
];
