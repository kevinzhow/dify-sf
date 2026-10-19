// dify-spec: web/app/components/base/__tests__/theme-selector.spec.tsx
import 'package:dify_sf_app/src/auth/widgets/auth_widgets.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

void main() {
  tearDown(() => DifyColors.useDark(false));

  group('ThemeSelector', () {
    // it.each: light, dark and system (`common.theme.auto`), from system.
    testWidgets('selects %s', (t) async {
      for (final (name, mode) in [
        ('common.theme.light', DifyThemeMode.light),
        ('common.theme.dark', DifyThemeMode.dark),
        ('common.theme.auto', DifyThemeMode.system),
      ]) {
        final theme = AppTheme(DifyThemeMode.system, remember: false);
        addTearDown(theme.dispose);
        if (mode == DifyThemeMode.system) await theme.set(DifyThemeMode.dark);
        await renderAuth(
          t,
          await authOn(RecordingAuthApi()),
          Align(
            alignment: Alignment.topRight,
            child: ThemeSelector(theme: theme),
          ),
          theme: theme,
        );
        await t.tap(find.bySemanticsLabel('common.theme.theme'));
        await settleAuth(t, 3);
        final item = find.semantics.byPredicate(
          (n) => n.getSemanticsData().role == SemanticsRole.menuItemRadio && n.label == name,
          describeMatch: (_) => 'menuitemradio "$name"',
        );
        expect(item, findsOne);
        await t.tap(find.text(name));
        await settleAuth(t, 3);
        expect(theme.mode, mode);
      }
    });
  });

  testWidgets('the sign-in header shows the theme selector after the locale menu, with the current choice\'s icon', (
    t,
  ) async {
    final theme = AppTheme(DifyThemeMode.dark, remember: false);
    addTearDown(theme.dispose);
    await renderAuth(t, await authOn(RecordingAuthApi()), const SignInHeader(), theme: theme);
    expect(find.byKey(const ValueKey('theme-selector')), findsOneWidget);
    expect(find.bySemanticsLabel('common.theme.theme'), findsOneWidget);
  });
}
