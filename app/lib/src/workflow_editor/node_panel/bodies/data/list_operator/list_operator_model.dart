/// The list operator's logic as pure Dart over its Dify `data` (plain JSON): list-operator/use-config.helpers.ts,
/// filter-condition.tsx's helpers, and the parts of if-else/utils.ts (`getOperators`,
/// `comparisonOperatorNotRequireValue`, `isComparisonOperatorNeedTranslate`), nodes/constants.ts (FILE_TYPE_OPTIONS,
/// TRANSFER_METHOD, SUB_VARIABLES) and nodes/utils.ts (`getConditionValueAsString`) it uses.
///
/// The `update*` functions are Immer's `produce`: they return a changed deep copy and leave their input alone.
library;

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/output_vars.dart' show VarType;

/// if-else `ComparisonOperator` values.
abstract final class Op {
  static const contains = 'contains', notContains = 'not contains', startWith = 'start with', endWith = 'end with';
  static const is_ = 'is', isNot = 'is not', empty = 'empty', notEmpty = 'not empty';
  static const equal = '=', notEqual = '≠', largerThan = '>', lessThan = '<';
  static const largerThanOrEqual = '≥', lessThanOrEqual = '≤';
  static const isNull = 'is null', isNotNull = 'is not null', in_ = 'in', notIn = 'not in', allOf = 'all of';
  static const exists = 'exists', notExists = 'not exists';
}

/// list-operator `OrderBy`.
abstract final class OrderBy {
  static const asc = 'asc', desc = 'desc';
}

const _stringOps = [Op.contains, Op.notContains, Op.startWith, Op.endWith, Op.is_, Op.isNot, Op.empty, Op.notEmpty];

/// `getOperators(type, file)` (if-else/utils.ts): the operators for a variable [type], or for the file attribute
/// [fileKey] when one is given.
List<String> getOperators(String? type, {String? fileKey}) {
  if (fileKey != null) {
    return switch (fileKey) {
      'name' || 'mime_type' || 'url' => _stringOps,
      'type' || 'transfer_method' => const [Op.in_, Op.notIn],
      'size' => const [Op.largerThan, Op.largerThanOrEqual, Op.lessThan, Op.lessThanOrEqual],
      'extension' => const [Op.is_, Op.isNot, Op.contains, Op.notContains],
      'related_id' => const [
        Op.is_,
        Op.isNot,
        Op.contains,
        Op.notContains,
        Op.startWith,
        Op.endWith,
        Op.empty,
        Op.notEmpty,
      ],
      _ => const [],
    };
  }
  return switch (type) {
    VarType.string => _stringOps,
    VarType.number || VarType.integer => const [
      Op.equal,
      Op.notEqual,
      Op.largerThan,
      Op.lessThan,
      Op.largerThanOrEqual,
      Op.lessThanOrEqual,
      Op.empty,
      Op.notEmpty,
    ],
    VarType.boolean => const [Op.is_, Op.isNot],
    VarType.file => const [Op.exists, Op.notExists],
    VarType.arrayString || VarType.arrayNumber || VarType.arrayBoolean => const [
      Op.contains,
      Op.notContains,
      Op.empty,
      Op.notEmpty,
    ],
    VarType.array || VarType.arrayObject => const [Op.empty, Op.notEmpty],
    VarType.arrayFile => const [Op.contains, Op.notContains, Op.allOf, Op.empty, Op.notEmpty],
    _ => const [Op.is_, Op.isNot, Op.empty, Op.notEmpty],
  };
}

/// `comparisonOperatorNotRequireValue`.
bool comparisonOperatorNotRequireValue(String? op) =>
    const {Op.empty, Op.notEmpty, Op.isNull, Op.isNotNull, Op.exists, Op.notExists}.contains(op);

/// `isComparisonOperatorNeedTranslate`: symbol operators are shown as they are.
bool isComparisonOperatorNeedTranslate(String? op) =>
    op != null &&
    op.isNotEmpty &&
    !const {Op.equal, Op.notEqual, Op.largerThan, Op.largerThanOrEqual, Op.lessThan, Op.lessThanOrEqual}.contains(op);

