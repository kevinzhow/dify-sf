// dify-spec: web/app/components/header/account-setting/preference-page/__tests__/index.spec.tsx
//
// The Preferences tab: Dify's request mocks become the recording accounts API (`PATCH /v1/account/profile`, protocol
// 1.12), its `useLocale` the app's [AppLocale].
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/i18n/dify_locales.g.dart';
import 'package:dify_sf_app/src/settings/preference_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import '../auth/harness.dart' show authOn;
import '../dify_test_i18n.dart';
import '../members/harness.dart' show settle;

String _language(String value) => difyLanguages.firstWhere((l) => l.value == value).name;
String _timezone(String value) => difyTimezones.firstWhere((t) => t.value == value).name;

/// The page signed in as a profile with [language] and [timezone], the app's language [locale].
Future<(RecordingAuthApi, AppLocale)> _render(
  WidgetTester t, {
  String? locale = 'en-US',
  String language = 'en-US',
  String timezone = 'Pacific/Niue',
}) async {
  useDifyTestTranslator();
  final api = RecordingAuthApi();
  final a = api.addAccount(email: 'test@example.com', name: 'Test User');
  api.accounts['test@example.com'] = (
    account: a.copyWith(interfaceLanguage: language, timezone: timezone),
    password: 'Password123',
  );
  final auth = await authOn(api, signedInAs: 'test@example.com');
  final appLocale = AppLocale(locale ?? language, loader: (_) async {});
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: AuthScope(
          controller: auth,
          child: const Padding(padding: EdgeInsets.all(32), child: PreferencePage()),
        ),
      ),
      builder: (context, c) => AppLocaleScope(
        locale: appLocale,
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await settle(t);
  return (api, appLocale);
}

/// The combobox of the section titled [label] (the select named by it).
Finder _combobox(String label) => find.byKey(
  ValueKey(label == 'common.language.timezone' ? 'preference-timezone' : 'preference-language'),
);

/// Its shown value.
String? _shown(WidgetTester t, String label) =>
    t.getSemantics(find.descendant(of: _combobox(label), matching: find.bySemanticsLabel(label)).first).value;

Future<void> _select(WidgetTester t, String label, String option) async {
  await t.tap(_combobox(label));
  await settle(t, 3);
  await t.tap(find.text(option).last);
  await settle(t);
}

Map<String, Object?>? _profileCall(RecordingAuthApi api) =>
    api.calls.where((c) => c.$1 == 'updateProfile').map((c) => c.$2).firstOrNull;

void main() {
  group('PreferencePage - Rendering', () {
    testWidgets('should render default language and timezone labels', (t) async {
      // Dify's `useLocale()` is undefined: the profile's language shows (here the app has no other choice than it).
      await _render(t, locale: null, language: 'en-US', timezone: 'Pacific/Niue');
      expect(find.text('common.language.displayLanguage'), findsOneWidget);
      expect(find.text('common.language.timezone'), findsOneWidget);
      expect(_shown(t, 'common.language.displayLanguage'), _language('en-US'));
      expect(_shown(t, 'common.language.timezone'), _timezone('Pacific/Niue'));
    });

    testWidgets('should render placeholders when the current locale or timezone is unsupported', (t) async {
      await _render(t, locale: 'unsupported-locale', language: 'unsupported-locale', timezone: 'Unsupported/Timezone');
      expect(_shown(t, 'common.language.displayLanguage'), 'common.placeholder.select');
      expect(_shown(t, 'common.language.timezone'), 'common.placeholder.select');
    });
  });

  group('PreferencePage - Interactions', () {
    testWidgets('should show success toast when language updates', (t) async {
      final (api, locale) = await _render(t);
      await _select(t, 'common.language.displayLanguage', _language('zh-Hans'));
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
      // PATCH /v1/account/profile with the language only.
      expect(_profileCall(api), {'interface_language': 'zh-Hans'});
      // setLocaleOnClient: the app switches at once.
      expect(locale.language, 'zh-Hans');
    });

    testWidgets('should show error toast when language update fails', (t) async {
      final (api, locale) = await _render(t);
      api.failures['updateProfile'] = const TransportException('Update failed', statusCode: 400, code: 'bad_request');
      await _select(t, 'common.language.displayLanguage', _language('zh-Hans'));
      expect(find.text('Update failed'), findsOneWidget);
      expect(locale.language, 'en-US');
    });

    testWidgets('should show success toast when timezone updates', (t) async {
      final (api, _) = await _render(t);
      await _select(t, 'common.language.timezone', _timezone('Pacific/Midway'));
      expect(find.text('common.actionMsg.modifiedSuccessfully'), findsOneWidget);
      expect(_profileCall(api), {'timezone': 'Pacific/Midway'});
      // The account's time zone follows (the log pages read it).
      expect(_shown(t, 'common.language.timezone'), _timezone('Pacific/Midway'));
    });

    testWidgets('should show error toast when timezone update fails', (t) async {
      final (api, _) = await _render(t);
      api.failures['updateProfile'] = const TransportException('Timezone failed', statusCode: 400, code: 'bad_request');
      await _select(t, 'common.language.timezone', _timezone('Pacific/Midway'));
      expect(find.text('Timezone failed'), findsOneWidget);
      expect(_shown(t, 'common.language.timezone'), _timezone('Pacific/Niue'));
    });
  });
}
