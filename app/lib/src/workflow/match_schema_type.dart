/// `matchTheSchemaType`, ported from Dify 1.17.1
/// `web/app/components/workflow/nodes/_base/components/variable/match-schema-type.ts`.
library;

/// JavaScript's `undefined` (a missing key), distinct from a JSON `null`.
const Object _undefined = _Undefined();

final class _Undefined {
  const _Undefined();
}

/// `isObj`: objects and arrays (`typeof x === 'object'`, not null).
bool _isObj(Object? x) => x is Map || x is List;

/// `Object.keys(x)` (also what `for...in` visits on plain JSON).
Iterable<String> _keys(Object? x) => switch (x) {
  final Map m => m.keys.map((k) => '$k'),
  final List l => [for (var i = 0; i < l.length; i++) '$i'],
  _ => const [],
};

/// `x[key]`, [_undefined] where absent.
Object? _get(Object? x, String key) => switch (x) {
  final Map m when m.containsKey(key) => m[key],
  final List l => switch (int.tryParse(key)) {
    final i? when i >= 0 && i < l.length && '$i' == key => l[i],
    _ => _undefined,
  },
  _ => _undefined,
};

/// Whether the plain-JSON [target] has the `type`s of [scheme], recursively (values and keys without types are
/// ignored; a `type` that is itself an object is compared as a structure).
bool matchTheSchemaType(Object? scheme, Object? target) => _isMatch(scheme, target);

bool _isMatch(Object? schema, Object? t) {
  if (!_isObj(schema)) return true;
  if (!_isObj(t)) {
    // ignore the object without type: deep find whether schema has a type
    for (final key in _keys(schema)) {
      if (key == 'type') return false;
      final value = _get(schema, key);
      if (_isObj(value) && !_isMatch(value, null)) return false;
    }
    return true;
  }
  final tx = _get(schema, 'type');
  final ty = _get(t, 'type');
  final isTypeValueObj = _isObj(tx);
  // caution: type can be an object, then it is not compared by value
  if (!isTypeValueObj && tx != ty) return false;

  for (final k in {..._keys(schema), ..._keys(t)}) {
    if (k == 'type' && !isTypeValueObj) continue; // already checked
    if (!_isMatch(_get(schema, k), _get(t, k))) return false;
  }
  return true;
}
