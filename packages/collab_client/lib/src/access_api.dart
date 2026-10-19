/// Access Point (docs/protocol.md section 2 "App detail pages", protocol 1.11): the Web App site, the site / API
/// switches and the Service API keys of one app, with **Dify 1.17.1's console API paths and shapes** under `/v1`
/// (`api/controllers/console/app/site.py`, `app.py` `site-enable` / `api-enable`, `apikey.py`).
///
/// ## What to use it for (the Access Point page)
///
/// * **Read**: `AppsApi.get(id)` -> [AppInfo] carries [AppInfoAccess.enableSite], [AppInfoAccess.enableApi],
///   [AppInfoAccess.apiBaseUrl] and [AppInfoAccess.site] (Dify's `AppDetailWithSite`). There is no separate site read
///   (as in Dify).
/// * **Web App card**: the URL is `${site.appBaseUrl}/${chat|workflow}/${site.accessToken}` ([AppSite.webAppUrl]); the
///   switch is [AccessApi.setSiteEnabled]; regenerate is [AccessApi.resetAccessToken] (a new 16-character code; the
///   old URL stops working); Settings is [AccessApi.updateSite] with an [AppSiteUpdate].
/// * **Service API card**: the switch is [AccessApi.setApiEnabled]; the base URL is [AppInfoAccess.apiBaseUrl]; the
///   "API Secret key" modal lists [AccessApi.listApiKeys] (the badge is its length), creates with
///   [AccessApi.createApiKey] (show the full key once in Dify's "created" dialog) and deletes with
///   [AccessApi.deleteApiKey]. The modal shows [AppApiKey.maskedToken] (Dify's `first 3...last 20`); copy copies
///   [AppApiKey.token].
/// * **Availability**: an unpublished workflow app (`VersionsApi.published` is null) shows Dify's "Go to publish"
///   banner and its Web App / API / MCP cards as unavailable; chatflows are not affected (Dify's `shared/utils.ts`).
///
/// The URLs lead nowhere yet: dify-sf has no web-app or service-API runtime (protocol 1.11 stores the settings and keys
/// a runtime will use).
///
/// ## Roles (Dify community edition, RBAC off; Dify's quirks kept on purpose)
///
/// | call | owner, admin | editor | normal, dataset_operator |
/// |---|---|---|---|
/// | [AccessApi.updateSite], [AccessApi.setSiteEnabled], [AccessApi.listApiKeys], [AccessApi.createApiKey] | yes | yes | `403` |
/// | [AccessApi.resetAccessToken], [AccessApi.setApiEnabled], [AccessApi.deleteApiKey] | yes | **`403`** | `403` |
///
/// Dify's UI shows the API switch, regenerate and key delete enabled for editors too; the server refuses them and the
/// UI shows Dify's error toast. Reading the app (with its site) is open to every member.
///
/// ## Keys
///
/// `app-` + 24 random letters and digits (Dify's `ApiToken.generate_api_key`), at most 10 per app (`400
/// max_keys_exceeded`). **Deviation (hardening)**: Dify stores keys in plaintext; dify-sf stores them encrypted with
/// the server's secrets key (`COLLAB_SECRETS_KEY`) plus a SHA-256 hash for the runtime's lookup. The list still answers
/// the full key (as Dify's app-key list does). A server without a secrets key answers `503 secrets_key_missing` to
/// [AccessApi.createApiKey]; a key that cannot be decrypted any more (the secrets key was changed) is listed with
/// [AppApiKey.token] `""` ([AppApiKey.unreadable]) and still works for the runtime. A copied app gets a new site (new
/// code, the copy's name and icon) and no keys (Dify's copy = export + import).
///
/// ## Errors
///
/// `TransportException` with the server's code: `not_found` (404: unknown app or key), `app_deleted` (404),
/// `bad_request` (400: unknown language, a privacy policy URL that is not `http(s)`, a disclaimer over 512 or a
/// placeholder over 64 characters, a malformed colour, an unknown token strategy, a malformed body), `max_keys_exceeded`
/// (400), `forbidden` (403), `unauthorized` (401), `secrets_key_missing` (503).
///
/// Implementations: `HttpAccessApi` (a real server) and `FakeAccessApi` (`package:collab_client/testing.dart`, the same
/// rules on a `FakeAppsApi`'s apps).
library;

