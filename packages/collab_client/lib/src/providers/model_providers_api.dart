/// Model providers (docs/protocol.md section 2 "Model providers", protocol 1.9): the workspace's LLM providers, their
/// credentials, models, parameter rules and default models, with **Dify 1.17.1's console API shapes**.
///
/// ## What to use it for
///
/// * **Workflow editor** (any member): [summaries] (configured providers, for the checklist's "Configure a model"),
///   [modelsOfType] for each model type the selectors need (Dify's `useModelList(type)`), [defaultModel] per type
///   (Dify's `useDefaultModel(type)`), [parameterRules] (Dify's `useModelParameterRules(provider, model)`), and
///   [providers] (the moderation feature asks whether OpenAI is configured).
/// * **Settings, Model Provider tab** (Dify's `model-provider-page`): [providers] (credential form schemas,
///   `custom_configuration` with credentials and custom models), [providerModels] (the provider card's model list,
///   every status), [enableModel]/[disableModel], the provider credential calls ([providerCredentials],
///   [createProviderCredential], [updateProviderCredential], [deleteProviderCredential], [switchProviderCredential],
///   [validateProviderCredentials]), the custom-model calls ([modelCredentials], [createModelCredential],
///   [updateModelCredential], [deleteModelCredential], [switchModelCredential], [validateModelCredentials],
///   [addCustomModel], [removeCustomModel]) and the system model selector ([defaultModel], [setDefaultModels]).
/// * **Icons**: responses carry icon URLs relative to the server (`icon_small: {"en_US": "/v1/workspace/model-providers/
///   langgenius/openai/openai/icon_small/en_US", "zh_Hans": ...}`), mostly SVG. [iconUrl] makes one absolute (for a
///   network image with no token: the icon route is public, like Dify's); [icon] fetches the bytes (fakes serve them
///   from memory).
///
/// ## Shapes
///
/// Reads return the JSON of Dify's console API **unchanged** (the `data` member unwrapped), so the app's data classes
/// that port Dify's TypeScript types (`ModelProvider`, `ProviderWithModels`, `ModelItem`, `DefaultModelResponse`,
/// `ModelParameterRule`, `Credential`, ...) parse them with their `fromJson`. Differences from Dify: there is no
/// `tenant_id` member, icon URLs are relative, `plugins` of the summary is `{}`, `system_configuration.enabled` is
/// always false and `preferred_provider_type` always `custom` (no hosted quota), load balancing is always off.
/// Provider ids are the long form `org/plugin/provider` (`langgenius/openai/openai`, `langgenius/gemini/google`).
///
/// ## Secrets
///
/// Credential reads ([providerCredentials], [modelCredentials]) return secret fields (`secret-input`) masked with Dify's
/// mask (first 6 characters, 12 `*`, last 2; 20 `*` for 8 characters or fewer). To keep a secret unchanged on update,
/// send [hiddenSecret] (`[__HIDDEN__]`, Dify's `__HIDDEN__` round trip) in its place: the server substitutes the stored
/// value. The server stores credentials encrypted; a server without a secrets key refuses credential writes with
/// `503 secrets_key_missing` (the catalog still works, every provider unconfigured).
///
/// ## Roles and errors
///
/// Reads: any member. Every other call, including the credential reads (masked values) and the two `validate*` calls:
/// the workspace owner or an admin (Dify's `is_admin_or_owner`; Dify lets every member validate, dify-sf keeps the
/// server's outbound requests to the privileged roles): others get `403 forbidden` (use `Account.isPrivileged` to show or
/// hide the edit controls, as Dify's `useCredentialPermissions`). Failures throw a `TransportException` with the
/// server's code: `credential_validation_failed` (400, saving: the provider refused the credentials; `message` is the
/// short reason), `credential_name_exists` (409), `secrets_key_missing` (503), `not_found` (404: unknown provider,
/// credential or model), `bad_request` (400: malformed body, unknown model type, a model that is not available as a
/// default, a name over 30 characters, a provider without custom models), `forbidden` (403), `unauthorized` (401).
///
/// Implementations: `HttpModelProvidersApi` (a real server) and `FakeModelProvidersApi`
/// (`package:collab_client/testing.dart`: in memory, with a small fixture catalog: OpenAI, Anthropic, Ollama and
/// OpenAI-API-compatible).
library;

/// Optional extension for compatible LLM discovery. Discovery never invokes a
/// model; probing is a separate operation requiring explicit consent.
abstract interface class ModelDiscoveryApi {
  Future<Map<String, Object?>> discoverModels(String provider, {required Map<String, Object?> credentials});
  Future<Map<String, Object?>> probeModel(
    String provider, {
    required Map<String, Object?> credentials,
    required String model,
    required String apiType,
    required bool consent,
  });
  Future<void> createAutofilledModel(
    String provider, {
    required String model,
    required Map<String, Object?> credentials,
    String? discoveryId,
    String? probeId,
  });
}

