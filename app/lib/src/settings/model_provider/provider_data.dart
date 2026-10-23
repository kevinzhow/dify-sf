/// The model provider page's reading of a provider (the console's ModelProvider / ModelProviderSummaryResponse JSON)
/// and the declarations and utils it uses: ConfigurationMethodEnum, ModelModalModeEnum, CustomModel, the custom
/// model fixed fields, MODEL_TYPE_TEXT, genModelTypeFormSchema and genModelNameFormSchema (utils.ts).
library;

import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart' show Json;
import '../form/base_form.dart';

/// ConfigurationMethodEnum.
abstract final class ConfigurationMethodEnum {
  static const predefinedModel = 'predefined-model';
  static const customizableModel = 'customizable-model';
  static const fetchFromRemote = 'fetch-from-remote';
}

/// ModelModalModeEnum.
enum ModelModalModeEnum {
  configProviderCredential('config-provider-credential'),
  configCustomModel('config-custom-model'),
  addCustomModelToModelList('add-custom-model-to-model-list'),
  configModelCredential('config-model-credential');

  const ModelModalModeEnum(this.value);
  final String value;
}

/// CustomModel: a model of a provider (`{model, model_type}`).
typedef CustomModel = ({String model, String modelType});

/// CustomConfigurationModelFixedFields (`__model_name`, `__model_type`).
typedef CustomModelFixedFields = ({String modelName, String modelType});

/// MODEL_TYPE_TEXT.
const modelTypeText = {
  ModelTypeEnum.textGeneration: 'LLM',
  ModelTypeEnum.textEmbedding: 'Text Embedding',
  ModelTypeEnum.rerank: 'Rerank',
  ModelTypeEnum.speech2text: 'Speech2text',
  ModelTypeEnum.moderation: 'Moderation',
  ModelTypeEnum.tts: 'TTS',
};

/// A custom model of `custom_configuration.custom_models` (CustomModelCredential).
class CustomModelEntry {
  const CustomModelEntry({
    required this.model,
    required this.modelType,
    this.currentCredentialId,
    this.currentCredentialName,
    this.availableModelCredentials = const [],
  });

  factory CustomModelEntry.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    final creds = m['available_model_credentials'];
    return CustomModelEntry(
      model: '${m['model'] ?? ''}',
      modelType: '${m['model_type'] ?? ''}',
      currentCredentialId: m['current_credential_id'] as String?,
      currentCredentialName: m['current_credential_name'] as String?,
      availableModelCredentials: creds is List ? [for (final c in creds) Credential.fromJson(c)] : const [],
    );
  }

  final String model, modelType;
  final String? currentCredentialId, currentCredentialName;
  final List<Credential> availableModelCredentials;

  CustomModel get asModel => (model: model, modelType: modelType);
}

/// The fields of a provider JSON the page reads.
extension ProviderJson on Json {
  String get providerName => '${this['provider'] ?? ''}';

  I18nText get label => _i18n(this['label']);
  I18nText? get description => this['description'] is Map ? _i18n(this['description']) : null;
  I18nText? get iconSmall => this['icon_small'] is Map ? _i18n(this['icon_small']) : null;
  I18nText? get iconSmallDark => this['icon_small_dark'] is Map ? _i18n(this['icon_small_dark']) : null;

  List<String> get supportedModelTypes => [for (final t in _list(this['supported_model_types'])) '$t'];
  List<String> get configurateMethods => [for (final t in _list(this['configurate_methods'])) '$t'];

  Json get customConfiguration => _map(this['custom_configuration']);
  Json get systemConfiguration => _map(this['system_configuration']);

  /// The summary (`is_configured` without the credential schemas) rather than the details.
  bool get isSummary => containsKey('is_configured') && !containsKey('provider_credential_schema');

  List<Credential> get availableCredentials => [
    for (final c in _list(customConfiguration['available_credentials'])) Credential.fromJson(c),
  ];

  String? get currentCredentialId => customConfiguration['current_credential_id'] as String?;

  /// `has_custom_models` of the summary, else whether the details list custom models.
  bool get hasCustomModels => customConfiguration.containsKey('has_custom_models')
      ? customConfiguration['has_custom_models'] == true
      : _list(customConfiguration['custom_models']).isNotEmpty;

  /// useCustomModels.
  List<CustomModelEntry> get customModels => [
    for (final m in _list(customConfiguration['custom_models'])) CustomModelEntry.fromJson(m),
  ];

  /// useCanAddedModels.
  List<CustomModelEntry> get canAddedModels => [
    for (final m in _list(customConfiguration['can_added_models'])) CustomModelEntry.fromJson(m),
  ];

  /// `allow_custom_token !== false`.
  bool get allowCustomToken => this['allow_custom_token'] != false;

  /// The credential form schemas of the provider (predefined) or of its custom models.
  List<Json> credentialFormSchemas({required bool predefined}) {
    final schema = _map(this[predefined ? 'provider_credential_schema' : 'model_credential_schema']);
    return [
      for (final s in _list(schema['credential_form_schemas']))
        if (s is Map) {for (final e in s.entries) '${e.key}': e.value},
    ];
  }

  /// `model_credential_schema.model` (`{label, placeholder}`), if any.
  Json? get modelCredentialModel {
    final m = _map(this['model_credential_schema'])['model'];
    return m is Map ? {for (final e in m.entries) '${e.key}': e.value} : null;
  }

  /// `help: {title, url}`.
  Json? get help => this['help'] is Map ? _map(this['help']) : null;
}

Json _map(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : const {};
List<Object?> _list(Object? v) => v is List ? v : const [];
I18nText _i18n(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value?.toString()} : const {};

/// genModelTypeFormSchema: the model type select of a custom model (default: the first type).
FormSchema genModelTypeFormSchema(List<String> modelTypes) => FormSchema(
  type: FormTypeEnum.select,
  name: '__model_type',
  label: const {'zh_Hans': '模型类型', 'en_US': 'Model Type'},
  defaultValue: modelTypes.firstOrNull,
  required: true,
  options: [
    for (final t in modelTypes)
      FormOption(
        value: t,
        label: {'zh_Hans': modelTypeText[t], 'en_US': modelTypeText[t]},
      ),
  ],
);

/// genModelNameFormSchema: the model name input of a custom model (the provider's `model_credential_schema.model`
/// label and placeholder, else Dify's).
FormSchema genModelNameFormSchema([Json? model]) => FormSchema(
  type: FormTypeEnum.textInput,
  name: '__model_name',
  label: _truthy(model?['label']) ? model!['label'] : const {'zh_Hans': '模型名称', 'en_US': 'Model Name'},
  required: true,
  placeholder: _truthy(model?['placeholder'])
      ? model!['placeholder']
      : const {'zh_Hans': '请输入模型名称', 'en_US': 'Please enter model name'},
);

bool _truthy(Object? v) => v != null && v != '' && v != false;
