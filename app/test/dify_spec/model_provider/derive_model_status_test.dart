// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/derive-model-status.spec.ts
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

CredentialPanelState createCredentialState({
  CardVariant variant = CardVariant.creditsActive,
  UsagePriority priority = UsagePriority.credits,
  bool supportsCredits = true,
  bool hasCredentials = false,
  bool isCreditsExhausted = false,
}) => CredentialPanelState(
  variant: variant,
  priority: priority,
  supportsCredits: supportsCredits,
  showPrioritySwitcher: true,
  hasCredentials: hasCredentials,
  isCreditsExhausted: isCreditsExhausted,
  credits: 100,
);

ModelItem createModelItem({String status = ModelStatusEnum.active}) => ModelItem(
  model: 'text-embedding-3-large',
  label: const {'en_US': 'Text Embedding 3 Large', 'zh_Hans': 'Text Embedding 3 Large'},
  modelType: ModelTypeEnum.textEmbedding,
  status: status,
);

ModelProvider createModelProvider() => const ModelProvider(provider: 'openai');

ProviderWithModels createModel() => ProviderWithModels(
  provider: 'openai',
  iconSmall: const {'en_US': '', 'zh_Hans': ''},
  label: const {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
  models: [createModelItem()],
);

void main() {
  group('deriveModelStatus', () {
    test('should return empty when model id or provider name is missing', () {
      expect(
        deriveModelStatus('', 'openai', createModelProvider(), createModelItem(), createCredentialState()),
        DerivedModelStatus.empty,
      );
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          '',
          createModelProvider(),
          createModelItem(),
          createCredentialState(),
        ),
        DerivedModelStatus.empty,
      );
    });

    test('should return incompatible when provider plugin is missing', () {
      expect(
        deriveModelStatus('text-embedding-3-large', 'openai', null, createModelItem(), createCredentialState()),
        DerivedModelStatus.incompatible,
      );
    });

    test('should return incompatible when model is missing from the provider list', () {
      expect(
        deriveModelStatus('text-embedding-3-large', 'openai', createModel(), null, createCredentialState()),
        DerivedModelStatus.incompatible,
      );
    });

    test('should return credits-exhausted when model is missing and AI credits are exhausted without api key', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          null,
          createCredentialState(priority: UsagePriority.apiKey, hasCredentials: false, isCreditsExhausted: true),
        ),
        DerivedModelStatus.creditsExhausted,
      );
    });

    test('should return configure-required when the model status is no-configure', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(status: ModelStatusEnum.noConfigure),
          createCredentialState(),
        ),
        DerivedModelStatus.configureRequired,
      );
    });

    test('should return disabled when the model status is disabled', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(status: ModelStatusEnum.disabled),
          createCredentialState(),
        ),
        DerivedModelStatus.disabled,
      );
    });

    test('should return credits-exhausted when credential state takes priority', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(),
          createCredentialState(isCreditsExhausted: true),
        ),
        DerivedModelStatus.creditsExhausted,
      );
    });

    test('should return api-key-unavailable when credential state is api-unavailable', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(),
          createCredentialState(variant: CardVariant.apiUnavailable, priority: UsagePriority.apiKey),
        ),
        DerivedModelStatus.apiKeyUnavailable,
      );
    });

    test('should return credits-exhausted when model status is quota exceeded', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(status: ModelStatusEnum.quotaExceeded),
          createCredentialState(priority: UsagePriority.apiKey),
        ),
        DerivedModelStatus.creditsExhausted,
      );
    });

    test('should return api-key-unavailable when model status is credential removed', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(status: ModelStatusEnum.credentialRemoved),
          createCredentialState(priority: UsagePriority.apiKey),
        ),
        DerivedModelStatus.apiKeyUnavailable,
      );
    });

    test('should return incompatible when model status is no-permission', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(status: ModelStatusEnum.noPermission),
          createCredentialState(priority: UsagePriority.apiKey),
        ),
        DerivedModelStatus.incompatible,
      );
    });

    test('should return active when model and credential state are available', () {
      expect(
        deriveModelStatus(
          'text-embedding-3-large',
          'openai',
          createModelProvider(),
          createModelItem(),
          createCredentialState(),
        ),
        DerivedModelStatus.active,
      );
    });
  });
}