/// Dify's `ModelTypeEnum` values, in Dify's order.
abstract final class ModelProviderModelTypes {
  static const llm = 'llm';
  static const textEmbedding = 'text-embedding';
  static const rerank = 'rerank';
  static const speech2text = 'speech2text';
  static const moderation = 'moderation';
  static const tts = 'tts';

  static const all = [llm, textEmbedding, rerank, speech2text, moderation, tts];
}

/// Dify's `ConfigurationMethodEnum` / `config_from` values.
abstract final class ModelConfigFrom {
  static const predefinedModel = 'predefined-model';
  static const customizableModel = 'customizable-model';

  /// `config_from` of [ModelProvidersApi.addCustomModel] (Dify's web sends `custom-model` there).
  static const customModel = 'custom-model';
}

/// The value that stands for "the stored secret, unchanged" in a credential update (Dify's `[__HIDDEN__]`).
const hiddenSecret = '[__HIDDEN__]';

/// One entry of `POST /default-model` (Dify's `model_settings[]`): [provider] and [model] null = leave this type alone.
final class DefaultModelSetting {
  const DefaultModelSetting({
    required this.modelType,
    this.provider,
    this.model,
  });

  final String modelType;
  final String? provider;
  final String? model;

  Map<String, Object?> toJson() => {
    'model_type': modelType,
    'provider': provider,
    'model': model,
  };
}

/// The answer of a `validate*` call: Dify's `{"result":"success"}` or `{"result":"error","error":"..."}`.
final class CredentialValidation {
  const CredentialValidation.success() : ok = true, error = null;
  const CredentialValidation.failure(String this.error) : ok = false;

  factory CredentialValidation.fromJson(Object? json) {
    final m = json is Map<String, Object?> ? json : const <String, Object?>{};
    return m['result'] == 'success'
        ? const CredentialValidation.success()
        : CredentialValidation.failure(
            m['error'] is String ? m['error']! as String : 'Unknown error',
          );
  }

  final bool ok;

  /// The short reason when not [ok].
  final String? error;
}

/// A provider icon's bytes.
final class ModelProviderIcon {
  const ModelProviderIcon({required this.bytes, required this.contentType});

  final List<int> bytes;

  /// `image/svg+xml` for most providers, else `image/png`.
  final String contentType;

  bool get isSvg => contentType.startsWith('image/svg');
}

/// See the library documentation above. [provider] arguments are long provider ids (`langgenius/openai/openai`).
abstract interface class ModelProvidersApi {
  // ----- reads (any member) -----

  /// `GET /v1/workspace/model-providers/summary` (`data`): every provider with its configuration state, in display
  /// order. Dify's `ModelProviderSummaryResponse` objects.
  Future<List<Map<String, Object?>>> summaries();

  /// `GET /v1/workspace/model-providers[?model_type=]` (`data`): every provider (only those supporting [modelType], if
  /// given) with credential form schemas, `custom_configuration` (current and available credentials, custom models
  /// without their credentials, `can_added_models`). Dify's `ProviderResponse` objects.
  Future<List<Map<String, Object?>>> providers({String? modelType});

  /// `GET /v1/workspace/models/model-types/{modelType}` (`data`): the **active** models of type [modelType] grouped by
  /// provider (only providers that have one; deprecated models left out). Dify's `ProviderWithModelsResponse`
  /// objects. What the model selectors list.
  Future<List<Map<String, Object?>>> modelsOfType(String modelType);

  /// `GET /v1/workspace/default-model?model_type=` (`data`): the workspace default of [modelType]
  /// (`{model, model_type, provider: {provider, label, icon_small, icon_small_dark, supported_model_types, models: []}}`),
  /// or null when there is no active model of that type. As in Dify, when no default was set the server picks the first
  /// active model and stores it as the default.
  Future<Map<String, Object?>?> defaultModel(String modelType);

  /// `GET /v1/workspace/model-providers/{provider}/models/parameter-rules?model=` (`data`): the parameter rules of an
  /// LLM (Dify's `ModelParameterRule` objects, templates resolved); `[]` when the provider has no usable credential or
  /// the model is unknown.
  Future<List<Map<String, Object?>>> parameterRules(
    String provider,
    String model,
  );

  /// `GET /v1/workspace/model-providers/{provider}/models` (`data`): every model of the provider with its status
  /// (`active`, `no-configure`, `disabled`, `credential-removed`) and the provider (`provider: {...}`). Dify's
  /// `ModelWithProviderEntityResponse` objects (the provider card's model list).
  Future<List<Map<String, Object?>>> providerModels(String provider);

  // ----- default models (owner, admin) -----

  /// `POST /v1/workspace/default-model` `{model_settings: [...]}` (the system model selector's Save). Each model must be
  /// active (else `400 bad_request`).
  Future<void> setDefaultModels(List<DefaultModelSetting> settings);

  // ----- model list (owner, admin) -----

