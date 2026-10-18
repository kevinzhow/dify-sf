/// A node's config as the plain JSON `data` Dify's workflow code works on, and the JavaScript semantics (truthiness,
/// `a?.b`, `Object.keys`, `String(x)`) the ports of that code need to mirror it one to one, quirks included.
///
/// Where Dify's code would throw (it reads a property of `undefined`), the ports throw [JsTypeError].
library;

import 'package:collab_client/collab_client.dart';

/// A config value as plain JSON, the shape Dify's node `data` has: keyed lists become lists, references (live or
/// broken) become their value selector `[node, output]`.
Object? plainOf(Value? v) => switch (v) {
  null || VNull() => null,
  VBool(:final value) => value,
  VInt(:final value) => value,
  VDouble(:final value) => value,
  VString(:final value) => value,
  VRef(:final ref) || VBroken(:final ref) => [ref.node, ref.output],
  VList(:final items) => [for (final i in items) plainOf(i)],
  VItems(:final items) => [for (final i in items) plainOf(i.value)],
  VMap(:final entries) => {for (final e in entries.entries) e.key: plainOf(e.value)},
};

/// Dify's node `data` for [node]: its config as plain JSON plus `type` and `title`. A fresh, mutable tree.
Map<String, Object?> difyDataOf(Node node) => {
  for (final e in node.config.entries) e.key: plainOf(e.value),
  'type': node.type,
  'title': node.title,
};

/// The value selector stored at a config value (`value_selector`, `variable_selector`, ...): a reference (live or
/// broken) or a plain list of strings (sys/env/conversation variables, deeper paths); null for anything else.
List<String>? selectorOf(Value? v) => switch (v) {
  VRef(:final ref) || VBroken(:final ref) => [ref.node, ref.output],
  VList(:final items) => [for (final i in items) ?(i is VString ? i.value : null)],
  _ => null,
};

/// `variableTransformer` (workflow/utils/variable.ts), template to selector: `{{#node.out#}}` -> `[node, out]`.
List<String> templateToSelector(String template) => template.replaceAll(RegExp(r'^\{\{#|#\}\}$'), '').split('.');

/// `variableTransformer`, selector to template: `[node, out]` -> `{{#node.out#}}`.
String selectorToTemplate(List<String> selector) => '{{#${selector.join('.')}#}}';

/// What Dify's code would throw (a property read on `undefined`).
final class JsTypeError implements Exception {
  const JsTypeError(this.what);
  final String what;
  @override
  String toString() => 'TypeError: $what';
}

/// JavaScript truthiness (`[]` and `{}` are truthy).
bool jsTruthy(Object? x) => switch (x) {
  null => false,
  final bool b => b,
  final num n => n != 0 && !n.isNaN,
  final String s => s.isNotEmpty,
  _ => true,
};

String? jsStr(Object? x) => x is String ? x : null;

/// `o?.[key]`: a map member or an array index; null (undefined) for anything else.
Object? jsGet(Object? o, String key) => switch (o) {
  final Map m => m[key],
  final List l => switch (int.tryParse(key)) {
    final i? when i >= 0 && i < l.length && '$i' == key => l[i],
    _ => null,
  },
  _ => null,
};

/// `o.key` where `o` may be null or undefined: that read throws in JavaScript.
Object? jsReq(Object? o, String key, String what) =>
    o == null ? throw JsTypeError("cannot read '$key' of undefined ($what)") : jsGet(o, key);

List<Object?> jsList(Object? x) => x is List ? x.cast<Object?>() : const [];

/// Number of `Object.keys(x)`.
int jsKeyCount(Object? x) => switch (x) {
  final Map m => m.length,
  final List l => l.length,
  final String s => s.length,
  _ => 0,
};

/// `Object.entries(x)` for objects and arrays.
Iterable<MapEntry<String, Object?>> jsEntries(Object? x) => switch (x) {
  final Map m => m.entries.map((e) => MapEntry('${e.key}', e.value)),
  final List l => [for (final (i, v) in l.indexed) MapEntry('$i', v)],
  _ => const [],
};

/// A JS property key as `String(x)` makes it (`['number']` is the key `number`).
String jsKey(Object? x) => switch (x) {
  null => 'undefined',
  final List l => l.map((e) => e == null ? '' : jsKey(e)).join(','),
  final Map _ => '[object Object]',
  _ => '$x',
};

/// `x.join(sep)`; throws where `x` is not an array (`undefined.join`, `'ab'.join`).
String jsJoin(Object? x, String what, [String sep = '.']) =>
    x is List ? x.map((e) => e == null ? '' : jsKey(e)).join(sep) : throw JsTypeError('$what.join is not a function');

/// `x?.join(sep)`.
String? jsJoinOpt(Object? x, String what, [String sep = '.']) => x == null ? null : jsJoin(x, what, sep);

/// Deep equality of plain JSON (maps, lists, scalars; other objects by `==`).
bool jsonEquals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !jsonEquals(e.value, b[e.key])) return false;
    }
    return true;
  }
  return a == b;
}
