// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/credential-panel.spec.tsx
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart'
    show StatusDot, StatusDotKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

/// dify-sf is self-hosted: no AI credits, so the panel shows the API key states (Dify's `apiKeyOnly` priority);
/// the credit variants are Dify Cloud's.
Json createProvider({Json? customConfiguration, String preferred = 'custom', bool systemEnabled = false}) => {
  'provider': 'langgenius/openai/openai',
  'provider_credential_schema': {'credential_form_schemas': <Object?>[]},
  'custom_configuration':
      customConfiguration ??
      {
        'status': 'active',
        'current_credential_id': 'cred-1',
        'current_credential_name': 'test-credential',
        'available_credentials': [
          {'credential_id': 'cred-1', 'credential_name': 'test-credential'},
        ],
      },
  'system_configuration': {
    'enabled': systemEnabled,
    'current_quota_type': 'trial',
    'quota_configurations': <Object?>[],
  },
  'preferred_provider_type': preferred,
  'configurate_methods': ['predefined-model'],
  'supported_model_types': ['llm'],
};

const badKey = {
  'status': 'active',
  'current_credential_id': null,
  'current_credential_name': 'Bad Key',
  'available_credentials': [
    {'credential_id': 'cred-1', 'credential_name': 'Bad Key'},
  ],
};

Future<void> render(WidgetTester t, Json provider) => renderSettings(
  t,
  Align(
    alignment: Alignment.topLeft,
    child: CredentialPanel(provider: provider),
  ),
  env: envOf(RecordingModelsApi()),
);

StatusDotKind dot(WidgetTester t) => t.widget<StatusDot>(find.byType(StatusDot)).status;
Color? labelColor(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('credential-panel-label'))).style?.color;
CardVariant variant(WidgetTester t) => t.widget<ModelAuthDropdown>(find.byType(ModelAuthDropdown)).state.variant;
bool destructive(WidgetTester t) => t.widget<SystemQuotaCard>(find.byType(SystemQuotaCard)).destructive;
Finder get warningIcon => find.byWidgetPredicate((w) => w is DifyIcon && w.name.endsWith('alertsAndFeedback/warning'));

void main() {
  group('CredentialPanel', () {
    group('Status label variants', () {
      testWidgets('should show green indicator for api-active (custom priority + authorized)', (t) async {
        await render(t, createProvider());
        expect(dot(t), StatusDotKind.success);
        expect(find.text('test-credential'), findsOneWidget);
      });

      testWidgets('should NOT show warning icon for api-active variant', (t) async {
        await render(t, createProvider());
        expect(warningIcon, findsNothing);
      });

      testWidgets(
        'should show red indicator and credential name for api-unavailable (exhausted + named unauthorized key)',
        (
          t,
        ) async {
          await render(t, createProvider(customConfiguration: badKey));
          expect(dot(t), StatusDotKind.error);
          expect(find.text('Bad Key'), findsOneWidget);
        },
      );
    });

    group('Destructive styling', () {
      testWidgets('should apply destructive container for api-unavailable variant', (t) async {
        await render(t, createProvider(customConfiguration: badKey));
        expect(destructive(t), isTrue);
      });

      testWidgets('should apply default container for api-active', (t) async {
        await render(t, createProvider());
        expect(destructive(t), isFalse);
      });
    });

    group('Text color', () {
      testWidgets('should use destructive text color for api-unavailable credential name', (t) async {
        await render(t, createProvider(customConfiguration: badKey));
        expect(labelColor(t), DifyColors.textDestructive);
      });

      testWidgets('should use secondary text color for api-active credential name', (t) async {
        await render(t, createProvider());
        expect(labelColor(t), DifyColors.textSecondary);
      });
    });

    group('ModelAuthDropdown integration', () {
      testWidgets('should pass api-active variant for custom priority with authorized key', (t) async {
        await render(t, createProvider());
        expect(variant(t), CardVariant.apiActive);
      });
    });

    group('apiKeyOnly priority (system disabled)', () {
      testWidgets('should derive api-required-add when system config disabled and no credentials', (t) async {
        await render(
          t,
          createProvider(
            preferred: 'system',
            customConfiguration: const {'status': 'no-configure', 'available_credentials': <Object?>[]},
          ),
        );
        expect(variant(t), CardVariant.apiRequiredAdd);
        expect(find.text('common.modelProvider.card.apiKeyRequired'), findsOneWidget);
      });

      testWidgets('should derive api-active when system config disabled but has authorized key', (t) async {
        await render(t, createProvider(preferred: 'system'));
        expect(variant(t), CardVariant.apiActive);
      });
    });
  });
}
