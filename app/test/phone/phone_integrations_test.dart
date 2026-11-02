/// Integrations on a phone: its own large app bar, one column (no 200 px section sidebar), the provider cards across
/// the width, and the toolbar's popups and dialogs fitting a 360 dp window; back closes them first.
library;

import 'package:dify_sf_app/src/cards/provider_icon_image.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings/integrations_page.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import '../support/model_fakes.dart';
import 'phone_harness.dart';

Future<void> _pump(WidgetTester t) async {
  final env = envOf(
    RecordingModelsApi()
      ..summaryData = [
        summaryJson(),
        summaryJson(provider: 'langgenius/anthropic/anthropic', label: 'Anthropic', isConfigured: false),
        summaryJson(
          provider: 'langgenius/ollama/ollama',
          label: 'Ollama with a provider name long enough to wrap',
          isConfigured: false,
          configurateMethods: const ['customizable-model'],
        ),
      ],
  );
  await t.pumpWidget(
    DifyApplication(
      edgeToEdge: true,
      theme: difyTheme(),
      home: DifyPage(
        edgeToEdge: true,
        body: ModelProviderScope(
          env: env,
          child: ProviderIconScope(source: env.models.icons, child: const IntegrationsPage()),
        ),
      ),
      builder: (context, child) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            child!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await settle(t);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });

  for (final w in phoneWindows) {
    testWidgets('${w.name}: one column under its own app bar, cards across the width, no overflow', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      await _pump(t);
      expect(t.takeException(), isNull);
      expect(find.byType(DifyTopAppBar), findsOneWidget);
      final title = find.descendant(of: find.byType(DifyTopAppBar), matching: find.text('Integrations'));
      expect(t.getRect(title), insideSafeArea(w.size, w.insets));
      // No section sidebar: the section's title and the search span the page.
      expect(find.text('Model Provider'), findsOneWidget);
      final search = t.getRect(find.byKey(const ValueKey('model-provider-search')));
      expect(search.left, 16);
      expect(search.right, greaterThan(w.size.width - 16 - 48), reason: 'the search spans the width');
      final cards = find.byKey(const ValueKey('provider-added-card'));
      expect(cards, findsWidgets);
      for (final card in t.widgetList(cards)) {
        final r = t.getRect(find.byWidget(card));
        expect(r.left, 16);
        expect(r.right, w.size.width - 16);
      }
    });
  }

  testWidgets('360 dp: the default model settings fit; back closes them before the page', (t) async {
    phoneWindow(t, size: const Size(360, 780));
    await _pump(t);
    await t.tap(find.byKey(const ValueKey('system-model-selector-button')));
    await settle(t);
    expect(find.byKey(const ValueKey('system-model-save')), findsOneWidget);
    expect(t.takeException(), isNull, reason: 'the dialog fits 360 dp');
    expect(await systemBack(t), isTrue);
    expect(find.byKey(const ValueKey('system-model-save')), findsNothing);
    expect(find.byType(IntegrationsPage), findsOneWidget);
  });

  testWidgets('360 dp: a provider card\'s credential menu and the credential dialog fit', (t) async {
    phoneWindow(t, size: const Size(360, 780));
    await _pump(t);
    final trigger = find.byKey(const ValueKey('model-auth-dropdown-trigger'));
    expect(trigger, findsWidgets);
    await t.ensureVisible(trigger.first);
    await t.tap(trigger.first);
    await settle(t);
    expect(t.takeException(), isNull, reason: 'the credential menu fits 360 dp');
    final add = find.byKey(const ValueKey('api-key-section-add'));
    if (add.evaluate().isNotEmpty) {
      await t.tap(add.first);
      await settle(t);
      expect(t.takeException(), isNull, reason: 'the credential dialog fits 360 dp');
      expect(await systemBack(t), isTrue);
    } else {
      expect(await systemBack(t), isTrue, reason: 'back closes the menu');
    }
    expect(find.byType(IntegrationsPage), findsOneWidget);
  });

  testWidgets('pushed from elsewhere on a phone (the editor) it is a page with a back button', (t) async {
    phoneWindow(t);
    final env = envOf(RecordingModelsApi()..summaryData = [summaryJson()]);
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      DifyApplication(
        navigatorKey: nav,
        edgeToEdge: true,
        theme: difyTheme(),
        home: const DifyPage(body: SizedBox()),
      ),
    );
    final shown = showIntegrationsSetting(nav.currentContext!, env: env);
    await settle(t);
    expect(find.byType(IntegrationsSettingModal), findsNothing);
    expect(find.byType(IntegrationsPage), findsOneWidget);
    expect(find.byType(DifyAppBarBackButton), findsOneWidget);
    await t.tap(find.byType(DifyAppBarBackButton));
    await settle(t);
    await shown;
    expect(find.byType(IntegrationsPage), findsNothing);
  });
}
