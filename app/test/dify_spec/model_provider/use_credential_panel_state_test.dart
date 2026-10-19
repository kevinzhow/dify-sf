// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/use-credential-panel-state.spec.ts
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

var mockTrialCredits = const TrialCredits(credits: 100, totalCredits: 10000, isExhausted: false);
const mockTrialModels = ['langgenius/openai/openai', 'langgenius/anthropic/anthropic'];

void setCredits({num? credits, bool? isExhausted}) => mockTrialCredits = TrialCredits(
  credits: credits ?? mockTrialCredits.credits,
  totalCredits: mockTrialCredits.totalCredits,
  isExhausted: isExhausted ?? mockTrialCredits.isExhausted,
);

CredentialPanelState renderPanelHook(ModelProvider? provider) => CredentialPanelState.of(
  provider,
  deploymentEdition: 'CLOUD',
  trialCredits: mockTrialCredits,
  trialModels: mockTrialModels,
);

const _defaultConfig = CustomConfiguration(
  status: 'active',
  currentCredentialId: 'cred-1',
  currentCredentialName: 'My Key',
  availableCredentials: [Credential(credentialId: 'cred-1', credentialName: 'My Key')],
);

ModelProvider createProvider({
  String provider = 'langgenius/openai/openai',
  CustomConfiguration customConfiguration = _defaultConfig,
  bool systemEnabled = true,
  String preferredProviderType = PreferredProviderTypeEnum.system,
}) => ModelProvider(
  provider: provider,
  customConfiguration: customConfiguration,
  systemConfigurationEnabled: systemEnabled,
  preferredProviderType: preferredProviderType,
  supportedModelTypes: const ['llm'],
);

