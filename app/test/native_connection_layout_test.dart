import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async => await DifyI18n.load('en-US'));
  for (final width in [320.0, 360.0, 412.0]) {
    testWidgets('native connection controls fit a $width px phone and remain reachable above the keyboard', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.physicalSize = Size(width, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        buildApp(
          AppSettings(serverUrl: '', journaled: true, lastDoc: ''),
          tokenStore: MemoryTokenStore(),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('locale-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-selector')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('locale-menu')));
      await t.pumpAndSettle();
      expect(find.text('English (United States)'), findsOneWidget);
      await t.tap(find.text('English (United States)'));
      await t.pumpAndSettle();
      t.view.viewInsets = const FakeViewPadding(bottom: 320);
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('server-address-connect')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('server-address-connect')).hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
