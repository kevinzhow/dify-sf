/// What the features panel needs from the host that the document does not hold: the TTS voices, the moderation
/// extensions, the model providers (is OpenAI set up for OpenAI moderation), the system's file upload limits, the
/// account settings, the app's locale and the modal context's dialogs. Everything defaults to a workspace with no
/// backend: no voices, no extensions, no providers, Dify's fallback limits.
library;

import 'package:flutter/widgets.dart';

import '../../design/widgets/toast.dart';
import '../../i18n/dify_i18n.dart';
import 'features_store.dart';

typedef Json = Map<String, Object?>;

/// One of Dify's languages (i18n-config/languages.ts): its value, name and TTS audition example.
typedef DifyLanguage = ({String value, String name, String example});

/// i18n-config/languages.ts.
const List<DifyLanguage> difyLanguages = [
  (value: 'en-US', name: 'English (United States)', example: 'Hello, Dify!'),
  (value: 'zh-Hans', name: '简体中文', example: '你好，Dify！'),
  (value: 'zh-Hant', name: '繁體中文', example: '你好，Dify！'),
  (value: 'pt-BR', name: 'Português (Brasil)', example: 'Olá, Dify!'),
  (value: 'es-ES', name: 'Español (España)', example: '¡Hola, Dify!'),
  (value: 'fr-FR', name: 'Français (France)', example: 'Bonjour, Dify!'),
  (value: 'de-DE', name: 'Deutsch (Deutschland)', example: 'Hallo, Dify!'),
  (value: 'ja-JP', name: '日本語 (日本)', example: 'こんにちは、Dify!'),
  (value: 'ko-KR', name: '한국어 (대한민국)', example: '안녕하세요, Dify!'),
  (value: 'lo-LA', name: 'ລາວ (ລາວ)', example: 'ສະບາຍດີ, Dify!'),
  (value: 'ru-RU', name: 'Русский (Россия)', example: ' Привет, Dify!'),
  (value: 'it-IT', name: 'Italiano (Italia)', example: 'Ciao, Dify!'),
  (value: 'th-TH', name: 'ไทย (ประเทศไทย)', example: 'สวัสดี Dify!'),
  (value: 'uk-UA', name: 'Українська (Україна)', example: 'Привет, Dify!'),
  (value: 'vi-VN', name: 'Tiếng Việt (Việt Nam)', example: 'Xin chào, Dify!'),
  (value: 'ro-RO', name: 'Română (România)', example: 'Salut, Dify!'),
  (value: 'pl-PL', name: 'Polski (Polish)', example: 'Cześć, Dify!'),
  (value: 'hi-IN', name: 'Hindi (India)', example: 'नमस्ते, Dify!'),
  (value: 'tr-TR', name: 'Türkçe', example: 'Selam!'),
  (value: 'fa-IR', name: 'Farsi (Iran)', example: 'سلام, دیفای!'),
  (value: 'sl-SI', name: 'Slovensko (Slovenija)', example: 'Zdravo, Dify!'),
  (value: 'id-ID', name: 'Bahasa Indonesia', example: 'Halo, Dify!'),
  (value: 'nl-NL', name: 'Nederlands (Nederland)', example: 'Hallo, Dify!'),
  (value: 'ar-TN', name: 'العربية (تونس)', example: 'مرحبا، Dify!'),
];

/// The conversation opener's modal (`setShowOpeningModal`): the opening feature, the variables the opener may use and
/// what to do on save / cancel.
typedef OpeningModalRequest = ({
  Json payload,
  List<Json> promptVariables,
  List<Json> workflowVariables,
  void Function(List<Json> variables)? onAutoAddPromptVariable,
  ValueChanged<Json> onSaveCallback,
  VoidCallback onCancelCallback,
});

/// The moderation settings modal (`setShowModerationSettingModal`).
typedef ModerationModalRequest = ({Json payload, ValueChanged<Json> onSaveCallback, VoidCallback onCancelCallback});

