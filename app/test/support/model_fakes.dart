import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';

export 'package:dify_sf_app/src/workflow/workspace_models.dart' show Json;

/// A model providers API for the settings' and editor's widget tests (the ported Dify specs set the console's answers
/// and check the requests): reads answer the fields below, every call is recorded in [calls] (name and arguments),
/// [fail] makes calls of a kind throw, [hold] makes them wait until the completer completes.
class RecordingModelsApi implements ModelProvidersApi {
  List<Json> summaryData = [];
  List<Json> providersData = [];
  final modelsByType = <String, List<Json>>{};
  final defaults = <String, Json?>{};
  final providerModelsData = <String, List<Json>>{};
  final rules = <String, List<Json>>{};
  Json providerCredentialData = {};
  Json modelCredentialData = {};
  final icons = <String, ModelProviderIcon>{};

  final calls = <(String, Map<String, Object?>)>[];
  final fail = <String, Object>{};
  final hold = <String, Completer<void>>{};

  /// The calls named [name], in order (their arguments).
  List<Map<String, Object?>> callsOf(String name) => [
    for (final (n, a) in calls)
      if (n == name) a,
  ];

  Future<T> _call<T>(String name, Map<String, Object?> args, T Function() answer) async {
    calls.add((name, args));
    final gate = hold[name];
    if (gate != null) await gate.future;
    final error = fail[name];
    if (error != null) throw error;
    return answer();
  }

  @override
  Future<List<Map<String, Object?>>> summaries() => _call('summaries', const {}, () => summaryData);

  @override
  Future<List<Map<String, Object?>>> providers({String? modelType}) =>
      _call('providers', {'modelType': modelType}, () => providersData);

  @override
  Future<List<Map<String, Object?>>> modelsOfType(String modelType) =>
      _call('modelsOfType', {'modelType': modelType}, () => modelsByType[modelType] ?? const []);

  @override
  Future<Map<String, Object?>?> defaultModel(String modelType) =>
      _call('defaultModel', {'modelType': modelType}, () => defaults[modelType]);

  @override
  Future<List<Map<String, Object?>>> parameterRules(String provider, String model) =>
      _call('parameterRules', {'provider': provider, 'model': model}, () => rules['$provider/$model'] ?? const []);

  @override
  Future<List<Map<String, Object?>>> providerModels(String provider) =>
      _call('providerModels', {'provider': provider}, () => providerModelsData[provider] ?? const []);

  @override
  Future<void> setDefaultModels(List<DefaultModelSetting> settings) => _call('setDefaultModels', {
    'settings': [for (final s in settings) s.toJson()],
  }, () {});

  @override
  Future<void> enableModel(String provider, {required String model, required String modelType}) =>
      _call('enableModel', {'provider': provider, 'model': model, 'modelType': modelType}, () {});

  @override
  Future<void> disableModel(String provider, {required String model, required String modelType}) =>
      _call('disableModel', {'provider': provider, 'model': model, 'modelType': modelType}, () {});

  @override
  Future<Map<String, Object?>> providerCredentials(String provider, {String? credentialId}) => _call(
    'providerCredentials',
    {'provider': provider, 'credentialId': credentialId},
    () => providerCredentialData,
  );

  @override
  Future<void> createProviderCredential(String provider, {required Map<String, Object?> credentials, String? name}) =>
      _call('createProviderCredential', {'provider': provider, 'credentials': credentials, 'name': name}, () {});

  @override
  Future<void> updateProviderCredential(
    String provider, {
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  }) => _call('updateProviderCredential', {
    'provider': provider,
    'credentialId': credentialId,
    'credentials': credentials,
    'name': name,
  }, () {});

  @override
  Future<void> deleteProviderCredential(String provider, {required String credentialId}) =>
      _call('deleteProviderCredential', {'provider': provider, 'credentialId': credentialId}, () {});

  @override
  Future<void> switchProviderCredential(String provider, {required String credentialId}) =>
      _call('switchProviderCredential', {'provider': provider, 'credentialId': credentialId}, () {});

  @override
  Future<CredentialValidation> validateProviderCredentials(
    String provider, {
    required Map<String, Object?> credentials,
  }) => _call(
    'validateProviderCredentials',
    {'provider': provider, 'credentials': credentials},
    () => const CredentialValidation.success(),
  );

  @override
  Future<Map<String, Object?>> modelCredentials(
    String provider, {
    required String model,
    required String modelType,
    String? configFrom,
    String? credentialId,
  }) => _call('modelCredentials', {
    'provider': provider,
    'model': model,
    'modelType': modelType,
    'configFrom': configFrom,
    'credentialId': credentialId,
  }, () => modelCredentialData);

