/// What the app knows about the workspace's model providers and models, shaped after Dify's data
/// (model-provider-page/declarations.ts, model-selector/types.ts and the console API responses they come from), and
/// the pure logic Dify derives from it for the model selector: getCurrentProviderAndModel (hooks.ts),
/// useCredentialStatus, useCredentialPanelState, useTrialCredits, providerSupportsCredits, deriveModelStatus and the
/// formatting helpers of utils.ts.
library;

/// An `I18nObject` / `TypeWithI18N`: text per language (`en_US`, `zh_Hans`, …).
typedef I18nText = Map<String, String?>;

/// renderI18nObject (i18n-config): the text in [language], else `en_US`, else the first non-empty one, else ''.
String renderI18nObject(I18nText? obj, String language) {
  if (obj == null) return '';
  final own = obj[language];
  if (own != null && own.isNotEmpty) return own;
  final en = obj['en_US'];
  if (en != null && en.isNotEmpty) return en;
  return obj.values.firstWhere((v) => v != null && v.isNotEmpty, orElse: () => '') ?? '';
}

/// useLanguage (hooks.ts): the locale with its first `-` replaced by `_` (`en-US` → `en_US`).
String languageOfLocale(String locale) => locale.replaceFirst('-', '_');

/// ModelTypeEnum.
abstract final class ModelTypeEnum {
  static const textGeneration = 'llm';
  static const textEmbedding = 'text-embedding';
  static const rerank = 'rerank';
  static const speech2text = 'speech2text';
  static const moderation = 'moderation';
  static const tts = 'tts';
}

/// ModelStatusEnum.
abstract final class ModelStatusEnum {
  static const active = 'active';
  static const noConfigure = 'no-configure';
  static const quotaExceeded = 'quota-exceeded';
  static const noPermission = 'no-permission';
  static const disabled = 'disabled';
  static const credentialRemoved = 'credential-removed';
}

/// ModelFeatureEnum.
abstract final class ModelFeatureEnum {
  static const toolCall = 'tool-call';
  static const multiToolCall = 'multi-tool-call';
  static const agentThought = 'agent-thought';
  static const streamToolCall = 'stream-tool-call';
  static const vision = 'vision';
  static const video = 'video';
  static const document = 'document';
  static const audio = 'audio';
  static const polling = 'polling';
  static const structuredOutput = 'structured-output';
}

/// ModelFeatureTextEnum.
const modelFeatureText = {
  ModelFeatureEnum.vision: 'Vision',
  ModelFeatureEnum.video: 'Video',
  ModelFeatureEnum.document: 'Document',
  ModelFeatureEnum.audio: 'Audio',
};

/// PreferredProviderTypeEnum.
abstract final class PreferredProviderTypeEnum {
  static const system = 'system';
  static const custom = 'custom';
}

/// sizeFormat (utils.ts): `500`, `1K`, `4K`.
String sizeFormat(num size) {
  final remainder = (size / 1000).floor();
  if (remainder < 1) return size is int || size != size.roundToDouble() ? '$size' : '${size.toInt()}';
  return '${remainder}K';
}

/// modelTypeFormat (utils.ts).
String modelTypeFormat(String modelType) =>
    modelType == ModelTypeEnum.textEmbedding ? 'TEXT EMBEDDING' : modelType.toUpperCase();

