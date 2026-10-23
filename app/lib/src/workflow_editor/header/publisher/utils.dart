/// app-publisher/utils.ts and workflow/utils/version.ts.
library;

import '../../../i18n/dify_i18n.dart';

/// Dify's `basePath` (`NEXT_PUBLIC_BASE_PATH`, empty by default): the web app is served from the site's root.
const publisherBasePath = '';

/// `getPublisherAppMode`: the web app route for an app mode (`AppModeEnum` value); everything but completion and
/// workflow apps opens the chat web app.
String getPublisherAppMode(String? mode) => mode != 'completion' && mode != 'workflow' ? 'chat' : mode!;

/// `getPublisherAppUrl`: the published web app, `<app_base_url><basePath>/<mode>/<access_token>`.
String getPublisherAppUrl({required String appBaseUrl, required String accessToken, String? mode}) =>
    '$appBaseUrl$publisherBasePath/${getPublisherAppMode(mode)}/$accessToken';

/// `getDisabledFunctionTooltip`: why the web app actions are unavailable, if they are.
String? getDisabledFunctionTooltip({
  int? publishedAt,
  required bool missingStartNode,
  required bool noAccessPermission,
}) {
  if (publishedAt == null || publishedAt == 0) return DifyI18n.tr('app', 'notPublishedYet');
  if (missingStartNode) return DifyI18n.tr('app', 'noUserInputNode');
  if (noAccessPermission) return DifyI18n.tr('app', 'noAccessPermission');
  return null;
}

/// `getWorkflowVersionName`: a version's marked name, else `# <version number>`, else [defaultName].
String getWorkflowVersionName({String? markedName, int? versionNumber, required String defaultName}) {
  if (markedName != null && markedName.isNotEmpty) return markedName;
  if (versionNumber != null && versionNumber != 0) return '# $versionNumber';
  return defaultName;
}