  @override
  Future<void> createModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
    String? name,
  }) => _call('createModelCredential', {
    'provider': provider,
    'model': model,
    'modelType': modelType,
    'credentials': credentials,
    'name': name,
  }, () {});

  @override
  Future<void> updateModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  }) => _call('updateModelCredential', {
    'provider': provider,
    'model': model,
    'modelType': modelType,
    'credentialId': credentialId,
    'credentials': credentials,
    'name': name,
  }, () {});

  @override
  Future<void> deleteModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) => _call('deleteModelCredential', {
    'provider': provider,
    'model': model,
    'modelType': modelType,
    'credentialId': credentialId,
  }, () {});

  @override
  Future<void> switchModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) => _call('switchModelCredential', {
    'provider': provider,
    'model': model,
    'modelType': modelType,
    'credentialId': credentialId,
  }, () {});

  @override
  Future<CredentialValidation> validateModelCredentials(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
  }) => _call(
    'validateModelCredentials',
    {'provider': provider, 'model': model, 'modelType': modelType, 'credentials': credentials},
    () => const CredentialValidation.success(),
  );

  @override
  Future<void> addCustomModel(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  }) => _call('addCustomModel', {
    'provider': provider,
    'model': model,
    'modelType': modelType,
    'credentialId': credentialId,
  }, () {});

  @override
  Future<void> removeCustomModel(String provider, {required String model, required String modelType}) =>
      _call('removeCustomModel', {'provider': provider, 'model': model, 'modelType': modelType}, () {});

  @override
  Uri iconUrl(String url) => Uri.parse('http://test$url');

  @override
  Future<ModelProviderIcon?> icon(String url) => _call('icon', {'url': url}, () => icons[url]);
}

/// Dify's `workspacePermissionKeys` of an owner or admin with the legacy roles.
const managerPermissionKeys = [
  'plugin.plugin_preferences',
  'plugin.model_config',
  'credential.use',
  'credential.create',
  'credential.manage',
];

/// The env over [api] with [permissionKeys] (a manager's by default).
ModelProviderEnv envOf(
  RecordingModelsApi api, {
  List<String> permissionKeys = managerPermissionKeys,
  bool rbacEnabled = false,
  WorkspaceModels? models,
}) => ModelProviderEnv(
  models: models ?? WorkspaceModels(api, fixedLanguage: 'en_US'),
  permissionKeys: permissionKeys,
  rbacEnabled: rbacEnabled,
);

/// An I18n object with the same text in English and Chinese.
Map<String, String> i18n(String text) => {'en_US': text, 'zh_Hans': text};

/// A provider as the details list it (ModelProvider), with the given changes.
Json providerJson({
  String provider = 'langgenius/openai/openai',
  String label = 'OpenAI',
  List<String> configurateMethods = const ['predefined-model'],
  List<String> supportedModelTypes = const ['llm'],
  Json customConfiguration = const {'status': 'no-configure'},
  List<Json> providerSchemas = const [],
  List<Json> modelSchemas = const [],
  Json? help,
  bool allowCustomToken = true,
  Json extra = const {},
}) => {
  'provider': provider,
  'label': i18n(label),
  'icon_small': i18n(''),
  'supported_model_types': supportedModelTypes,
  'configurate_methods': configurateMethods,
  'provider_credential_schema': {'credential_form_schemas': providerSchemas},
  'model_credential_schema': {
    'model': {'label': i18n('Model Name'), 'placeholder': i18n('Enter your model name')},
    'credential_form_schemas': modelSchemas,
  },
  'preferred_provider_type': 'custom',
  'custom_configuration': customConfiguration,
  'system_configuration': {'enabled': false, 'quota_configurations': <Object?>[]},
  'help': ?help,
  'allow_custom_token': allowCustomToken,
  ...extra,
};

/// A summary entry (ModelProviderSummaryResponse).
Json summaryJson({
  String provider = 'langgenius/openai/openai',
  String label = 'OpenAI',
  bool isConfigured = true,
  List<String> configurateMethods = const ['predefined-model'],
  List<String> supportedModelTypes = const ['llm'],
  Json? customConfiguration,
}) => {
  'provider': provider,
  'plugin_id': provider.split('/').take(2).join('/'),
  'label': i18n(label),
  'icon_small': i18n(''),
  'supported_model_types': supportedModelTypes,
  'configurate_methods': configurateMethods,
  'preferred_provider_type': 'custom',
  'is_configured': isConfigured,
  'custom_configuration':
      customConfiguration ??
      {
        'status': isConfigured ? 'active' : 'no-configure',
        'available_credentials': <Object?>[],
        'current_credential_usable': isConfigured,
        'has_custom_models': false,
      },
  'system_configuration': {'enabled': false},
};

/// A model of a provider's model list (ModelItem).
Json modelJson(
  String model, {
  String modelType = 'llm',
  String status = 'active',
  String fetchFrom = 'predefined-model',
  bool deprecated = false,
  Json properties = const {'mode': 'chat', 'context_size': 128000},
}) => {
  'model': model,
  'label': i18n(model),
  'model_type': modelType,
  'features': <Object?>[],
  'fetch_from': fetchFrom,
  'status': status,
  'model_properties': properties,
  'load_balancing_enabled': false,
  'deprecated': deprecated,
};

/// A provider with models of one type (ProviderWithModelsResponse).
Json providerWithModels(String provider, List<String> models, {String modelType = 'llm', String label = 'OpenAI'}) => {
  'provider': provider,
  'label': i18n(label),
  'icon_small': i18n(''),
  'status': 'active',
  'models': [for (final m in models) modelJson(m, modelType: modelType)],
};

/// A default model (DefaultModelResponse).
Json defaultModelJson(String provider, String model, {String modelType = 'llm'}) => {
  'model': model,
  'model_type': modelType,
  'provider': {'provider': provider, 'label': i18n(provider), 'models': <Object?>[]},
};
