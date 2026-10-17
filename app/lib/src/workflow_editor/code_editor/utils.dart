/// code-editor/utils.ts.
library;

import 'dart:convert';

/// `serializeCodeEditorValue`: the text the editor shows for [value], a string or a JSON value (objects become
/// `JSON.stringify(value, null, 2)`, so Monaco never receives an object).
String serializeCodeEditorValue(Object? value, {bool isJSONStringifyBeauty = false}) {
  if (value == null) return '';
  if (!isJSONStringifyBeauty) {
    if (value is String) return value;
    try {
      return _stringify(value);
    } catch (_) {
      return '';
    }
  }
  try {
    return _stringify(value);
  } catch (_) {
    return value is String ? value : '';
  }
}

/// `JSON.stringify(value, null, 2)`: integral doubles print without a fraction and non-finite numbers as null, as in
/// JavaScript.
String _stringify(Object value) => const JsonEncoder.withIndent('  ').convert(_jsValue(value));

Object? _jsValue(Object? v) => switch (v) {
  double d when !d.isFinite => null,
  double d when d == d.truncateToDouble() && d.abs() < 1e21 => d.toInt(),
  Map m => {for (final e in m.entries) '${e.key}': _jsValue(e.value)},
  Iterable l => [for (final e in l) _jsValue(e)],
  _ => v,
};
