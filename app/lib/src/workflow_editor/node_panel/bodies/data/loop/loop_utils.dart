/// The Loop node's condition vocabulary (nodes/loop/types.ts `ComparisonOperator`, utils.ts, default.ts options).
library;

import '../../../../../workflow/var_types.dart';
import '../data_common.dart';

/// `ComparisonOperator` values (`CmpOp` beside collab_client's `Op`).
abstract final class CmpOp {
  static const contains = 'contains';
  static const notContains = 'not contains';
  static const startWith = 'start with';
  static const endWith = 'end with';
  static const is_ = 'is';
  static const isNot = 'is not';
  static const empty = 'empty';
  static const notEmpty = 'not empty';
  static const equal = '=';
  static const notEqual = '≠';
  static const largerThan = '>';
  static const lessThan = '<';
  static const largerThanOrEqual = '≥';
  static const lessThanOrEqual = '≤';
  static const isNull = 'is null';
  static const isNotNull = 'is not null';
  static const in_ = 'in';
  static const notIn = 'not in';
  static const allOf = 'all of';
  static const exists = 'exists';
  static const notExists = 'not exists';
}

const _emptyRelated = {CmpOp.empty, CmpOp.notEmpty, CmpOp.isNull, CmpOp.isNotNull, CmpOp.exists, CmpOp.notExists};

/// `isEmptyRelatedOperator`.
bool isEmptyRelatedOperator(String? operator) => _emptyRelated.contains(operator);

/// `comparisonOperatorNotRequireValue`.
bool comparisonOperatorNotRequireValue(String? operator) => operator != null && _emptyRelated.contains(operator);

/// `isComparisonOperatorNeedTranslate`: the symbol operators are shown as they are.
bool isComparisonOperatorNeedTranslate(String? operator) =>
    operator != null &&
    !const {
      CmpOp.equal,
      CmpOp.notEqual,
      CmpOp.largerThan,
      CmpOp.largerThanOrEqual,
      CmpOp.lessThan,
      CmpOp.lessThanOrEqual,
    }.contains(
      operator,
    );

const _stringOps = [
  CmpOp.contains,
  CmpOp.notContains,
  CmpOp.startWith,
  CmpOp.endWith,
  CmpOp.is_,
  CmpOp.isNot,
  CmpOp.empty,
  CmpOp.notEmpty,
];

/// `getOperators(type, file)`: the operators for a variable type, or for a file attribute [fileKey].
List<String> getOperators(String? type, {String? fileKey}) {
  if (fileKey != null) {
    return switch (fileKey) {
      'name' || 'mime_type' || 'url' => _stringOps,
      'type' || 'transfer_method' => const [CmpOp.in_, CmpOp.notIn],
      'size' => const [CmpOp.largerThan, CmpOp.largerThanOrEqual, CmpOp.lessThan, CmpOp.lessThanOrEqual],
      'extension' => const [CmpOp.is_, CmpOp.isNot, CmpOp.contains, CmpOp.notContains],
      _ => const [],
    };
  }
  return switch (type) {
    VarType.string => _stringOps,
    VarType.number => const [
      CmpOp.equal,
      CmpOp.notEqual,
      CmpOp.largerThan,
      CmpOp.lessThan,
      CmpOp.largerThanOrEqual,
      CmpOp.lessThanOrEqual,
      CmpOp.empty,
      CmpOp.notEmpty,
    ],
    VarType.boolean => const [CmpOp.is_, CmpOp.isNot, CmpOp.empty, CmpOp.notEmpty],
    VarType.object => const [CmpOp.empty, CmpOp.notEmpty],
    VarType.file => const [CmpOp.exists, CmpOp.notExists],
    VarType.arrayString ||
    VarType.arrayNumber => const [CmpOp.contains, CmpOp.notContains, CmpOp.empty, CmpOp.notEmpty],
    VarType.array || VarType.arrayObject => const [CmpOp.empty, CmpOp.notEmpty],
    VarType.arrayFile => const [CmpOp.contains, CmpOp.notContains, CmpOp.allOf, CmpOp.empty, CmpOp.notEmpty],
    _ => const [CmpOp.is_, CmpOp.isNot, CmpOp.empty, CmpOp.notEmpty],
  };
}

/// The label of an operator in the condition operator dropdown.
String operatorLabel(String o) => isComparisonOperatorNeedTranslate(o) ? wf('nodes.ifElse.comparisonOperator.$o') : o;

/// `FILE_TYPE_OPTIONS` / `TRANSFER_METHOD` with their `nodes.ifElse.optionName.*` keys.
const fileTypeOptions = [('image', 'image'), ('document', 'doc'), ('audio', 'audio'), ('video', 'video')];
const transferMethodOptions = [('local_file', 'localUpload'), ('remote_url', 'url')];

/// `SUB_VARIABLES`: the file attributes a sub-variable condition can test.
const subVariables = ['type', 'size', 'name', 'url', 'extension', 'mime_type', 'transfer_method', 'related_id'];
