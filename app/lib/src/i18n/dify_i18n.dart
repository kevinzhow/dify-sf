import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Dify's translations (`assets/i18n/<language>/<namespace>.json`, copied from Dify by tool/gen_dify_i18n.py) with the
/// parts of i18next Dify uses: flat keys (`keySeparator: false`), `{{name}}` interpolation without escaping, plural
/// suffixes (`_one`, `_other`, …) chosen by `count`, and en-US as the fallback language.
///
/// Cards and other text measured outside the widget tree read it synchronously, so [load] runs before the app starts.
abstract class Translator {
  String t(String ns, String key, [Map<String, Object?> params = const {}]);
}

class DifyI18n implements Translator {
  DifyI18n._(this.language, this._bundles, this._fallback);

  static const fallbackLanguage = 'en-US';

  /// The translator in use. Tests may replace it (e.g. with [KeyEchoTranslator], as Dify's tests do).
  static Translator current = KeyEchoTranslator();

  /// Shorthand for `DifyI18n.current.t`.
  static String tr(String ns, String key, [Map<String, Object?> params = const {}]) => current.t(ns, key, params);

  final String language;
  final Map<String, Map<String, String>> _bundles, _fallback;

  /// Loads [namespaces] for [language] (and en-US) and makes it [current].
  static Future<DifyI18n> load(
    String language, {
    AssetBundle? bundle,
    List<String> namespaces = const [
      'workflow',
      'common',
      'plugin',
      'tools',
      'app',
      'time',
      'app-debug',
      'share',
      'pipeline',
      'plugin-trigger',
      'dataset',
      'dataset-settings',
      'dataset-creation',
      'dataset-documents',
      'agent-v-2',
      'app-overview',
      'login',
    ],
  }) async {
    final b = bundle ?? rootBundle;
    Future<Map<String, Map<String, String>>> read(String lang) async => {
      for (final ns in namespaces) ns: await _read(b, 'assets/i18n/$lang/$ns.json'),
    };
    final fallback = await read(fallbackLanguage);
    final i18n = DifyI18n._(language, language == fallbackLanguage ? fallback : await read(language), fallback);
    current = i18n;
    return i18n;
  }

  static Future<Map<String, String>> _read(AssetBundle b, String path) async {
    try {
      final json = jsonDecode(await b.loadString(path)) as Map<String, dynamic>;
      return {for (final e in json.entries) e.key: '${e.value}'};
    } catch (_) {
      return const {};
    }
  }

  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) {
    final count = params['count'];
    String? lookup(Map<String, Map<String, String>> bundles, String lang) {
      // Dify code names namespaces in camelCase (`appOverview`) for kebab-case files (`app-overview.json`).
      final b = bundles[ns] ?? bundles[ns.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}')];
      if (b == null) return null;
      if (count is num) {
        final hit = b['${key}_${pluralCategory(lang, count)}'] ?? b['${key}_other'];
        if (hit != null) return hit;
      }
      return b[key];
    }

    final text = lookup(_bundles, language) ?? lookup(_fallback, fallbackLanguage) ?? key;
    return interpolate(text, params);
  }

  /// `{{name}}` → the parameter's value (missing parameters stay as written, like i18next).
  static String interpolate(String text, Map<String, Object?> params) => params.isEmpty
      ? text
      : text.replaceAllMapped(RegExp(r'\{\{\s*([\w.]+)\s*\}\}'), (m) {
          final v = params[m[1]];
          return v == null ? m[0]! : '$v';
        });

  /// CLDR plural categories (what Intl.PluralRules gives i18next) for the languages Dify ships.
  static String pluralCategory(String language, num n) {
    final lang = language.split('-').first;
    final i = n.abs().floor(), whole = n == n.truncate();
    final m10 = i % 10, m100 = i % 100;
    switch (lang) {
      case 'zh' || 'ja' || 'ko' || 'id' || 'th' || 'vi' || 'lo':
        return 'other';
      case 'fr' || 'pt' || 'hi' || 'fa':
        return i == 0 || i == 1 ? 'one' : 'other';
      case 'ru' || 'uk':
        if (!whole) return 'other';
        if (m10 == 1 && m100 != 11) return 'one';
        if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'few';
        return 'many';
      case 'pl':
        if (!whole) return 'other';
        if (i == 1) return 'one';
        if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'few';
        return 'many';
      case 'ro':
        if (whole && i == 1) return 'one';
        if (!whole || i == 0 || (m100 >= 2 && m100 <= 19)) return 'few';
        return 'other';
      case 'sl':
        if (!whole) return 'few';
        if (m100 == 1) return 'one';
        if (m100 == 2) return 'two';
        if (m100 == 3 || m100 == 4) return 'few';
        return 'other';
      case 'ar':
        if (!whole) return 'other';
        if (i == 0) return 'zero';
        if (i == 1) return 'one';
        if (i == 2) return 'two';
        if (m100 >= 3 && m100 <= 10) return 'few';
        if (m100 >= 11) return 'many';
        return 'other';
      default: // en, de, es, it, nl, tr
        return whole && i == 1 ? 'one' : 'other';
    }
  }
}

/// The language of the loaded translations (`en-US` while none are, e.g. in tests).
String currentDifyLanguage() {
  final t = DifyI18n.current;
  return t is DifyI18n ? t.language : DifyI18n.fallbackLanguage;
}

/// Returns keys untranslated (Dify's tests' `withSelectorKey((key) => key)`).
class KeyEchoTranslator implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;
}

/// The Dify language for a locale (Dify's languages are `<language>-<region>`, Chinese by script).
String difyLanguageFor(Locale locale) {
  const languages = [
    'en-US', 'zh-Hans', 'zh-Hant', 'pt-BR', 'es-ES', 'fr-FR', 'de-DE', 'ja-JP', 'ko-KR', 'ru-RU', 'it-IT', //
    'th-TH', 'id-ID', 'uk-UA', 'vi-VN', 'ro-RO', 'pl-PL', 'hi-IN', 'tr-TR', 'fa-IR', 'sl-SI', 'nl-NL', 'ar-TN', 'lo-LA',
  ];
  if (locale.languageCode == 'zh') {
    final traditional =
        locale.scriptCode == 'Hant' || const {'TW', 'HK', 'MO'}.contains(locale.countryCode?.toUpperCase());
    return traditional ? 'zh-Hant' : 'zh-Hans';
  }
  final tag = '${locale.languageCode}-${locale.countryCode ?? ''}';
  if (languages.contains(tag)) return tag;
  return languages.firstWhere((l) => l.startsWith('${locale.languageCode}-'), orElse: () => DifyI18n.fallbackLanguage);
}
