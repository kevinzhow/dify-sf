/// The Access Point page's helpers: app/access-point/shared/utils.ts (API reference paths, the published workflow's
/// state, the built-in URLs, the hidden Start inputs), app/overview/app-card-utils.ts (the Launch URL and the embed
/// snippets) and context/i18n.ts `useDocLink` (Dify's documentation links), Dify 1.17.1.
library;

import 'dart:convert';

import 'package:archive/archive.dart' show GZipEncoder;
import 'package:collab_client/collab_client.dart';

import '../../design/widgets/toast.dart';
import '../../i18n/dify_i18n.dart';

typedef Json = Map<String, Object?>;

/// `getAppApiReferencePath`: the docs path of the app's service API reference (none for agents).
String? appApiReferencePath(String mode) => switch (mode) {
  AppModes.advancedChat => '/api-reference/guides/chatflow',
  'agent-chat' || 'chat' => '/api-reference/guides/chat',
  'completion' => '/api-reference/guides/completion',
  AppModes.workflow => '/api-reference/guides/workflow',
  _ => null,
};

/// types/doc-paths.ts `docPathProductAvailability` for the productless paths this page links to: they get the
/// edition's product prefix (`/self-host` on the community edition).
const _productlessDocPaths = {'/use-dify/nodes/start', '/use-dify/nodes/trigger/overview'};

/// `useDocLink()(path)` on the community edition: `https://docs.dify.ai/<en|zh|ja>[/self-host]<path>`.
String difyDocLink(String path, {String? language}) {
  final lang =
      language ??
      switch (DifyI18n.current) {
        DifyI18n(:final language) => language,
        _ => DifyI18n.fallbackLanguage,
      };
  final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[lang] ?? 'en';
  final hash = path.indexOf('#');
  final pathname = hash < 0 ? path : path.substring(0, hash);
  final product = _productlessDocPaths.contains(pathname) ? '/self-host' : '';
  return 'https://docs.dify.ai/$docLanguage$product$path';
}

/// The published workflow (Dify's `WorkflowResponse`, `GET /apps/{id}/workflows/publish`); null: never published.
typedef PublishedWorkflow = Json?;

/// `getPublishedWorkflowNodes`.
List<Json> publishedWorkflowNodes(PublishedWorkflow workflow) => switch (workflow?['graph']) {
  {'nodes': final List<Object?> nodes} => nodes.whereType<Json>().toList(),
  _ => const [],
};

String? _nodeType(Json node) => switch (node['data']) {
  {'type': final String type} => type,
  _ => null,
};

/// `isTriggerNode` (workflow/types.ts): the trigger start nodes.
bool isTriggerNodeType(String? type) =>
    type == 'trigger-webhook' || type == 'trigger-schedule' || type == 'trigger-plugin';

/// `getPublishedWorkflowState`.
({bool hasStartNode, bool hasTriggerNode, bool isUnpublished, bool isWorkflowApp}) publishedWorkflowState(
  String mode,
  PublishedWorkflow workflow,
) {
  final isWorkflowApp = mode == AppModes.workflow;
  final nodes = publishedWorkflowNodes(workflow);
  return (
    hasStartNode: nodes.any((n) => _nodeType(n) == 'start'),
    hasTriggerNode: nodes.any((n) => isTriggerNodeType(_nodeType(n))),
    isUnpublished: isWorkflowApp && workflow?['graph'] == null,
    isWorkflowApp: isWorkflowApp,
  );
}

/// `isAdvancedApp`.
bool isAdvancedApp(String mode) => mode == AppModes.workflow || mode == AppModes.advancedChat;

/// `getBuiltInAccessUrls`: the service API's base URL and the Web App's URL: the site's `app_base_url`, then `chat`,
/// `workflow` or `completion`, then the site's `access_token` (Dify's `basePath` being empty).
({String api, String webApp}) builtInAccessUrls(AppInfo app) {
  final mode = app.mode == 'completion' || app.mode == AppModes.workflow ? app.mode : 'chat';
  final site = app.site;
  return (api: app.apiBaseUrl, webApp: '${site?.appBaseUrl ?? ''}/$mode/${site?.accessToken ?? ''}');
}

