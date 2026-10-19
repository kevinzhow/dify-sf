// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/model-auth-dropdown/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

Json createProvider({Json? customConfiguration}) => {
  'provider': 'test',
  'custom_configuration': customConfiguration ?? {'status': 'active', 'available_credentials': <Object?>[]},
  'system_configuration': {'enabled': true, 'current_quota_type': 'trial', 'quota_configurations': <Object?>[]},
  'preferred_provider_type': 'system',
  'provider_credential_schema': {'credential_form_schemas': <Object?>[]},
};

CredentialPanelState createState({CardVariant variant = CardVariant.creditsActive, bool hasCredentials = false}) =>
    CredentialPanelState(
      variant: variant,
      priority: UsagePriority.credits,
      supportsCredits: true,
      showPrioritySwitcher: false,
      hasCredentials: hasCredentials,
      isCreditsExhausted: false,
      credits: 100,
    );

const key1 = {
  'status': 'active',
  'available_credentials': [
    {'credential_id': 'c1', 'credential_name': 'Key 1'},
  ],
  'current_credential_id': 'c1',
  'current_credential_name': 'Key 1',
};

late RecordingModelsApi api;
late WorkspaceModels models;

Future<void> render(WidgetTester t, Json provider, CredentialPanelState state) {
  api = RecordingModelsApi();
  models = WorkspaceModels(api, fixedLanguage: 'en_US');
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 400, top: 20),
        child: SizedBox(
          width: 120,
          child: ModelAuthDropdown(provider: provider, state: state),
        ),
      ),
    ),
    env: envOf(api, models: models),
  );
}

String buttonText(WidgetTester t) =>
    t.widget<DifyButton>(find.byKey(const ValueKey('model-auth-dropdown-trigger'))).semanticLabel!;
DifyButtonVariant buttonVariant(WidgetTester t) =>
    t.widget<DifyButton>(find.byKey(const ValueKey('model-auth-dropdown-trigger'))).variant;
Future<void> tapTrigger(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('model-auth-dropdown-trigger')));
  await settle(t);
}

final summary = <String, Object?>{
  'provider': 'test',
  'is_configured': true,
  'custom_configuration': {
    'available_credentials': [
      {'credential_id': 'c1', 'credential_name': 'Key 1'},
    ],
    'current_credential_id': 'c1',
    'current_credential_name': 'Key 1',
    'current_credential_usable': true,
  },
};

void main() {
  group('ModelAuthDropdown', () {
    group('Button text', () {
      testWidgets('should show "Add API Key" when no credentials for credits-active', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.creditsActive, hasCredentials: false));
        expect(buttonText(t), 'common.modelProvider.auth.addApiKey');
      });

      testWidgets('should show "Configure" when has credentials for api-active', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiActive, hasCredentials: true));
        expect(buttonText(t), 'common.operation.config');
      });

      testWidgets('should show "Add API Key" for api-required-add variant', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiRequiredAdd, hasCredentials: false));
        expect(buttonText(t), 'common.modelProvider.auth.addApiKey');
      });

      testWidgets('should show "Configure" for api-required-configure variant', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiRequiredConfigure, hasCredentials: true));
        expect(buttonText(t), 'common.operation.config');
      });

      testWidgets('should show "Configure" for credits-active when has credentials', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.creditsActive, hasCredentials: true));
        expect(buttonText(t), 'common.operation.config');
      });

      testWidgets('should show "Add API Key" for credits-exhausted (no credentials)', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.creditsExhausted, hasCredentials: false));
        expect(buttonText(t), 'common.modelProvider.auth.addApiKey');
      });

      testWidgets('should show "Configure" for api-unavailable (has credentials)', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiUnavailable, hasCredentials: true));
        expect(buttonText(t), 'common.operation.config');
      });

      testWidgets('should show "Configure" for api-fallback (has credentials)', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiFallback, hasCredentials: true));
        expect(buttonText(t), 'common.operation.config');
      });
    });

    group('Button variant styling', () {
      testWidgets('should use primary for api-required-add', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiRequiredAdd));
        expect(buttonVariant(t), DifyButtonVariant.primary);
      });

      testWidgets('should use primary for api-required-configure', (t) async {
        await render(t, createProvider(), createState(variant: CardVariant.apiRequiredConfigure, hasCredentials: true));
        expect(buttonVariant(t), DifyButtonVariant.primary);
      });
    });

    group('Popover behavior', () {
      testWidgets('should keep the popover open and allow retrying when loading a summary detail fails', (t) async {
        await render(t, {
          'provider': 'test',
          'plugin_id': 'test-plugin',
          'label': i18n('Test'),
          'supported_model_types': ['llm'],
          'configurate_methods': <Object?>[],
          'preferred_provider_type': 'system',
          'is_configured': true,
          'custom_configuration': {
            'status': 'active',
            'has_custom_models': false,
            'available_credentials': <Object?>[],
            'current_credential_usable': false,
          },
          'system_configuration': {'enabled': true},
        }, createState());
        final gate = api.hold['providers'] = Completer();
        api.fail['providers'] = Exception('500');
        await tapTrigger(t);
        expect(find.text('common.loading'), findsOneWidget);
        gate.complete();
        await settle(t);
        expect(find.text('common.api.actionFailed'), findsOneWidget);

        api.hold.remove('providers');
        api.fail.remove('providers');
        api.providersData = [createProvider()];
        await t.tap(find.text('common.operation.retry'));
        await settle(t);
        expect(find.text('common.modelProvider.card.noApiKeysTitle'), findsOneWidget);
        expect(api.callsOf('providers'), hasLength(2));
      });

      testWidgets('should open popover on button click and show dropdown content', (t) async {
        await render(
          t,
          createProvider(customConfiguration: key1),
          createState(variant: CardVariant.apiActive, hasCredentials: true),
        );
        await tapTrigger(t);
        expect(find.text('Key 1'), findsOneWidget);
      });

      testWidgets('should load provider detail on first click and reuse it on reopen', (t) async {
        await render(t, summary, createState(variant: CardVariant.apiActive, hasCredentials: true));
        api.providersData = [createProvider(customConfiguration: key1)];
        await tapTrigger(t);
        expect(find.text('Key 1'), findsOneWidget);
        expect(api.callsOf('providers'), hasLength(1));
        await tapTrigger(t);
        expect(find.text('Key 1'), findsNothing);
        await tapTrigger(t);
        expect(find.text('Key 1'), findsOneWidget);
        expect(api.callsOf('providers'), hasLength(1));
      });

      testWidgets('should render updated provider detail from the query cache', (t) async {
        await render(t, {
          'provider': 'test',
          'is_configured': true,
          'custom_configuration': {'available_credentials': <Object?>[], 'current_credential_usable': true},
        }, createState(variant: CardVariant.apiActive, hasCredentials: true));
        api.providersData = [createProvider(customConfiguration: key1)];
        await tapTrigger(t);
        expect(find.text('Key 1'), findsOneWidget);
        api.providersData = [
          createProvider(
            customConfiguration: const {
              'status': 'active',
              'available_credentials': [
                {'credential_id': 'c2', 'credential_name': 'Key 2'},
              ],
              'current_credential_id': 'c2',
              'current_credential_name': 'Key 2',
            },
          ),
        ];
        await models.updateModelProviders();
        await settle(t);
        expect(find.text('Key 2'), findsOneWidget);
        expect(find.text('Key 1'), findsNothing);
      });
    });
  });
}