import 'apps_api.dart';

/// Dify's `constants/languages.py` `languages`: what [AppSite.defaultLanguage] accepts, in Dify's order.
abstract final class AppSiteLanguages {
  static const all = [
    'en-US',
    'zh-Hans',
    'zh-Hant',
    'pt-BR',
    'es-ES',
    'fr-FR',
    'de-DE',
    'ja-JP',
    'ko-KR',
    'lo-LA',
    'ru-RU',
    'it-IT',
    'uk-UA',
    'vi-VN',
    'ro-RO',
    'pl-PL',
    'hi-IN',
    'tr-TR',
    'fa-IR',
    'sl-SI',
    'th-TH',
    'id-ID',
    'ar-TN',
    'nl-NL',
  ];
}

/// Dify's `CustomizeTokenStrategy` ([AppSite.customizeTokenStrategy]).
abstract final class CustomizeTokenStrategy {
  static const must = 'must';
  static const allow = 'allow';
  static const notAllow = 'not_allow';

  static const all = [must, allow, notAllow];
}

/// Limits of the site settings (Dify's `Site` model and the settings modal).
abstract final class AppSiteLimits {
  /// `custom_disclaimer` (Dify's `Site._validate_custom_disclaimer`).
  static const disclaimerMaxLength = 512;

  /// `input_placeholder` (Dify's settings modal).
  static const placeholderMaxLength = 64;
}

/// The Web App site of an app: Dify's `AppDetailSiteResponse` (in [AppInfoAccess.site]) and `AppSiteResponse` (the
/// answer of [AccessApi.updateSite] and [AccessApi.resetAccessToken]; dify-sf answers every member of both).
final class AppSite {
  const AppSite({
    this.appId,
    required this.accessToken,
    required this.title,
    this.iconType,
    this.icon,
    this.iconBackground,
    this.description,
    this.defaultLanguage = 'en-US',
    this.chatColorTheme,
    this.chatColorThemeInverted = false,
    this.customizeDomain,
    this.copyright,
    this.privacyPolicy,
    this.inputPlaceholder,
    this.customDisclaimer = '',
    this.customizeTokenStrategy = CustomizeTokenStrategy.notAllow,
    this.promptPublic = false,
    this.appBaseUrl = '',
    this.showWorkflowSteps = true,
    this.useIconAsAnswerIcon = false,
    this.json = const {},
  });

  factory AppSite.fromJson(Map<String, Object?> m) => AppSite(
    appId: _optStr(m['app_id']),
    accessToken: _str(m['access_token'] ?? m['code']),
    title: _str(m['title']),
    iconType: _optStr(m['icon_type']),
    icon: _optStr(m['icon']),
    iconBackground: _optStr(m['icon_background']),
    description: _optStr(m['description']),
    defaultLanguage: m['default_language'] is String ? m['default_language']! as String : 'en-US',
    chatColorTheme: _optStr(m['chat_color_theme']),
    chatColorThemeInverted: m['chat_color_theme_inverted'] == true,
    customizeDomain: _optStr(m['customize_domain']),
    copyright: _optStr(m['copyright']),
    privacyPolicy: _optStr(m['privacy_policy']),
    inputPlaceholder: _optStr(m['input_placeholder']),
    customDisclaimer: _str(m['custom_disclaimer']),
    customizeTokenStrategy: m['customize_token_strategy'] is String
        ? m['customize_token_strategy']! as String
        : CustomizeTokenStrategy.notAllow,
    promptPublic: m['prompt_public'] == true,
    appBaseUrl: _str(m['app_base_url']),
    showWorkflowSteps: m['show_workflow_steps'] != false,
    useIconAsAnswerIcon: m['use_icon_as_answer_icon'] == true,
    json: m,
  );

  /// The app id (Dify's `AppSiteResponse.app_id`).
  final String? appId;

  /// The site code (Dify's `code`, also sent as `access_token`): 16 letters and digits, the last path segment of the
  /// Web App URL. [AccessApi.resetAccessToken] draws a new one.
  final String accessToken;

  /// Web App title (initially the app's name).
  final String title;
  final String? iconType;
  final String? icon;
  final String? iconBackground;
  final String? description;

  /// [AppSiteLanguages] (initially the creator's interface language).
  final String defaultLanguage;

