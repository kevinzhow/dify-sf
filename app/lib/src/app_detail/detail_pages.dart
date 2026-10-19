/// The registry of app detail pages and of the APIs they get (see `detail_page_slot.dart`). One line per page / API.
library;

import 'package:collab_client/collab_client.dart';

import '../workflow_editor/run/server_run_service.dart' show ServerWorkflowRuntime;

import 'access/access_point_page.dart';
import 'annotations/annotations_page.dart';
import 'detail_page_slot.dart';
import 'logs/logs_page.dart';
import 'overview/overview_page.dart';

const Map<AppDetailPageId, AppDetailPageBuilder> registeredAppDetailPages = {
  AppDetailPageId.accessPoint: buildAccessPointPage,
  AppDetailPageId.annotations: buildAnnotationsPage,
  AppDetailPageId.logs: buildLogsPage,
  AppDetailPageId.overview: buildOverviewPage,
};

/// The APIs of a signed-in session on a real server, by type ([AppDetailContext.service]): one entry per API, for
/// example `AccessApi: HttpAccessApi(server, auth: auth)`. Tests and the demo pass their own map (fakes). The editor's
/// [ServerWorkflowRuntime] only when the server's [features] announce a workflow runtime (protocols 1.13, 1.14).
Map<Type, Object> httpAppDetailServices(
  Uri server,
  TokenProvider auth, {
  SystemFeatures features = SystemFeatures.none,
}) => {
  AccessApi: HttpAccessApi(server, auth: auth),
  VersionsApi: HttpVersionsApi(server, auth: auth),
  AnnotationsApi: HttpAnnotationsApi(server, auth: auth),
  StatsApi: HttpStatsApi(server, auth: auth),
  LogsApi: HttpLogsApi(server, auth: auth),
  if (features.workflowRuntime case final runtime?)
    ServerWorkflowRuntime: ServerWorkflowRuntime(
      api: HttpWorkflowRunApi(server, auth: auth),
      singleNodeRun: runtime.singleNodeRun,
      draftRun: runtime.draftRun,
    ),
};