/// The Start node's variables (`InputVar`) hidden from the Web App's form (`getHiddenStartInputs`).
List<Json> hiddenStartInputs(PublishedWorkflow workflow) {
  final start = publishedWorkflowNodes(workflow).where((n) => _nodeType(n) == 'start').firstOrNull;
  final variables = switch (start?['data']) {
    {'variables': final List<Object?> vs} => vs.whereType<Json>(),
    _ => const <Json>[],
  };
  return [
    for (final v in variables)
      if (v['hide'] == true) v,
  ];
}

/// `WorkflowLaunchInputValue`: a string, or a bool for checkboxes.
typedef LaunchValue = Object;

const _launchInputTypes = {'text-input', 'paragraph', 'select', 'number', 'checkbox', 'json', 'json_object', 'url'};

/// `isWorkflowLaunchInputSupported`.
bool isWorkflowLaunchInputSupported(Json variable) => _launchInputTypes.contains(variable['type']);

LaunchValue _defaultValue(Json variable) {
  final d = variable['default'];
  if (variable['type'] == 'checkbox') return d is bool ? d : '$d'.toLowerCase() == 'true';
  if (d is num) return _jsNumber(d);
  return d == null ? '' : '$d';
}

/// `String(n)` as JavaScript writes it (no `.0` on whole numbers).
String _jsNumber(num n) => n is double && n == n.truncateToDouble() && n.isFinite ? '${n.toInt()}' : '$n';

/// `createWorkflowLaunchInitialValues`.
Map<String, LaunchValue> workflowLaunchInitialValues(List<Json> variables) => {
  for (final v in variables) '${v['variable']}': _defaultValue(v),
};

String _serialized(Json variable, Map<String, LaunchValue> values) {
  final raw = values['${variable['variable']}'];
  if (variable['type'] == 'checkbox') return '${raw == true || (raw is String && raw.isNotEmpty)}';
  return raw == null ? '' : '$raw';
}

/// `buildWorkflowLaunchUrl`: [accessibleUrl] with each hidden variable as a search parameter.
String buildWorkflowLaunchUrl({
  required String accessibleUrl,
  required List<Json> variables,
  required Map<String, LaunchValue> values,
}) {
  final uri = Uri.parse(accessibleUrl);
  final params = Map<String, String>.of(uri.queryParameters);
  for (final v in variables) {
    params['${v['variable']}'] = _serialized(v, values);
  }
  return uri.replace(queryParameters: params).toString();
}

/// `getEmbeddedIframeSnippet`.
String embeddedIframeSnippet(String iframeUrl) =>
    '<iframe\n'
    ' src="$iframeUrl"\n'
    ' style="width: 100%; height: 100%; min-height: 700px"\n'
    ' frameborder="0"\n'
    ' allow="microphone;clipboard-write">\n'
    '</iframe>';

String _scriptInputs(Map<String, LaunchValue> values) {
  if (values.isEmpty) {
    return '{\n'
        '    // You can define the inputs from the Start node here\n'
        '    // key is the variable name\n'
        '    // e.g.\n'
        '    // name: "NAME"\n'
        '  }';
  }
  return '{\n${values.entries.map((e) => '    ${e.key}: ${jsonEncode(e.value)},').join('\n')}\n  }';
}