/// The host's services for the features panel (see the library comment).
@immutable
class FeaturesServices {
  const FeaturesServices({
    this.voices,
    this.playAudition,
    this.codeBasedExtensions = const [],
    this.apiBasedExtensions = const [],
    this.addApiBasedExtension,
    this.modelProviders = const [],
    this.modelProvidersLoading = false,
    this.fileUploadConfig,
    this.openAccountSettings,
    this.toast = difyToast,
    this.locale,
    this.languages = difyLanguages,
    this.showOpeningModal,
    this.showModerationSettingModal,
  });

  static const empty = FeaturesServices();

  /// The app's TTS voices for a language (`textToAudio.voices`, `{value, name}`); none without a backend.
  final Future<List<({String value, String name})>> Function(String language)? voices;

  /// Plays the audition [text] with [voice] (AudioBtn); no audition button without it.
  final Future<void> Function(String text, String? voice)? playAudition;

  /// `useCodeBasedExtensions('moderation')`: Dify's CodeBasedExtensionItem JSON (`name`, `label`, `form_schema`).
  final List<Json> codeBasedExtensions;

  /// The workspace's API-based extensions (`{id, name, api_endpoint}`).
  final List<Json> apiBasedExtensions;

  /// The API extension selector's "Add" (Dify's ApiBasedExtensionModal, which needs the backend).
  final VoidCallback? addApiBasedExtension;

  /// `useModelProviderDetails`: the model providers (Dify's ModelProvider JSON); OpenAI moderation needs
  /// `langgenius/openai/openai` set up.
  final List<Json> modelProviders;
  final bool modelProvidersLoading;

  /// `useFileUploadConfig`: the system's limits (`file_size_limit`, `workflow_file_upload_limit`, ...); Dify's
  /// fallbacks without it.
  final Json? fileUploadConfig;

  /// Opens the account settings at a destination (`provider`, `custom-endpoint`).
  final ValueChanged<String>? openAccountSettings;

  /// dify-ui's toast.
  final void Function(DifyToastType type, String message)? toast;

  /// `useLocale()`; the translations' language when null.
  final String? locale;

  /// i18n-config `languages`.
  final List<DifyLanguage> languages;

  /// The modal context's opening statement modal; the [OpeningSettingModal] dialog when null.
  final void Function(BuildContext context, OpeningModalRequest request)? showOpeningModal;

  /// The modal context's moderation settings modal; the [ModerationSettingModal] dialog when null.
  final void Function(BuildContext context, ModerationModalRequest request)? showModerationSettingModal;

  String get currentLocale =>
      locale ?? (DifyI18n.current is DifyI18n ? (DifyI18n.current as DifyI18n).language : 'en-US');

  /// The moderation modal's `isOpenAIProviderConfigured`.
  bool get isOpenAIProviderConfigured {
    final openai = modelProviders.where((p) => p['provider'] == 'langgenius/openai/openai').firstOrNull;
    if (openai == null) return false;
    final system = featureMap(openai, 'system_configuration');
    final custom = featureMap(openai, 'custom_configuration');
    final quota = system['enabled'] == true
        ? (system['quota_configurations'] as List? ?? const [])
              .whereType<Map>()
              .where((q) => q['quota_type'] == system['current_quota_type'])
              .firstOrNull
        : null;
    return custom['status'] == 'active' || quota?['is_valid'] == true;
  }
}

/// Hands [services] to the features panel below it.
class FeaturesServicesScope extends InheritedWidget {
  const FeaturesServicesScope({super.key, required this.services, required super.child});

  final FeaturesServices services;

  /// The nearest services, or [FeaturesServices.empty].
  static FeaturesServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeaturesServicesScope>()?.services ?? FeaturesServices.empty;

  @override
  bool updateShouldNotify(FeaturesServicesScope oldWidget) => services != oldWidget.services;
}

/// `t(key, { ns: 'appDebug' })`.
String ad(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app-debug', key, params);

/// `t(key, { ns: 'common' })`.
String tc(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);
