/// The colour theme: Dify's next-themes switch (web/app/layout.tsx `ThemeProvider attribute="data-theme"
/// defaultTheme="system" enableSystem`): the choice light | dark | system (default system) is remembered as `theme`,
/// system follows the platform's brightness. The resolved theme switches the token getters ([DifyColors.useDark]);
/// [DifyTheme.apply] then rebuilds and repaints everything, and tells the caches drawn from tokens
/// ([DifyTheme.changes]: canvas captures, the dot tile, code editor styles) to start over.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dify_icon.dart';
import 'dify_tokens.g.dart';

/// The theme choice (Dify's `Theme` values in types/app.ts and next-themes' `system`).
enum DifyThemeMode {
  light,
  dark,
  system;

  /// `light`, `dark` or `system`; null for anything else.
  static DifyThemeMode? parse(String? value) => switch (value) {
    'light' => light,
    'dark' => dark,
    'system' => system,
    _ => null,
  };
}

/// Switches the colour tokens between Dify's light and dark themes for the whole app.
abstract final class DifyTheme {
  static final _changes = _Changes();

  /// Notified after every switch, before the rebuild: caches of token colours that no rebuild reaches (offscreen
  /// captures, baked images, style caches) start over.
  static Listenable get changes => _changes;

  /// The icons to have decoded in the theme's colours before anything draws them (main: the canvas cards' icons,
  /// which are captured on their first paint). Evaluated with the new theme's tokens.
  static Iterable<(String, Color)> Function()? icons;

  static int _calls = 0;

  /// Switches to the dark (or light) theme: the icons of [icons] are decoded first, then the tokens switch, [changes]
  /// fire and every element rebuilds and every render object repaints (also `const` subtrees and painters that never
  /// repaint on their own). A later call wins over one still decoding.
  static Future<void> apply(bool dark) async {
    final call = ++_calls;
    if (dark == DifyColors.isDark) return;
    final list = icons;
    if (list != null) {
      // The icons' colours in the new theme, decoded while the old one still draws.
      DifyColors.useDark(dark);
      final wanted = list().toList();
      DifyColors.useDark(!dark);
      await IconCache.preload(wanted);
      if (call != _calls) return;
    }
    DifyColors.useDark(dark);
    _changes.changed();
    rebuildAll();
  }

  /// Invalidate offscreen captures after a newly registered font. Framework
  /// paragraphs relayout through Flutter's existing font-change notification.
  static void fontsChanged() => _changes.changed();

  /// Marks every element for a rebuild and every render object for a repaint.
  static void rebuildAll() {
    final binding = WidgetsBinding.instance;
    void build(Element e) {
      e.markNeedsBuild();
      e.visitChildren(build);
    }

    void paint(RenderObject r) {
      r.markNeedsPaint();
      r.visitChildren(paint);
    }

    final root = binding.rootElement;
    if (root != null) build(root);
    for (final view in binding.renderViews) {
      paint(view);
    }
  }
}

class _Changes extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// The app's theme choice: remembered (SharedPreferences `theme`), resolved against the platform's brightness for
/// [DifyThemeMode.system] (followed live), applied through [DifyTheme.apply].
class AppTheme extends ChangeNotifier with WidgetsBindingObserver {
  AppTheme(this._mode, {this.remember = true}) {
    WidgetsBinding.instance.addObserver(this);
  }

  /// The remembered choice, or [override] (the `--theme` / `?theme=` launch option) for this run. Applies it.
  static Future<AppTheme> load({String? override}) async {
    final stored = DifyThemeMode.parse((await SharedPreferences.getInstance()).getString(prefKey));
    final theme = AppTheme(DifyThemeMode.parse(override) ?? stored ?? DifyThemeMode.system);
    await theme._resolve();
    return theme;
  }

  /// Dify's storage key (next-themes' default `storageKey`).
  static const prefKey = 'theme';

  DifyThemeMode _mode;

  /// Whether [set] remembers the choice (tests turn it off).
  final bool remember;

  /// The choice: light, dark or system.
  DifyThemeMode get mode => _mode;

  /// Whether the dark theme is showing.
  bool get isDark => DifyColors.isDark;

  /// Switches to [mode] and remembers it.
  Future<void> set(DifyThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    if (remember) await (await SharedPreferences.getInstance()).setString(prefKey, mode.name);
    await _resolve();
    notifyListeners();
  }

  bool get _platformDark => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;

  Future<void> _resolve() => DifyTheme.apply(switch (_mode) {
    DifyThemeMode.light => false,
    DifyThemeMode.dark => true,
    DifyThemeMode.system => _platformDark,
  });

  @override
  void didChangePlatformBrightness() {
    if (_mode != DifyThemeMode.system) return;
    _resolve().then((_) => notifyListeners());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Provides the [AppTheme]; widgets that call [of] rebuild when the choice or the resolved theme changes.
class AppThemeScope extends InheritedNotifier<AppTheme> {
  const AppThemeScope({super.key, required AppTheme theme, required super.child}) : super(notifier: theme);

  /// The app's theme (subscribing); null without a scope.
  static AppTheme? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppThemeScope>()?.notifier;
}