  /// `PATCH .../models/enable` `{model, model_type}`.
  Future<void> enableModel(
    String provider, {
    required String model,
    required String modelType,
  });

  /// `PATCH .../models/disable` `{model, model_type}`: the model gets status `disabled` (and leaves [modelsOfType]).
  Future<void> disableModel(
    String provider, {
    required String model,
    required String modelType,
  });

  // ----- provider credentials (owner, admin) -----

  /// `GET .../credentials[?credential_id=]` (`credentials`): the values of credential [credentialId], or of the
  /// current credential when null, secrets masked; `{}` when the provider has no current credential.
  Future<Map<String, Object?>> providerCredentials(
    String provider, {
    String? credentialId,
  });

  /// `POST .../credentials` `{credentials, name?}`: validates (one cheap request to the provider, unless the server
  /// has validation switched off), then stores a new credential. [name]: at most 30 characters, unique per provider;
  /// default `API KEY <n>`. The provider's first credential becomes its current one.
  Future<void> createProviderCredential(
    String provider, {
    required Map<String, Object?> credentials,
    String? name,
  });

  /// `PUT .../credentials` `{credential_id, credentials, name?}`. Secrets sent as [hiddenSecret] keep their stored value.
  Future<void> updateProviderCredential(
    String provider, {
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  });

  /// `DELETE .../credentials` `{credential_id}`. Deleting the current credential leaves the provider without one
  /// (its models become `no-configure`) until [switchProviderCredential]; deleting the last one unconfigures it.
  Future<void> deleteProviderCredential(
    String provider, {
    required String credentialId,
  });

  /// `POST .../credentials/switch` `{credential_id}`: makes it the provider's current credential.
  Future<void> switchProviderCredential(
    String provider, {
    required String credentialId,
  });

  /// `POST .../credentials/validate` `{credentials}`: checks without storing.
  Future<CredentialValidation> validateProviderCredentials(
    String provider, {
    required Map<String, Object?> credentials,
  });

  // ----- custom models (owner, admin) -----

  /// `GET .../models/credentials?model=&model_type=[&config_from=][&credential_id=]`: Dify's
  /// `{credentials, current_credential_id, current_credential_name, load_balancing: {enabled: false, configs: []},
  /// available_credentials: [{credential_id, credential_name}]}` (secrets masked). With [configFrom]
  /// `predefined-model`, `available_credentials` are the provider's credentials, else the model's.
  Future<Map<String, Object?>> modelCredentials(
    String provider, {
    required String model,
    required String modelType,
    String? configFrom,
    String? credentialId,
  });

  /// `POST .../models/credentials` `{model, model_type, credentials, name?}`: validates, stores, and adds the model to
  /// the provider's model list if it is not there yet (with this credential as its current one).
  Future<void> createModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
    String? name,
  });

  /// `PUT .../models/credentials` `{model, model_type, credential_id, credentials, name?}`.
  Future<void> updateModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
    required Map<String, Object?> credentials,
    String? name,
  });

  /// `DELETE .../models/credentials` `{model, model_type, credential_id}`. The last credential of a model removes the
  /// model; deleting its current one leaves it `credential-removed`.
  Future<void> deleteModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  });

  /// `POST .../models/credentials/switch` `{model, model_type, credential_id}` (Dify: "add the credential to the model
  /// list"): adds the model with this credential, or makes it the model's current credential (`400` if it already is).
  Future<void> switchModelCredential(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  });

  /// `POST .../models/credentials/validate` `{model, model_type, credentials}`.
  Future<CredentialValidation> validateModelCredentials(
    String provider, {
    required String model,
    required String modelType,
    required Map<String, Object?> credentials,
  });

  /// `POST .../models` `{model, model_type, config_from: "custom-model", credential_id}`: puts the model (back) into
  /// the model list with credential [credentialId] as its current one.
  Future<void> addCustomModel(
    String provider, {
    required String model,
    required String modelType,
    required String credentialId,
  });

  /// `DELETE .../models` `{model, model_type}`: removes a custom model from the list (its credentials stay: it shows in
  /// `can_added_models`).
  Future<void> removeCustomModel(
    String provider, {
    required String model,
    required String modelType,
  });

  // ----- icons (public) -----

  /// [url] (an icon URL of a response, relative to the server) as an absolute URL.
  Uri iconUrl(String url);

  /// The icon at [url] (as in a response); null if there is none.
  Future<ModelProviderIcon?> icon(String url);
}

/// Optional management surface for the server's supported, signed model-provider plugins.
/// Reads need a workspace member; installation and removal need owner/admin.
/// Removing a runtime retains saved model credentials and workflow documents.
abstract interface class ModelProviderPluginsApi {
  Future<List<Map<String, Object?>>> providerPlugins();
  Future<Map<String, Object?>> installProviderPlugin(String pluginId);
  Future<Map<String, Object?>> providerPluginTask(String taskId);
  Future<void> uninstallProviderPlugin(
    String pluginId, {
    required String installationId,
  });
}
