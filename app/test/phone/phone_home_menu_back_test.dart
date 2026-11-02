// The real phone home with a real provider menu open on the Integrations tab (Winnie's review reproduction for
// PR 82): one back closes only the menu, the next returns to the Studio.
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/shell/phone_home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import '../support/model_fakes.dart';
import 'phone_harness.dart';

Finder destination(String name) => find.descendant(
  of: find.byKey(const ValueKey('phone-home-navigation')),
  matching: find.text(name),
);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('back from a provider menu preserves the Integrations tab', (t) async {
    phoneWindow(t);
    final w = await workspace();
    final settings = await AppSettings.load();
    final models = RecordingModelsApi()
      ..summaryData = [summaryJson()]
      ..providersData = [providerJson()];
    await t.pumpWidget(
      DifyApplication(
        edgeToEdge: true,
        theme: difyTheme(),
        home: AuthScope(
          controller: w.auth,
          child: HomePage(
            settings: settings,
            backendFor: (_) => FakeAppsBackend(w.api),
            appsApiFor: (_) => w.api,
            modelsApiFor: (_) => models,
            studioPollInterval: null,
          ),
        ),
        builder: (_, child) => AppLocaleScope(locale: AppLocale('en-US'), child: child!),
      ),
    );
    await settle(t);
    await t.tap(destination('Integrations'));
    await settle(t);
    expect(t.widget<PhoneHomeShell>(find.byType(PhoneHomeShell)).tab, HomeTab.integrations);
    final trigger = find.byKey(const ValueKey('model-auth-dropdown-trigger'));
    expect(trigger, findsWidgets);
    await t.ensureVisible(trigger.first);
    await t.tap(trigger.first);
    await settle(t);
    final popup = find.byKey(const ValueKey('api-key-section-add'));
    expect(popup, findsWidgets, reason: 'the real provider menu is open');
    await systemBack(t);
    final after = t.widget<PhoneHomeShell>(find.byType(PhoneHomeShell)).tab;
    final popupClosed = popup.evaluate().isEmpty;
    expect(popupClosed, isTrue);
    expect(after, HomeTab.integrations, reason: 'one back should close only the provider menu');
    await systemBack(t);
    expect(t.widget<PhoneHomeShell>(find.byType(PhoneHomeShell)).tab, HomeTab.studio);
    await unmount(t);
  });
}
