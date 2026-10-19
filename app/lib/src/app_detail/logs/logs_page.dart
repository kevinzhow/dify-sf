/// The Logs page (Dify 1.17.1's `[appId]/logs`, `app/components/app/log-annotation/index.tsx`): the chat apps'
/// conversation logs or the workflow app's run logs, by mode (no tabs since 1.17).
library;

import 'package:collab_client/collab_client.dart' show AppInfo, AppModes;
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../open_url.dart';
import '../app_permission.dart' show appRedirectionPath;
import '../detail_page_slot.dart';
import 'chat_log.dart';
import 'log_widgets.dart';
import 'logs_data.dart';
import 'workflow_log.dart';

/// `PageType` of the log-annotation page.
enum LogPageType { log, annotation }

/// log-annotation/index.tsx: the loading state without an app, else the annotations ([annotationBuilder]) or the
/// logs: [WorkflowLogs] for workflow apps, [ChatLogs] for every other mode.
class LogAnnotation extends StatelessWidget {
  const LogAnnotation({
    super.key,
    required this.app,
    required this.pageType,
    required this.source,
    this.annotationBuilder,
    this.logBuilder,
    this.workflowLogBuilder,
  });

  /// Null: the app is still loading.
  final AppInfo? app;
  final LogPageType pageType;
  final AppLogsSource source;

  /// The Annotations page (built by `app_detail/annotations/`).
  final Widget Function(BuildContext context, AppInfo app)? annotationBuilder;

  /// Replace the chat / workflow logs (tests, and the page's navigation wiring).
  final Widget Function(BuildContext context, AppInfo app)? logBuilder, workflowLogBuilder;

  @override
  Widget build(BuildContext context) {
    final a = app;
    if (a == null) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'status',
        child: ColoredBox(color: DifyColors.backgroundBody, child: const LogLoading()),
      );
    }
    final isWorkflow = a.mode == AppModes.workflow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: switch (pageType) {
        LogPageType.annotation => annotationBuilder?.call(context, a) ?? const SizedBox.shrink(),
        LogPageType.log when isWorkflow => workflowLogBuilder?.call(context, a) ?? WorkflowLogs(app: a, source: source),
        LogPageType.log => logBuilder?.call(context, a) ?? ChatLogs(app: a, source: source),
      },
    );
  }
}

/// The Logs page of the app detail shell.
Widget buildLogsPage(BuildContext context, AppDetailContext detail) => _LogsPage(detail: detail);

class _LogsPage extends StatelessWidget {
  const _LogsPage({required this.detail});
  final AppDetailContext detail;

  /// The empty state's "testing" link: Dify's `getRedirectionPath` for the app.
  String _testPath(AppInfo app) => appRedirectionPath(id: app.id, mode: app.mode, permissionKeys: app.permissionKeys);

  void _test(AppInfo app) {
    final page = AppDetailPageId.fromPath(_testPath(app));
    if (page != null) detail.navigate(page);
  }

  /// The empty state's "sharing" link: the web app in a new tab, or the Access Point page while the server sends no
  /// site (before protocol 1.11).
  void _share(AppInfo app) {
    final url = LogEmptyElement.shareUrlOf(appSite(app), app.mode);
    if (url != null) {
      openExternalUrl(url);
    } else {
      detail.navigate(AppDetailPageId.accessPoint);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = appLogsSourceOf(detail);
    return ValueListenableBuilder<AppInfo>(
      valueListenable: detail.app,
      builder: (context, app, _) => LogAnnotation(
        key: ValueKey('logs-${app.id}-${app.mode}'),
        app: app,
        pageType: LogPageType.log,
        source: source,
        workflowLogBuilder: (context, app) => WorkflowLogs(
          app: app,
          source: source,
          testPath: _testPath(app),
          onTest: () => _test(app),
          onShare: () => _share(app),
          onReplay: (runId) => detail.navigate(AppDetailPageId.workflow, query: {'replayRunId': runId}),
        ),
        logBuilder: (context, app) => ChatLogs(
          app: app,
          source: source,
          testPath: _testPath(app),
          onTest: () => _test(app),
          onShare: () => _share(app),
          initialPage: switch (int.tryParse(detail.query['page'] ?? '')) {
            final p? when p >= 1 => p - 1,
            _ => 0,
          },
          conversationId: detail.query['conversation_id'],
        ),
      ),
    );
  }
}