/// FILE_TYPE_OPTIONS (value, `nodes.ifElse.optionName.<i18nKey>`).
const fileTypeOptions = [('image', 'image'), ('document', 'doc'), ('audio', 'audio'), ('video', 'video')];

/// TRANSFER_METHOD.
const transferMethodOptions = [('local_file', 'localUpload'), ('remote_url', 'url')];

/// SUB_VARIABLES: a file's attributes.
const subVariables = ['type', 'size', 'name', 'url', 'extension', 'mime_type', 'transfer_method', 'related_id'];

/// `getConditionValueAsString`.
String conditionValueAsString(Object? value) => switch (value) {
  final List l => l.isEmpty ? '' : jsKey(l.first),
  final num n => jsKey(n),
  null => '',
  final String s => s,
  final other => jsKey(other),
};

// ---- use-config.helpers.ts ------------------------------------------------------------------------------------

/// `getItemVarType`: the element type of an array type (other types as they are, string when none).
String getItemVarType(String? varType) => switch (varType) {
  VarType.arrayNumber => VarType.number,
  VarType.arrayString => VarType.string,
  VarType.arrayFile => VarType.file,
  VarType.arrayObject => VarType.object,
  VarType.arrayBoolean => VarType.boolean,
  _ => varType ?? VarType.string,
};

/// `getItemVarTypeShowName`: the item type capitalised, `?` without a variable.
String getItemVarTypeShowName(String? itemVarType, bool hasVariable) {
  if (!hasVariable) return '?';
  final t = itemVarType == null || itemVarType.isEmpty ? VarType.string : itemVarType;
  return '${t.substring(0, 1).toUpperCase()}${t.substring(1)}';
}

/// `supportsSubVariable`: file arrays filter and sort by a file attribute.
bool supportsSubVariable(String? varType) => varType == VarType.arrayFile;

/// `canFilterVariable`: the input variable types offered.
bool canFilterVariable(String? type) =>
    const {VarType.arrayNumber, VarType.arrayString, VarType.arrayBoolean, VarType.arrayFile}.contains(type);

/// `buildFilterCondition`. As in Dify, a previous key makes the new key `''`.
Map<String, Object?> buildFilterCondition({String? itemVarType, required bool isFileArray, String? existingKey}) => {
  'key': isFileArray && (existingKey == null || existingKey.isEmpty) ? 'name' : '',
  'comparison_operator': getOperators(itemVarType, fileKey: isFileArray ? 'name' : null).firstOrNull,
  'value': itemVarType == VarType.boolean ? false : '',
};

Object? _copy(Object? x) => switch (x) {
  final Map m => {for (final e in m.entries) '${e.key}': _copy(e.value)},
  final List l => [for (final e in l) _copy(e)],
  _ => x,
};

/// A mutable deep copy of [inputs] (`produce`'s draft).
Map<String, Object?> _draft(Map<String, Object?> inputs) => _copy(inputs)! as Map<String, Object?>;

/// `draft.<key>` as a map, created when missing (where Dify would throw on `undefined`, the port creates it).
Map<String, Object?> _section(Map<String, Object?> d, String key) => switch (d[key]) {
  final Map<String, Object?> m => m,
  _ => d[key] = <String, Object?>{},
};

/// `updateListFilterVariable`.
Map<String, Object?> updateListFilterVariable(
  Map<String, Object?> inputs, {
  required List<String> variable,
  required String? varType,
  required String itemVarType,
}) {
  final d = _draft(inputs);
  final isFileArray = varType == VarType.arrayFile;
  d['variable'] = variable;
  d['var_type'] = varType;
  d['item_var_type'] = itemVarType;
  final filter = _section(d, 'filter_by');
  filter['conditions'] = [
    buildFilterCondition(
      itemVarType: itemVarType,
      isFileArray: isFileArray,
      existingKey: jsStr(jsGet(jsGet(filter['conditions'], '0'), 'key')),
    ),
  ];
  final order = _section(d, 'order_by');
  if (isFileArray && jsTruthy(order['enabled']) && !jsTruthy(order['key'])) order['key'] = 'name';
  return d;
}

