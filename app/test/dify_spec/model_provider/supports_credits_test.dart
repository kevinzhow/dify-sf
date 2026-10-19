// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/supports-credits.spec.ts
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

ModelProvider makeProvider({bool enabled = true}) =>
    ModelProvider(provider: 'langgenius/openai/openai', systemConfigurationEnabled: enabled);

void main() {
  group('providerSupportsCredits', () {
    test('returns true when the provider is system-enabled and listed in trial_models', () {
      expect(providerSupportsCredits(makeProvider(), ['langgenius/openai/openai'], 'CLOUD'), isTrue);
    });

    test('returns false when the provider is not listed in trial_models', () {
      expect(providerSupportsCredits(makeProvider(), ['langgenius/anthropic/anthropic'], 'CLOUD'), isFalse);
    });

    test('returns false when system hosting is disabled', () {
      expect(providerSupportsCredits(makeProvider(enabled: false), ['langgenius/openai/openai'], 'CLOUD'), isFalse);
    });

    test('returns false for an undefined provider', () {
      expect(providerSupportsCredits(null, ['langgenius/openai/openai'], 'CLOUD'), isFalse);
    });

    for (final deploymentEdition in const ['COMMUNITY', 'ENTERPRISE']) {
      test('returns false outside Cloud when deployment edition is %s', () {
        expect(providerSupportsCredits(makeProvider(), ['langgenius/openai/openai'], deploymentEdition), isFalse);
      });
    }
  });
}