  /// `#RRGGBB` or null (chat apps).
  final String? chatColorTheme;
  final bool chatColorThemeInverted;

  /// Enterprise; stored, unused.
  final String? customizeDomain;

  /// Locked in Dify's community edition (stored as sent).
  final String? copyright;

  /// An `http(s)` URL or null.
  final String? privacyPolicy;

  /// At most [AppSiteLimits.placeholderMaxLength] characters.
  final String? inputPlaceholder;

  /// At most [AppSiteLimits.disclaimerMaxLength] characters; `""` when there is none.
  final String customDisclaimer;

  /// [CustomizeTokenStrategy].
  final String customizeTokenStrategy;
  final bool promptPublic;

  /// Where the Web App is served (the server's `COLLAB_WEBAPP_BASE_URL`, else the request's origin), no trailing `/`.
  final String appBaseUrl;
  final bool showWorkflowSteps;
  final bool useIconAsAnswerIcon;

  /// The whole answer object.
  final Map<String, Object?> json;

  /// Dify's Web App URL: `${appBaseUrl}/${chat|workflow}/${accessToken}` (`chat` for chatflows).
  String webAppUrl(String appMode) => '$appBaseUrl/${appMode == AppModes.workflow ? 'workflow' : 'chat'}/$accessToken';

  Map<String, Object?> toJson() => json.isNotEmpty
      ? json
      : {
          'app_id': appId,
          'access_token': accessToken,
          'code': accessToken,
          'title': title,
          'icon_type': iconType,
          'icon': icon,
          'icon_background': iconBackground,
          'description': description,
          'default_language': defaultLanguage,
          'chat_color_theme': chatColorTheme,
          'chat_color_theme_inverted': chatColorThemeInverted,
          'customize_domain': customizeDomain,
          'copyright': copyright,
          'privacy_policy': privacyPolicy,
          'input_placeholder': inputPlaceholder,
          'custom_disclaimer': customDisclaimer,
          'customize_token_strategy': customizeTokenStrategy,
          'prompt_public': promptPublic,
          'app_base_url': appBaseUrl,
          'show_workflow_steps': showWorkflowSteps,
          'use_icon_as_answer_icon': useIconAsAnswerIcon,
        };
}

/// The body of [AccessApi.updateSite] (Dify's `AppSiteUpdatePayload`): every member is optional; null members keep
/// their value (a string member cannot be cleared to null, only to `""`, as in Dify).
final class AppSiteUpdate {
  const AppSiteUpdate({
    this.title,
    this.iconType,
    this.icon,
    this.iconBackground,
    this.description,
    this.defaultLanguage,
    this.chatColorTheme,
    this.chatColorThemeInverted,
    this.customizeDomain,
    this.copyright,
    this.privacyPolicy,
    this.inputPlaceholder,
    this.customDisclaimer,
    this.customizeTokenStrategy,
    this.promptPublic,
    this.showWorkflowSteps,
    this.useIconAsAnswerIcon,
  });

  final String? title;
  final String? iconType;
  final String? icon;
  final String? iconBackground;
  final String? description;

  /// [AppSiteLanguages]; anything else is `400 bad_request`.
  final String? defaultLanguage;

  /// `#RGB` / `#RRGGBB` or `""`.
  final String? chatColorTheme;
  final bool? chatColorThemeInverted;
  final String? customizeDomain;
  final String? copyright;

  /// `http://` or `https://` URL, or `""`.
  final String? privacyPolicy;
  final String? inputPlaceholder;
  final String? customDisclaimer;

  /// [CustomizeTokenStrategy].
  final String? customizeTokenStrategy;
  final bool? promptPublic;
  final bool? showWorkflowSteps;
  final bool? useIconAsAnswerIcon;

  Map<String, Object?> toJson() => {
    'title': ?title,
    'icon_type': ?iconType,
    'icon': ?icon,
    'icon_background': ?iconBackground,
    'description': ?description,
    'default_language': ?defaultLanguage,
    'chat_color_theme': ?chatColorTheme,
    'chat_color_theme_inverted': ?chatColorThemeInverted,
    'customize_domain': ?customizeDomain,
    'copyright': ?copyright,
    'privacy_policy': ?privacyPolicy,
    'input_placeholder': ?inputPlaceholder,
    'custom_disclaimer': ?customDisclaimer,
    'customize_token_strategy': ?customizeTokenStrategy,
    'prompt_public': ?promptPublic,
    'show_workflow_steps': ?showWorkflowSteps,
    'use_icon_as_answer_icon': ?useIconAsAnswerIcon,
  };
}