I18nText _i18n(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value?.toString()} : const {};
I18nText? _i18nOrNull(Object? v) => v is Map ? _i18n(v) : null;
String _s(Object? v) => v is String ? v : '';
String? _sOrNull(Object? v) => v is String ? v : null;
Map<String, Object?> _m(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : const {};
List<Object?> _l(Object? v) => v is List ? v : const [];

/// A model as the model lists return it (ModelItem / ProviderModelWithStatusEntity / ModelSelectorModel).
class ModelItem {
  const ModelItem({
    required this.model,
    this.label = const {},
    this.modelType = ModelTypeEnum.textGeneration,
    this.features,
    this.fetchFrom = 'predefined-model',
    this.status = ModelStatusEnum.active,
    this.modelProperties = const {},
    this.loadBalancingEnabled = false,
    this.deprecated = false,
    this.hasInvalidLoadBalancingConfigs = false,
  });

  factory ModelItem.fromJson(Object? json) {
    final m = _m(json);
    final features = m['features'];
    return ModelItem(
      model: _s(m['model']),
      label: _i18n(m['label']),
      modelType: _s(m['model_type']),
      features: features is List ? [for (final f in features) '$f'] : null,
      fetchFrom: _s(m['fetch_from']),
      status: _s(m['status']),
      modelProperties: _m(m['model_properties']),
      loadBalancingEnabled: m['load_balancing_enabled'] == true,
      deprecated: m['deprecated'] == true,
      hasInvalidLoadBalancingConfigs: m['has_invalid_load_balancing_configs'] == true,
    );
  }

  final String model;
  final I18nText label;
  final String modelType;
  final List<String>? features;
  final String fetchFrom;

  /// One of [ModelStatusEnum] (other values are treated as Dify treats them: incompatible).
  final String status;

  /// `mode` (`chat` / `completion`), `context_size`, …
  final Map<String, Object?> modelProperties;
  final bool loadBalancingEnabled;
  final bool deprecated;
  final bool hasInvalidLoadBalancingConfigs;

  String get mode => _s(modelProperties['mode']);
}

/// A provider with its models of one type (ProviderWithModelsResponse / ModelSelectorProvider): an entry of
/// `GET workspaces/current/models/model-types/{type}`.
class ProviderWithModels {
  const ProviderWithModels({
    required this.provider,
    this.label = const {},
    this.iconSmall,
    this.iconSmallDark,
    this.models = const [],
    this.status = 'active',
  });

  factory ProviderWithModels.fromJson(Object? json) {
    final m = _m(json);
    return ProviderWithModels(
      provider: _s(m['provider']),
      label: _i18n(m['label']),
      iconSmall: _i18nOrNull(m['icon_small']),
      iconSmallDark: _i18nOrNull(m['icon_small_dark']),
      models: [for (final i in _l(m['models'])) ModelItem.fromJson(i)],
      status: _s(m['status']),
    );
  }

  final String provider;
  final I18nText label;
  final I18nText? iconSmall;
  final I18nText? iconSmallDark;
  final List<ModelItem> models;

  /// CustomConfigurationStatus: `active` / `no-configure`.
  final String status;
}

/// A stored provider credential (Credential / CredentialConfiguration).
class Credential {
  const Credential({required this.credentialId, this.credentialName, this.notAllowedToUse});

  factory Credential.fromJson(Object? json) {
    final m = _m(json);
    return Credential(
      credentialId: _s(m['credential_id']),
      credentialName: _sOrNull(m['credential_name']),
      notAllowedToUse: m['not_allowed_to_use'] is bool ? m['not_allowed_to_use']! as bool : null,
    );
  }

  final String credentialId;
  final String? credentialName;
  final bool? notAllowedToUse;
}

/// A provider's `custom_configuration` (the summary's has `current_credential_usable`; ModelProvider's does not).
class CustomConfiguration {
  const CustomConfiguration({
    this.status = 'no-configure',
    this.currentCredentialId,
    this.currentCredentialName,
    this.availableCredentials,
    this.currentCredentialUsable,
  });

  factory CustomConfiguration.fromJson(Object? json) {
    final m = _m(json);
    final creds = m['available_credentials'];
    return CustomConfiguration(
      status: _s(m['status']),
      currentCredentialId: _sOrNull(m['current_credential_id']),
      currentCredentialName: _sOrNull(m['current_credential_name']),
      availableCredentials: creds is List ? [for (final c in creds) Credential.fromJson(c)] : null,
      currentCredentialUsable: m['current_credential_usable'] is bool ? m['current_credential_usable']! as bool : null,
    );
  }

  final String status;
  final String? currentCredentialId;
  final String? currentCredentialName;
  final List<Credential>? availableCredentials;
  final bool? currentCredentialUsable;
}

/// An installed model provider (ModelProvider / ModelProviderSummaryResponse): an entry of
/// `GET workspaces/current/model-providers/summary`.
class ModelProvider {
  const ModelProvider({
    required this.provider,
    this.label = const {},
    this.iconSmall,
    this.iconSmallDark,
    this.supportedModelTypes = const [],
    this.preferredProviderType = PreferredProviderTypeEnum.custom,
    this.customConfiguration = const CustomConfiguration(),
    this.systemConfigurationEnabled = false,
  });

  factory ModelProvider.fromJson(Object? json) {
    final m = _m(json);
    return ModelProvider(
      provider: _s(m['provider']),
      label: _i18n(m['label']),
      iconSmall: _i18nOrNull(m['icon_small']),
      iconSmallDark: _i18nOrNull(m['icon_small_dark']),
      supportedModelTypes: [for (final t in _l(m['supported_model_types'])) '$t'],
      preferredProviderType: _s(m['preferred_provider_type']),
      customConfiguration: CustomConfiguration.fromJson(m['custom_configuration']),
      systemConfigurationEnabled: _m(m['system_configuration'])['enabled'] == true,
    );
  }

  final String provider;
  final I18nText label;
  final I18nText? iconSmall;
  final I18nText? iconSmallDark;
  final List<String> supportedModelTypes;

  /// [PreferredProviderTypeEnum].
  final String preferredProviderType;
  final CustomConfiguration customConfiguration;

  /// `system_configuration.enabled` (system-hosted credits).
  final bool systemConfigurationEnabled;
}

/// The workspace's AI credit pool (useTrialCredits over `GET workspaces/current/model-providers/credits`).
class TrialCredits {
  const TrialCredits({
    this.credits = 0,
    this.usedCredits = 0,
    this.totalCredits = 0,
    this.isUnlimited = false,
    this.isExhausted = true,
    this.isLoading = false,
    this.exhaustedAt,
    this.nextCreditResetDate,
  });

  /// useTrialCredits: [json] is the response (null while not loaded), [isPending] the query's pending flag.
  factory TrialCredits.select(Map<String, Object?>? json, {bool isPending = false}) {
    if (json == null) return TrialCredits(isLoading: isPending);
    num n(Object? v) => v is num ? v : 0;
    return TrialCredits(
      credits: n(json['remaining_credits']),
      usedCredits: n(json['quota_used']),
      totalCredits: n(json['quota_limit']),
      isUnlimited: json['is_unlimited'] == true,
      isExhausted: json['is_exhausted'] == true,
      exhaustedAt: json['exhausted_at'] is num ? json['exhausted_at']! as num : null,
      nextCreditResetDate: json['next_credit_reset_date'] is num ? json['next_credit_reset_date']! as num : null,
    );
  }

  final num credits;
  final num usedCredits;
  final num totalCredits;
  final bool isUnlimited;
  final bool isExhausted;
  final bool isLoading;
  final num? exhaustedAt;
  final num? nextCreditResetDate;
}

/// The selector's value: `{provider, model}` (DefaultModel / ModelSelectorValue).
typedef DefaultModel = ({String provider, String model});

/// getCurrentProviderAndModel (hooks.ts): the first provider named like [defaultModel]'s, and its model of that name.
({ProviderWithModels? currentProvider, ModelItem? currentModel}) getCurrentProviderAndModel(
  List<ProviderWithModels> modelList,
  DefaultModel? defaultModel,
) {
  final provider = modelList.where((p) => p.provider == defaultModel?.provider).firstOrNull;
  final model = provider?.models.where((m) => m.model == defaultModel?.model).firstOrNull;
  return (currentProvider: provider, currentModel: model);
}

/// providerSupportsCredits (supports-credits.ts).
bool providerSupportsCredits(ModelProvider? provider, List<String>? trialModels, String deploymentEdition) {
  if (deploymentEdition != 'CLOUD' || provider == null || !provider.systemConfigurationEnabled) return false;
  return provider.provider.isNotEmpty && (trialModels?.contains(provider.provider) ?? false);
}

/// useCredentialStatus (model-auth/hooks/use-credential-status.ts).
class CredentialStatus {
  const CredentialStatus._({
    required this.hasCredential,
    required this.authorized,
    required this.authRemoved,
    this.currentCredentialId,
    this.currentCredentialName,
    this.availableCredentials,
    this.notAllowedToUse,
  });

  factory CredentialStatus.of(ModelProvider? provider) {
    final c = provider?.customConfiguration;
    final id = c?.currentCredentialId;
    final name = c?.currentCredentialName;
    final available = c?.availableCredentials;
    final hasCredential = available?.isNotEmpty ?? false;
    final authRemoved = hasCredential && (id == null || id.isEmpty) && (name == null || name.isEmpty);
    final current = available?.where((x) => x.credentialId == id).firstOrNull;
    final usable = c?.currentCredentialUsable;
    final notAllowed = usable == false ? true : current?.notAllowedToUse;
    final authorized = usable ?? (id != null && id.isNotEmpty && name != null && name.isNotEmpty && notAllowed != true);
    return CredentialStatus._(
      hasCredential: hasCredential,
      authorized: authorized,
      authRemoved: authRemoved,
      currentCredentialId: id,
      currentCredentialName: name,
      availableCredentials: available,
      notAllowedToUse: notAllowed,
    );
  }

  final bool hasCredential;
  final bool authorized;
  final bool authRemoved;
  final String? currentCredentialId;
  final String? currentCredentialName;
  final List<Credential>? availableCredentials;
  final bool? notAllowedToUse;
}

/// UsagePriority.
enum UsagePriority { credits, apiKey, apiKeyOnly }

/// CardVariant.
enum CardVariant {
  creditsActive('credits-active'),
  creditsFallback('credits-fallback'),
  creditsExhausted('credits-exhausted'),
  noUsage('no-usage'),
  apiFallback('api-fallback'),
  apiActive('api-active'),
  apiRequiredAdd('api-required-add'),
  apiRequiredConfigure('api-required-configure'),
  apiUnavailable('api-unavailable');

  const CardVariant(this.value);
  final String value;
}

/// isDestructiveVariant.
bool isDestructiveVariant(CardVariant v) =>
    v == CardVariant.creditsExhausted || v == CardVariant.noUsage || v == CardVariant.apiUnavailable;

/// useCredentialPanelState (provider-added-card/use-credential-panel-state.ts).
class CredentialPanelState {
  const CredentialPanelState({
    required this.variant,
    required this.priority,
    required this.supportsCredits,
    required this.showPrioritySwitcher,
    required this.hasCredentials,
    required this.isCreditsExhausted,
    this.credentialName,
    this.credits = 0,
  });

  factory CredentialPanelState.of(
    ModelProvider? provider, {
    required String deploymentEdition,
    required TrialCredits trialCredits,
    List<String> trialModels = const [],
  }) {
    final status = CredentialStatus.of(provider);
    // The trial-models query only runs on Cloud; providerSupportsCredits is false elsewhere anyway.
    final supportsCredits = providerSupportsCredits(provider, trialModels, deploymentEdition);
    final priority = !supportsCredits
        ? UsagePriority.apiKeyOnly
        : provider?.preferredProviderType == PreferredProviderTypeEnum.system
        ? UsagePriority.credits
        : UsagePriority.apiKey;
    return CredentialPanelState(
      variant: _deriveVariant(
        priority,
        trialCredits.isExhausted,
        status.hasCredential,
        status.authorized,
        status.currentCredentialName,
      ),
      priority: priority,
      supportsCredits: supportsCredits,
      showPrioritySwitcher: supportsCredits,
      hasCredentials: status.hasCredential,
      isCreditsExhausted: trialCredits.isExhausted,
      credentialName: status.currentCredentialName,
      credits: trialCredits.credits,
    );
  }

  static CardVariant _deriveVariant(
    UsagePriority priority,
    bool isExhausted,
    bool hasCredential,
    bool authorized,
    String? credentialName,
  ) {
    if (priority == UsagePriority.credits) {
      if (!isExhausted) return CardVariant.creditsActive;
      if (hasCredential && authorized) return CardVariant.apiFallback;
      if (hasCredential && !authorized) return CardVariant.noUsage;
      return CardVariant.creditsExhausted;
    }
    if (hasCredential && authorized) return CardVariant.apiActive;
    if (priority == UsagePriority.apiKey && !isExhausted) return CardVariant.creditsFallback;
    if (priority == UsagePriority.apiKey && !hasCredential) return CardVariant.noUsage;
    if (hasCredential && !authorized) {
      return credentialName != null && credentialName.isNotEmpty
          ? CardVariant.apiUnavailable
          : CardVariant.apiRequiredConfigure;
    }
    return CardVariant.apiRequiredAdd;
  }

  final CardVariant variant;
  final UsagePriority priority;
  final bool supportsCredits;
  final bool showPrioritySwitcher;
  final bool hasCredentials;
  final bool isCreditsExhausted;
  final String? credentialName;
  final num credits;
}

/// DerivedModelStatus (derive-model-status.ts), with the English texts of the badge and tooltip i18n keys
/// (`common.modelProvider.selector.*`).
enum DerivedModelStatus {
  empty('empty'),
  active('active'),
  configureRequired('configure-required', badge: 'Configure required'),
  creditsExhausted(
    'credits-exhausted',
    badge: 'Credits exhausted',
    tooltip: 'Your AI credits have been exhausted. Please upgrade your plan or add an API key.',
  ),
  apiKeyUnavailable(
    'api-key-unavailable',
    badge: 'API Key unavailable',
    tooltip: 'The API key has been removed. Please configure a new API key.',
  ),
  disabled('disabled', badge: 'Disabled'),
  incompatible('incompatible', badge: incompatibleLabel, tooltip: incompatibleTip);

  const DerivedModelStatus(this.value, {this.badge, this.tooltip});
  final String value;

  /// DERIVED_MODEL_STATUS_BADGE_I18N.
  final String? badge;

  /// DERIVED_MODEL_STATUS_TOOLTIP_I18N.
  final String? tooltip;

  static const incompatibleLabel = 'Incompatible';
  static const incompatibleTip =
      'This model is not available in the current version. Please select another available model.';
}

/// deriveModelStatus. [currentModelProvider]: the installed provider (any non-null object counts, as in Dify).
DerivedModelStatus deriveModelStatus(
  String? modelId,
  String? providerName,
  Object? currentModelProvider,
  ModelItem? currentModel,
  CredentialPanelState credentialState,
) {
  if (modelId == null || modelId.isEmpty || providerName == null || providerName.isEmpty) {
    return DerivedModelStatus.empty;
  }
  if (currentModelProvider == null) return DerivedModelStatus.incompatible;
  final exhaustedWithoutApiKey =
      credentialState.supportsCredits && credentialState.isCreditsExhausted && !credentialState.hasCredentials;
  final priorityExhausted =
      credentialState.priority == UsagePriority.credits &&
      credentialState.supportsCredits &&
      credentialState.isCreditsExhausted;
  if (priorityExhausted || exhaustedWithoutApiKey) return DerivedModelStatus.creditsExhausted;
  if (currentModel == null) return DerivedModelStatus.incompatible;
  if (credentialState.variant == CardVariant.apiUnavailable) return DerivedModelStatus.apiKeyUnavailable;
  return switch (currentModel.status) {
    ModelStatusEnum.active => DerivedModelStatus.active,
    ModelStatusEnum.noConfigure => DerivedModelStatus.configureRequired,
    ModelStatusEnum.quotaExceeded => DerivedModelStatus.creditsExhausted,
    ModelStatusEnum.credentialRemoved => DerivedModelStatus.apiKeyUnavailable,
    ModelStatusEnum.disabled => DerivedModelStatus.disabled,
    _ => DerivedModelStatus.incompatible,
  };
}

/// The workspace's model providers and models, as the console API returns them. The default is an empty workspace
/// (no providers, no models), which is what a fresh self-hosted Dify has.
class ModelCatalog {
  const ModelCatalog({
    this.providers = const [],
    this.modelLists = const {},
    this.deploymentEdition = 'COMMUNITY',
    this.trialCredits = const TrialCredits(),
    this.trialModels = const [],
    this.language = 'en_US',
  });

  static const empty = ModelCatalog();

  /// `GET workspaces/current/model-providers/summary`: every installed provider.
  final List<ModelProvider> providers;

  /// `GET workspaces/current/models/model-types/{type}` per [ModelTypeEnum] value.
  final Map<String, List<ProviderWithModels>> modelLists;

  /// System features' `deployment_edition`: `CLOUD`, `COMMUNITY` or `ENTERPRISE`.
  final String deploymentEdition;

  /// useTrialCredits (exhausted while unknown, as in Dify).
  final TrialCredits trialCredits;

  /// `GET trial-models` (Cloud only): providers that can use AI credits.
  final List<String> trialModels;

  /// useLanguage: the language I18n texts are shown in.
  final String language;

  List<ProviderWithModels> modelList(String type) => modelLists[type] ?? const [];

  /// useTextGenerationCurrentProviderAndModelAndModelList's `textGenerationModelList`.
  List<ProviderWithModels> get textGenerationModelList => modelList(ModelTypeEnum.textGeneration);

  /// Its `activeTextGenerationModelList`: the providers whose status is active.
  List<ProviderWithModels> get activeTextGenerationModelList => [
    for (final p in textGenerationModelList)
      if (p.status == ModelStatusEnum.active) p,
  ];

  /// The agent ModelBar's useAllModel: every type's list, concatenated in Dify's order.
  List<ProviderWithModels> get allModelList => [
    for (final t in const [
      ModelTypeEnum.textGeneration,
      ModelTypeEnum.moderation,
      ModelTypeEnum.rerank,
      ModelTypeEnum.speech2text,
      ModelTypeEnum.textEmbedding,
      ModelTypeEnum.tts,
    ])
      ...modelList(t),
  ];

  /// The summary entry of [provider] (the trigger's `resolvedProvider`), or null when not installed.
  ModelProvider? provider(String? provider) =>
      provider == null || provider.isEmpty ? null : providers.where((p) => p.provider == provider).firstOrNull;

  CredentialPanelState credentialPanelState(ModelProvider? provider) => CredentialPanelState.of(
    provider,
    deploymentEdition: deploymentEdition,
    trialCredits: trialCredits,
    trialModels: trialModels,
  );
}
