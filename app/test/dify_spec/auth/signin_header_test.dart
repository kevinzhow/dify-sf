// dify-spec: web/app/signin/__tests__/_header.spec.tsx
import 'package:dify_sf_app/src/auth/widgets/auth_widgets.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

void main() {
  group('Signin Header', () {
    testWidgets('keeps the default Dify logo accessible name', (t) async {
      await renderAuth(t, await authOn(RecordingAuthApi()), const SignInHeader());
      expect(
        find.semantics.byPredicate((n) => n.getSemanticsData().flagsCollection.isImage && n.label == 'Dify'),
        findsOne,
      );
    });

    testWidgets('should switch locale without forcing a full page reload', (t) async {
      final loaded = <String>[];
      final locale = AppLocale('en-US', loader: (l) async => loaded.add(l));
      await renderAuth(t, await authOn(RecordingAuthApi()), const SignInHeader(), locale: locale);
      final element = t.element(find.byType(SignInHeader));
      await t.tap(find.byKey(const ValueKey('locale-menu')));
      await settleAuth(t, 3);
      await t.tap(find.text('日本語 (日本)'));
      await settleAuth(t, 3);
      expect(loaded, ['ja-JP']);
      expect(locale.language, 'ja-JP');
      // The same page, updated in place (Dify: `setLocaleOnClient(value, false)`).
      expect(t.element(find.byType(SignInHeader)), same(element));
    });
  });
}