/// One Service API key: Dify's `ApiKeyItem` (`{id, type: "app", token, last_used_at, created_at}`).
final class AppApiKey {
  const AppApiKey({
    required this.id,
    this.type = 'app',
    required this.token,
    this.lastUsedAt,
    this.createdAt,
    this.json = const {},
  });

  factory AppApiKey.fromJson(Map<String, Object?> m) => AppApiKey(
    id: _str(m['id']),
    type: m['type'] is String ? m['type']! as String : 'app',
    token: _str(m['token']),
    lastUsedAt: m['last_used_at'] is num ? (m['last_used_at']! as num).toInt() : null,
    createdAt: m['created_at'] is num ? (m['created_at']! as num).toInt() : null,
    json: m,
  );

  final String id;

  /// Always `app`.
  final String type;

  /// The full key (`app-` + 24 characters); `""` if the server can no longer decrypt it ([unreadable]).
  final String token;

  /// Epoch seconds; null = never used (Dify's "Never"). Always null until a runtime exists.
  final int? lastUsedAt;

  /// Epoch seconds.
  final int? createdAt;

  /// The whole answer object.
  final Map<String, Object?> json;

  /// The server lost the means to decrypt this key (see the library documentation).
  bool get unreadable => token.isEmpty;

  /// Dify's `api-key-table.tsx` mask: the first 3 and the last 20 characters (`app...<last 20>`).
  String get maskedToken =>
      token.length <= 23 ? token : '${token.substring(0, 3)}...${token.substring(token.length - 20)}';

  Map<String, Object?> toJson() => json.isNotEmpty
      ? json
      : {'id': id, 'type': type, 'token': token, 'last_used_at': lastUsedAt, 'created_at': createdAt};
}

/// The Access Point members of [AppInfo] (Dify's `AppDetailWithSite`; protocol 1.11).
extension AppInfoAccess on AppInfo {
  /// The Web App switch (Dify's default for workflow and chatflow apps: on).
  bool get enableSite => json['enable_site'] != false;

  /// The Service API switch (default on).
  bool get enableApi => json['enable_api'] != false;

  /// The Service API base URL (`<origin>/v1`, Dify's `api_base_url`); `""` if the server sent none.
  String get apiBaseUrl => json['api_base_url'] is String ? json['api_base_url']! as String : '';

  /// The Web App site; null on servers older than 1.11.
  AppSite? get site =>
      json['site'] is Map<String, Object?> ? AppSite.fromJson(json['site']! as Map<String, Object?>) : null;
}

/// See the library documentation above. [appId] arguments are app ids (= document ids).
abstract interface class AccessApi {
  /// `POST /v1/apps/{appId}/site` (owner, admin, editor): Web App settings -> the site.
  Future<AppSite> updateSite(String appId, AppSiteUpdate update);

  /// `POST /v1/apps/{appId}/site/access-token-reset` (owner, admin): a new site code -> the site.
  Future<AppSite> resetAccessToken(String appId);

  /// `POST /v1/apps/{appId}/site-enable` `{enable_site}` (owner, admin, editor) -> the app (Dify's `AppDetail`).
  Future<AppInfo> setSiteEnabled(String appId, bool enable);

  /// `POST /v1/apps/{appId}/api-enable` `{enable_api}` (owner, admin) -> the app.
  Future<AppInfo> setApiEnabled(String appId, bool enable);

  /// `GET /v1/apps/{appId}/api-keys` (owner, admin, editor): Dify's `{data: [...]}`, oldest first.
  Future<List<AppApiKey>> listApiKeys(String appId);

  /// `POST /v1/apps/{appId}/api-keys` (owner, admin, editor) -> `201` the new key (full token).
  Future<AppApiKey> createApiKey(String appId);

  /// `DELETE /v1/apps/{appId}/api-keys/{keyId}` (owner, admin) -> `204`.
  Future<void> deleteApiKey(String appId, String keyId);
}

String _str(Object? v) => v is String ? v : '';
String? _optStr(Object? v) => v is String ? v : null;
