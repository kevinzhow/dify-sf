import 'dart:convert';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

/// Dify's test i18n (web/test/i18n-mock.ts): `t(key, { ns, ...params })` returns `<ns>.<key>`, followed by
/// `:<params as JSON>` when there are parameters besides `ns`.
class DifyTestTranslator implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      params.isEmpty ? '$ns.$key' : '$ns.$key:${jsonEncode(params)}';
}

/// Installs [DifyTestTranslator] for the tests of the calling file (call in `setUp` or at the top of `main`).
void useDifyTestTranslator() => DifyI18n.current = DifyTestTranslator();