void main() {
  group('useCredentialPanelState', () {
    setUp(() => mockTrialCredits = const TrialCredits(credits: 100, totalCredits: 10000, isExhausted: false));

    // Credits priority variants
    group('Credits priority variants', () {
      test('should return credits-active when credits available', () {
        final result = renderPanelHook(createProvider());

        expect(result.variant, CardVariant.creditsActive);
        expect(result.priority, UsagePriority.credits);
        expect(result.supportsCredits, isTrue);
      });

      test('should return api-fallback when credits exhausted but API key authorized', () {
        setCredits(isExhausted: true, credits: 0);

        expect(renderPanelHook(createProvider()).variant, CardVariant.apiFallback);
      });

      test('should return no-usage when credits exhausted and API key unauthorized', () {
        setCredits(isExhausted: true);
        final provider = createProvider(
          customConfiguration: const CustomConfiguration(
            status: 'active',
            availableCredentials: [Credential(credentialId: 'cred-1', credentialName: 'My Key')],
          ),
        );

        expect(renderPanelHook(provider).variant, CardVariant.noUsage);
      });

      test('should return no-usage when credits exhausted and selected API key is unavailable', () {
        setCredits(isExhausted: true, credits: 0);
        final provider = createProvider(
          customConfiguration: const CustomConfiguration(
            status: 'active',
            currentCredentialId: 'cred-1',
            currentCredentialName: 'Bad Key',
            availableCredentials: [
              Credential(credentialId: 'cred-1', credentialName: 'Bad Key', notAllowedToUse: true),
            ],
          ),
        );

        expect(renderPanelHook(provider).variant, CardVariant.noUsage);
      });

      test('should return credits-exhausted when credits exhausted and no credentials', () {
        setCredits(isExhausted: true);
        final provider = createProvider(
          customConfiguration: const CustomConfiguration(status: 'no-configure', availableCredentials: []),
        );

        expect(renderPanelHook(provider).variant, CardVariant.creditsExhausted);
      });
    });

    // API key priority variants
    group('API key priority variants', () {
      test('should return api-active when API key authorized', () {
        final result = renderPanelHook(createProvider(preferredProviderType: PreferredProviderTypeEnum.custom));

        expect(result.variant, CardVariant.apiActive);
        expect(result.priority, UsagePriority.apiKey);
      });

      test('should return credits-fallback when API key unauthorized and credits available', () {
        final provider = createProvider(
          preferredProviderType: PreferredProviderTypeEnum.custom,
          customConfiguration: const CustomConfiguration(
            status: 'active',
            availableCredentials: [Credential(credentialId: 'cred-1', credentialName: 'My Key')],
          ),
        );

        expect(renderPanelHook(provider).variant, CardVariant.creditsFallback);
      });

      test('should return credits-fallback when no credentials and credits available', () {
        final provider = createProvider(
          preferredProviderType: PreferredProviderTypeEnum.custom,
          customConfiguration: const CustomConfiguration(status: 'no-configure', availableCredentials: []),
        );

        expect(renderPanelHook(provider).variant, CardVariant.creditsFallback);
      });

      test('should return no-usage when no credentials and credits exhausted', () {
        setCredits(isExhausted: true, credits: 0);
        final provider = createProvider(
          preferredProviderType: PreferredProviderTypeEnum.custom,
          customConfiguration: const CustomConfiguration(status: 'no-configure', availableCredentials: []),
        );

        expect(renderPanelHook(provider).variant, CardVariant.noUsage);
      });

      test('should return api-unavailable when credential with name unauthorized and credits exhausted', () {
        setCredits(isExhausted: true, credits: 0);
        final provider = createProvider(
          preferredProviderType: PreferredProviderTypeEnum.custom,
          customConfiguration: const CustomConfiguration(
            status: 'active',
            currentCredentialName: 'Bad Key',
            availableCredentials: [Credential(credentialId: 'cred-1', credentialName: 'Bad Key')],
          ),
        );

        expect(renderPanelHook(provider).variant, CardVariant.apiUnavailable);
      });

      test('should return api-unavailable when selected API key is unavailable and credits are exhausted', () {
        setCredits(isExhausted: true, credits: 0);
        final provider = createProvider(
          preferredProviderType: PreferredProviderTypeEnum.custom,
          customConfiguration: const CustomConfiguration(
            status: 'active',
            currentCredentialId: 'cred-1',
            currentCredentialName: 'Bad Key',
            availableCredentials: [
              Credential(credentialId: 'cred-1', credentialName: 'Bad Key', notAllowedToUse: true),
            ],
          ),
        );

        expect(renderPanelHook(provider).variant, CardVariant.apiUnavailable);
      });

      test('should return api-required-configure when credentials exist but the current credential is incomplete', () {
        setCredits(isExhausted: true, credits: 0);
        final provider = createProvider(
          preferredProviderType: PreferredProviderTypeEnum.custom,
          customConfiguration: const CustomConfiguration(
            status: 'active',
            currentCredentialId: 'cred-1',
            availableCredentials: [Credential(credentialId: 'cred-1', credentialName: 'Bad Key')],
          ),
        );

        expect(renderPanelHook(provider).variant, CardVariant.apiRequiredConfigure);
      });
    });

    // apiKeyOnly priority
    group('apiKeyOnly priority (non-cloud / system disabled / not in trial_models)', () {
      test('should return apiKeyOnly when system config disabled', () {
        final result = renderPanelHook(createProvider(systemEnabled: false));

        expect(result.priority, UsagePriority.apiKeyOnly);
        expect(result.supportsCredits, isFalse);
      });

      test('should return apiKeyOnly when provider not in trial_models even if system enabled', () {
        final result = renderPanelHook(createProvider(provider: 'langgenius/minimax/minimax'));

        expect(result.priority, UsagePriority.apiKeyOnly);
        expect(result.supportsCredits, isFalse);
        expect(result.showPrioritySwitcher, isFalse);
      });
    });

    // Undefined provider
    group('Undefined provider', () {
      test('should return safe defaults when provider is undefined', () {
        final result = renderPanelHook(null);

        expect(result.priority, UsagePriority.apiKeyOnly);
        expect(result.supportsCredits, isFalse);
        expect(result.hasCredentials, isFalse);
        expect(result.credentialName, isNull);
      });
    });

    // Derived metadata
    group('Derived metadata', () {
      test('should show priority switcher when credits supported and custom config active', () {
        expect(renderPanelHook(createProvider()).showPrioritySwitcher, isTrue);
      });

      test('should hide priority switcher when system config disabled', () {
        expect(renderPanelHook(createProvider(systemEnabled: false)).showPrioritySwitcher, isFalse);
      });

      test('should hide priority switcher when provider not in trial_models', () {
        expect(renderPanelHook(createProvider(provider: 'langgenius/zhipuai/zhipuai')).showPrioritySwitcher, isFalse);
      });

      test('should expose credential name from provider', () {
        expect(renderPanelHook(createProvider()).credentialName, 'My Key');
      });

      test('should expose credits amount', () {
        setCredits(credits: 500);

        expect(renderPanelHook(createProvider()).credits, 500);
      });
    });
  });

  group('isDestructiveVariant', () {
    for (final (variant, expected) in const [
      (CardVariant.creditsExhausted, true),
      (CardVariant.noUsage, true),
      (CardVariant.apiUnavailable, true),
      (CardVariant.creditsActive, false),
      (CardVariant.apiFallback, false),
      (CardVariant.apiActive, false),
      (CardVariant.apiRequiredAdd, false),
      (CardVariant.apiRequiredConfigure, false),
    ]) {
      test('should return %s for variant %s', () {
        expect(isDestructiveVariant(variant), expected);
      });
    }
  });
}