/// `updateFilterEnabled`.
Map<String, Object?> updateFilterEnabled(Map<String, Object?> inputs, bool enabled) {
  final d = _draft(inputs);
  final filter = _section(d, 'filter_by');
  filter['enabled'] = enabled;
  if (enabled && filter['conditions'] == null) filter['conditions'] = <Object?>[];
  return d;
}

/// `updateFilterCondition`: the (only) condition becomes [condition].
Map<String, Object?> updateFilterCondition(Map<String, Object?> inputs, Map<String, Object?> condition) {
  final d = _draft(inputs);
  final filter = _section(d, 'filter_by');
  final list = switch (filter['conditions']) {
    final List<Object?> l => l,
    _ => filter['conditions'] = <Object?>[],
  };
  if (list.isEmpty) {
    list.add(_copy(condition));
  } else {
    list[0] = _copy(condition);
  }
  return d;
}

/// `updateLimit`.
Map<String, Object?> updateLimit(Map<String, Object?> inputs, Map<String, Object?> limit) =>
    _draft(inputs)..['limit'] = _copy(limit);

/// `updateExtractEnabled`: turning it on starts at the first item.
Map<String, Object?> updateExtractEnabled(Map<String, Object?> inputs, bool enabled) {
  final d = _draft(inputs);
  final extract = _section(d, 'extract_by');
  extract['enabled'] = enabled;
  if (enabled) extract['serial'] = '1';
  return d;
}

/// `updateExtractSerial`.
Map<String, Object?> updateExtractSerial(Map<String, Object?> inputs, String value) {
  final d = _draft(inputs);
  _section(d, 'extract_by')['serial'] = value;
  return d;
}

/// `updateOrderByEnabled`: turning it on sorts ascending, by `name` for file arrays without a key.
Map<String, Object?> updateOrderByEnabled(Map<String, Object?> inputs, bool enabled, bool hasSubVariable) {
  final d = _draft(inputs);
  final order = _section(d, 'order_by');
  order['enabled'] = enabled;
  if (enabled) {
    order['value'] = OrderBy.asc;
    if (hasSubVariable && !jsTruthy(order['key'])) order['key'] = 'name';
  }
  return d;
}

/// `updateOrderByKey`.
Map<String, Object?> updateOrderByKey(Map<String, Object?> inputs, String key) {
  final d = _draft(inputs);
  _section(d, 'order_by')['key'] = key;
  return d;
}

/// `updateOrderByType`.
Map<String, Object?> updateOrderByType(Map<String, Object?> inputs, String type) {
  final d = _draft(inputs);
  _section(d, 'order_by')['value'] = type;
  return d;
}

// ---- filter-condition.tsx -------------------------------------------------------------------------------------

/// VAR_INPUT_SUPPORTED_KEYS: the file attributes typed into a variable-capable input, and their type.
const varInputSupportedKeys = {
  'name': VarType.string,
  'url': VarType.string,
  'extension': VarType.string,
  'mime_type': VarType.string,
  'related_id': VarType.string,
  'size': VarType.number,
};

/// `getExpectedVarType`: the value's type (by file attribute when the condition has a key, else the item type);
/// null for attributes chosen from a list (type, transfer_method) or unknown keys.
String? expectedVarType(Map<String, Object?> condition, String? varType) {
  final key = jsStr(condition['key']) ?? '';
  return key.isNotEmpty ? varInputSupportedKeys[key] : varType;
}

/// in / not in / all of choose their value from a list.
bool isSelectOperator(Object? op) => const {Op.in_, Op.notIn, Op.allOf}.contains(op);

/// `getSelectOptions`: (value, `nodes.ifElse.optionName.<key>`) of the value select.
List<(String, String)> selectOptionsOf(Map<String, Object?> condition) {
  if (!isSelectOperator(condition['comparison_operator'])) return const [];
  if (condition['key'] == 'type' || condition['comparison_operator'] == Op.allOf) return fileTypeOptions;
  if (condition['key'] == 'transfer_method') return transferMethodOptions;
  return const [];
}

/// `getFallbackInputType`: whether the plain input is a number input.
bool fallbackInputIsNumber({required bool hasSubVariable, required Map<String, Object?> condition, String? varType}) =>
    (hasSubVariable && condition['key'] == 'size') || (!hasSubVariable && varType == VarType.number);
