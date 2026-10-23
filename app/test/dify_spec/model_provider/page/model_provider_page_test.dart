// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/settings/model_provider/model_provider_page.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/settings/model_provider/system_model_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

/// mockProviders: OpenAI configured, Anthropic not.
List<Json> mockProviders() => [
  summaryJson(provider: 'openai', label: 'OpenAI'),
  summaryJson(provider: 'anthropic', label: 'Anthropic', isConfigured: false),
];

late RecordingModelsApi api;

Future<void> renderModelProviderPage(
  WidgetTester t, {
  List<Json>? providers,
  Map<String, Json?> defaults = const {},
  List<String> permissionKeys = managerPermissionKeys,
  String? searchText,
  bool summaryLoading = false,
  bool defaultsLoading = false,
}) async {
  api = RecordingModelsApi()..summaryData = providers ?? mockProviders();
  api.defaults.addAll(defaults);
  if (summaryLoading) api.hold['summaries'] = Completer();
  if (defaultsLoading) api.hold['defaultModel'] = Completer();
  await renderSettings(
    t,
    SingleChildScrollView(
      child: SizedBox(
        width: 1400,
        child: ModelProviderPage(searchText: searchText, stickyToolbar: true),
      ),
    ),
    env: envOf(api, permissionKeys: permissionKeys),
  );
}

List<String> cardOrder(WidgetTester t) => [
  for (final c in t.widgetList<ProviderAddedCard>(find.byType(ProviderAddedCard))) '${c.provider['provider']}',
];

Finder get noneConfigured => find.text('common.modelProvider.noneConfigured');

void main() {
  group('ModelProviderPage', () {
    testWidgets('should render main elements', (t) async {
      // dify-sf has no plugins: no auto-update setting and no marketplace section.
      await renderModelProviderPage(t);
      expect(find.text('common.modelProvider.searchModels'), findsOneWidget);
      expect(find.byType(SystemModelSelector), findsOneWidget);
    });

    testWidgets('should skip system model settings without plugin preference access', (t) async {
      await renderModelProviderPage(t, permissionKeys: const ['credential.use']);
      expect(api.callsOf('defaultModel'), isEmpty);
      expect(find.byType(SystemModelSelector), findsNothing);
    });

    testWidgets('should render configured and not configured providers sections', (t) async {
      await renderModelProviderPage(t);
      expect(cardOrder(t), ['openai', 'anthropic']);
      expect(find.text('common.modelProvider.toBeConfigured'), findsOneWidget);
      expect(t.widget<ProviderAddedCard>(find.byType(ProviderAddedCard).last).notConfigured, isTrue);
    });

    testWidgets('should show provider placeholders while model providers are loading', (t) async {
      await renderModelProviderPage(t, summaryLoading: true);
      expect(find.byType(ModelProviderListSkeleton), findsOneWidget);
      expect(find.bySemanticsLabel('common.loading'), findsOneWidget);
      expect(find.byType(ProviderAddedCard), findsNothing);
      expect(find.text('common.modelProvider.emptyProviderTitle'), findsNothing);
      expect(noneConfigured, findsNothing);
      api.hold['summaries']!.complete();
      await settle(t);
    });

    testWidgets('should filter providers based on search text', (t) async {
      await renderModelProviderPage(t, searchText: 'open');
      await t.pump(const Duration(milliseconds: 600));
      expect(cardOrder(t), ['openai']);
    });

    testWidgets('should not show not-set-up empty state when search has no matches', (t) async {
      await renderModelProviderPage(t, searchText: 'non-existent');
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('common.modelProvider.emptyProviderTitle'), findsNothing);
      expect(find.text('common.modelProvider.toBeConfigured'), findsNothing);
    });

    group('system model config status', () {
      testWidgets('should show none-configured warning when no configured providers exist', (t) async {
        await renderModelProviderPage(
          t,
          providers: [summaryJson(provider: 'anthropic', label: 'Anthropic', isConfigured: false)],
        );
        expect(noneConfigured, findsOneWidget);
        expect(find.text('common.modelProvider.notConfigured'), findsNothing);
        expect(find.text('common.modelProvider.emptyProviderTitle'), findsOneWidget);
        expect(cardOrder(t), ['anthropic']);
      });

      testWidgets('should show none-configured warning when providers exist but no default models set', (t) async {
        await renderModelProviderPage(t);
        expect(noneConfigured, findsOneWidget);
      });

      testWidgets('should render the none-configured warning inline with the system model selector', (t) async {
        await renderModelProviderPage(t);
        final warning = find.byKey(const ValueKey('model-provider-none-configured'));
        expect(find.descendant(of: warning, matching: noneConfigured), findsOneWidget);
        final selector = find.descendant(of: warning, matching: find.byType(SystemModelSelector));
        expect(selector, findsOneWidget);
        expect(t.widget<SystemModelSelector>(selector).notConfigured, isTrue);
        expect(t.widget<SystemModelSelector>(selector).compact, isTrue);
        expect(t.getSize(find.byKey(const ValueKey('system-model-selector-button'))).height, 24);
      });

      testWidgets('should not show warning when some default models are set', (t) async {
        await renderModelProviderPage(t, defaults: {'llm': defaultModelJson('openai', 'gpt-4')});
        expect(noneConfigured, findsNothing);
        expect(find.text('common.modelProvider.notConfigured'), findsNothing);
      });

      testWidgets('should not show warning when all default models are configured', (t) async {
        await renderModelProviderPage(
          t,
          defaults: {
            'llm': defaultModelJson('openai', 'gpt-4'),
            'text-embedding': defaultModelJson('openai', 'text-embedding-3', modelType: 'text-embedding'),
            'rerank': defaultModelJson('openai', 'rerank-v3', modelType: 'rerank'),
            'speech2text': defaultModelJson('openai', 'whisper-1', modelType: 'speech2text'),
            'tts': defaultModelJson('openai', 'tts-1', modelType: 'tts'),
          },
        );
        expect(find.text('common.modelProvider.noProviderInstalled'), findsNothing);
        expect(noneConfigured, findsNothing);
        expect(find.text('common.modelProvider.notConfigured'), findsNothing);
      });

      testWidgets('should not show warning while loading', (t) async {
        await renderModelProviderPage(t, defaultsLoading: true);
        expect(find.text('common.modelProvider.noProviderInstalled'), findsNothing);
        expect(noneConfigured, findsNothing);
        expect(find.text('common.modelProvider.notConfigured'), findsNothing);
        api.hold['defaultModel']!.complete();
        await settle(t);
      });
    });

    testWidgets('should prioritize fixed providers in visible order', (t) async {
      await renderModelProviderPage(
        t,
        providers: [
          summaryJson(provider: 'zeta-provider', label: 'Zeta Provider'),
          summaryJson(provider: 'langgenius/anthropic/anthropic', label: 'Anthropic Fixed'),
          // Dify counts OpenAI configured by its hosted quota; dify-sf has none, so it is configured by its key here.
          summaryJson(provider: 'langgenius/openai/openai', label: 'OpenAI Fixed'),
        ],
      );
      expect(cardOrder(t), ['langgenius/openai/openai', 'langgenius/anthropic/anthropic', 'zeta-provider']);
      expect(find.text('common.modelProvider.toBeConfigured'), findsNothing);
    });
  });
}