/// `getEmbeddedScriptSnippet` (`webAppRoute` `chatbot`, or `agent`).
String embeddedScriptSnippet({
  required String url,
  required String token,
  String webAppRoute = 'chatbot',
  required String primaryColor,
  bool isTestEnv = false,
  required Map<String, LaunchValue> inputValues,
}) =>
    '<script>\n'
    ' window.difyChatbotConfig = {\n'
    "  token: '$token'${isTestEnv ? ',\n  isDev: true' : ''},\n"
    "  baseUrl: '$url'${webAppRoute != 'chatbot' ? ",\n  routeSegment: '$webAppRoute'" : ''},\n"
    '  inputs: ${_scriptInputs(inputValues)},\n'
    '  systemVariables: {\n'
    "    // user_id: 'YOU CAN DEFINE USER ID HERE',\n"
    "    // conversation_id: 'YOU CAN DEFINE CONVERSATION ID HERE, IT MUST BE A VALID UUID',\n"
    '  },\n'
    '  userVariables: {\n'
    "    // avatar_url: 'YOU CAN DEFINE USER AVATAR URL HERE',\n"
    "    // name: 'YOU CAN DEFINE USER NAME HERE',\n"
    '  },\n'
    ' }\n'
    '</script>\n'
    '<script\n'
    ' src="$url/embed.min.js"\n'
    ' id="$token"\n'
    ' defer>\n'
    '</script>\n'
    '<style>\n'
    '  #dify-chatbot-bubble-button {\n'
    '    background-color: $primaryColor !important;\n'
    '  }\n'
    '  #dify-chatbot-bubble-window {\n'
    '    width: 24rem !important;\n'
    '    height: 40rem !important;\n'
    '  }\n'
    '</style>';

/// `getChromePluginContent`.
String chromePluginContent(String iframeUrl) => 'ChatBot URL: $iframeUrl';

/// `compressAndEncodeBase64`: gzip, then base64 (the browser's CompressionStream; `package:archive` here, so every
/// platform compresses).
String compressAndEncodeBase64(String input) => base64Encode(GZipEncoder().encodeBytes(utf8.encode(input)));

/// embedded/index.tsx `buildEmbeddedIframeUrl`: `<app_base_url>/<route>/<token>` with each hidden input gzipped and
/// base64-encoded as a search parameter.
String buildEmbeddedIframeUrl({
  required String appBaseUrl,
  required String accessToken,
  String webAppRoute = 'chatbot',
  required List<Json> variables,
  required Map<String, LaunchValue> values,
}) {
  final uri = Uri.parse('$appBaseUrl/$webAppRoute/$accessToken');
  if (variables.isEmpty) return uri.toString();
  return uri
      .replace(
        queryParameters: {
          ...uri.queryParameters,
          for (final v in variables) '${v['variable']}': compressAndEncodeBase64(_serialized(v, values)),
        },
      )
      .toString();
}

/// embedded-chatbot/theme `createTheme(...).primaryColor`.
String chatPrimaryColor(String? chatColorTheme) =>
    chatColorTheme == null || chatColorTheme.isEmpty ? '#1C64F2' : chatColorTheme;

/// react-query's retry for the published workflow (`useAppWorkflow` in built-in-access-points.tsx): never after a
/// 403, else up to three times.
bool retryPublishedWorkflow(int failureCount, Object error) {
  if (error is TransportException && error.statusCode == 403) return false;
  return failureCount < 3;
}

final _recentGetErrors = <String, DateTime>{};

/// Dify's request layer (service/fetch.ts `afterResponseErrorCode`, request-error-toast.ts): a failed request whose
/// answer carries a message (anything but 401) toasts that message; a failed GET ([get]) does so at most once per
/// request and message within 10 s (react-query's retries do not repeat it). [request] names the request.
void notifyRequestError(Object error, {bool get = false, String request = '', DateTime Function() now = DateTime.now}) {
  if (error is! TransportException || error.statusCode == 401 || error.message.isEmpty) return;
  if (get) {
    final key = '$request\u0000${error.message}', t = now();
    final previous = _recentGetErrors[key];
    if (previous != null && t.difference(previous) < const Duration(seconds: 10)) return;
    _recentGetErrors[key] = t;
  }
  toast.error(error.message);
}

/// `clearRequestErrorToasts`: a successful answer to [request] lets its next failure toast again; without [request]
/// every request's (a new session, tests).
void clearRequestErrors([String? request]) =>
    request == null ? _recentGetErrors.clear() : _recentGetErrors.removeWhere((k, _) => k.startsWith('$request\u0000'));
