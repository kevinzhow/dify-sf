import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dify_i18n.dart';
import 'dify_locales.g.dart';

/// The UI language, switchable at run time (Dify's `setLocaleOnClient(locale, false)`: no reload). Loads the
/// translations, remembers the choice and rebuilds whatever depends on [AppLocaleScope].
class AppLocale extends ChangeNotifier {
  AppLocale(this._language, {this.loader = _load});

  String _language;

  /// Loads and remembers a language (tests pass their own).
  final Future<void> Function(String language) loader;

  /// Dify's language code (`en-US`, `zh-Hans`, ...).
  String get language => _language;

  /// Loads the translations and switches to [language].
  Future<void> set(String language) async {
    if (language == _language) return;
    await loader(language);
    _language = language;
    notifyListeners();
  }

  static Future<void> _load(String language) async {
    await DifyI18n.load(language);
    final p = await SharedPreferences.getInstance();
    await p.setString(prefKey, language);
  }

  /// The remembered choice (SharedPreferences).
  static const prefKey = 'lang';

  static Future<String?> remembered() async => (await SharedPreferences.getInstance()).getString(prefKey);

  /// The languages of Dify's locale menu (`languages.filter(item => item.supported)`).
  static List<({String value, String name})> get supported => [
    for (final l in difyLanguages)
      if (l.supported) (value: l.value, name: l.name),
  ];
}

/// Provides the [AppLocale]; widgets that call [of] rebuild when the language changes.
class AppLocaleScope extends InheritedNotifier<AppLocale> {
  const AppLocaleScope({super.key, required AppLocale locale, required super.child}) : super(notifier: locale);

  /// The current language (subscribing); `en-US` without a scope.
  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLocaleScope>()?.notifier?.language ?? DifyI18n.fallbackLanguage;

  static AppLocale? read(BuildContext context) => context.getInheritedWidgetOfExactType<AppLocaleScope>()?.notifier;
}
