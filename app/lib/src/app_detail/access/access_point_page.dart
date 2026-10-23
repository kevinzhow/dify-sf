/// The Access Point page of an opened app (Dify 1.17.1 app/access-point: index.tsx and built-in-access-points): the
/// Web App, Service API, MCP server and Trigger cards of the built-in environment (deployment environments are
/// enterprise-only), with Dify's "No published versions yet" banner for workflow apps never published.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../active_page.dart';
import '../../open_url.dart';
import '../app_permission.dart';
import '../detail_page_slot.dart';
import 'access_point_card.dart';
import 'access_point_utils.dart';
import 'mcp_trigger_cards.dart';
import 'service_api_card.dart';
import 'site_settings_modal.dart';
import 'web_app_card.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// The page's [AppDetailPageBuilder] (registered in `detail_pages.dart`).
Widget buildAccessPointPage(BuildContext context, AppDetailContext detail) => AccessPointPage(
  app: detail.app,
  access: detail.service<AccessApi>(),
  versions: detail.service<VersionsApi>(),
  highlightedAccessPoint: detail.query['accessPoint'],
  refreshApp: detail.refreshApp,
  goToPublish: () => detail.navigate(AppDetailPageId.workflow),
);

/// The access points (`ACCESS_POINT_ORDER`), as `?accessPoint=` names them.
abstract final class AccessPoints {
  static const webApp = 'webApp', serviceApi = 'serviceApi', mcp = 'mcp', trigger = 'trigger';
}

/// AccessPoint: "Access Point" and its description over the built-in access points (scrolling).
class AccessPointPage extends StatefulWidget {
  const AccessPointPage({
    super.key,
    required this.app,
    this.access,
    this.versions,
    this.highlightedAccessPoint,
    this.refreshApp,
    this.goToPublish,
    this.openUrl,
    this.retryDelay = _retryDelay,
  });

  /// The open app (with its site, protocol 1.11).
  final ValueListenable<AppInfo> app;

  /// The Access Point's API; null: no server (switches and keys do nothing).
  final AccessApi? access;

  /// The published workflow's source; null: never published (as a server without publishing answers).
  final VersionsApi? versions;
  final String? highlightedAccessPoint;
  final Future<void> Function()? refreshApp;

  /// "Go to publish": opens the editor.
  final VoidCallback? goToPublish;
  final void Function(String url)? openUrl;

  /// react-query's retry delay before the [attempt]th retry.
  final Duration Function(int attempt) retryDelay;

  static Duration _retryDelay(int attempt) => Duration(milliseconds: math.min(1000 * (1 << attempt), 30000));

  @override
  State<AccessPointPage> createState() => AccessPointPageState();
}

class AccessPointPageState extends State<AccessPointPage> {
  /// The app with the switches' stored changes (Dify's `setAppDetail`) until the shell refetches it.
  late final ValueNotifier<AppInfo> app = ValueNotifier(widget.app.value);

  /// The published workflow's query (`useAppWorkflow`).
  PublishedWorkflow workflow;
  bool workflowPending = true, workflowError = false;
  int _load = 0;
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_appChanged);
    _fetchWorkflow();
  }

  @override
  void didUpdateWidget(AccessPointPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_appChanged);
      widget.app.addListener(_appChanged);
      _appChanged();
    }
    if (oldWidget.versions != widget.versions) _fetchWorkflow();
  }

  bool? _active;

  /// Showing the page again asks for the published workflow again (react-query refetches a query when a component
  /// using it mounts): a collaborator may have published meanwhile.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = context.dependOnInheritedWidgetOfExactType<ActivePage>()?.active ?? true;
    if (_active == false && active) _fetchWorkflow();
    _active = active;
  }

  @override
  void dispose() {
    widget.app.removeListener(_appChanged);
    app.dispose();
    super.dispose();
  }

  /// A refetched app (after an edit, a publish or a new token): the cards follow it, and the published workflow is
  /// asked again (Dify invalidates it on publish).
  void _appChanged() {
    app.value = widget.app.value;
    _fetchWorkflow();
  }

  bool get _shouldFetch => isAdvancedApp(app.value.mode);

  /// `useAppWorkflow(appId, {retry})`: never retried after a 403, else up to three times.
  void _fetchWorkflow() {
    final id = app.value.id;
    final load = ++_load;
    if (!_shouldFetch) {
      workflow = null;
      workflowPending = false;
      workflowError = false;
      if (mounted) setState(() {});
      return;
    }
    if (_loadedFor != id) {
      // A first load (or another app): pending until it answers; a refetch keeps the current data.
      workflowPending = true;
      _loadedFor = id;
    }
    final versions = widget.versions;
    Future<void> attempt(int failures) async {
      try {
        final published = versions == null ? null : await versions.published(id);
        clearRequestErrors('GET /apps/$id/workflows/publish');
        if (!mounted || load != _load) return;
        setState(() {
          workflow = published?.toJson();
          workflowPending = false;
          workflowError = false;
        });
      } on Object catch (e) {
        if (!mounted || load != _load) return;
        // Every failed answer goes through Dify's request layer (deduplicated for GETs): normal members and dataset
        // operators get the server's 403 message once, as in Dify (no banner, cards unavailable for workflow apps).
        notifyRequestError(e, get: true, request: 'GET /apps/$id/workflows/publish');
        if (retryPublishedWorkflow(failures, e)) {
          await Future<void>.delayed(widget.retryDelay(failures));
          if (mounted && load == _load) await attempt(failures + 1);
          return;
        }
        setState(() {
          workflow = null;
          workflowPending = false;
          workflowError = true;
        });
      }
    }

    unawaited(attempt(0));
  }

  /// `useAccessPointActions().saveSiteConfig`: Dify's success or failure toast; a success refetches the app.
  Future<void> saveSiteConfig(SiteConfigParams params, {required bool canManageAccessPoint}) async {
    if (!canManageAccessPoint) return;
    final api = widget.access;
    Object? error;
    try {
      if (api == null) throw StateError('No server');
      await api.updateSite(app.value.id, siteUpdateOf(params));
    } on Object catch (e) {
      error = e;
      notifyRequestError(e);
    }
    handleResult(error);
  }

  /// `useAccessPointActions().handleResult`.
  void handleResult(Object? error, [String? message]) {
    if (error == null) unawaited(widget.refreshApp?.call());
    final text = _t(
      'common',
      'actionMsg.${message ?? (error == null ? 'modifiedSuccessfully' : 'modifiedUnsuccessfully')}',
    );
    error == null ? toast.success(text) : toast.error(text);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: app,
    builder: (context, info, _) {
      final caps = appACLCapabilitiesOf(info);
      return ColoredBox(
        color: DifyColors.componentsPanelBg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      SizedBox(
                        height: 24,
                        child: Semantics(
                          header: true,
                          child: DifyTextLine(
                            _t('common', 'appMenus.accessPoint'),
                            style: difyTextStyle(DifyType.titleXlSemiBold, DifyColors.textPrimary),
                          ),
                        ),
                      ),
                      DifyTextLine(
                        _t('deployments', 'studio.accessPoint.description'),
                        style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                      ),
                    ],
                  ),
                  // The environment tabs show for workflows and chatflows the user may view: on the community edition
                  // the built-in environment alone (deployment environments are enterprise).
                  if (isAdvancedApp(info.mode) && caps.canViewAccessPoint) const EnvironmentTabs(),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: BuiltInAccessPoints(
                  app: info,
                  appListenable: app,
                  access: widget.access,
                  workflow: workflow,
                  workflowPending: workflowPending,
                  workflowError: workflowError,
                  canDeploy: caps.canDeploy,
                  canManageAccessPoint: caps.canManageAccessPoint,
                  canReleaseAndVersion: caps.canReleaseAndVersion,
                  highlightedAccessPoint: widget.highlightedAccessPoint,
                  onAppChanged: (a) => app.value = a,
                  onRefreshApp: widget.refreshApp,
                  onSaveSiteConfig: (p) => saveSiteConfig(p, canManageAccessPoint: caps.canManageAccessPoint),
                  goToPublish: widget.goToPublish,
                  openUrl: widget.openUrl,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// BuiltInAccessPoints: the unpublished banner, the cards (one column, two from 1280 px wide; Trigger for workflow
/// apps only) and the trigger-mode notice. Cards are unavailable for a workflow app that is unpublished or published
/// with a trigger start, loading while the published workflow loads.
class BuiltInAccessPoints extends StatelessWidget {
  const BuiltInAccessPoints({
    super.key,
    required this.app,
    required this.workflow,
    required this.canDeploy,
    required this.canManageAccessPoint,
    required this.canReleaseAndVersion,
    this.workflowPending = false,
    this.workflowError = false,
    this.appListenable,
    this.access,
    this.highlightedAccessPoint,
    this.onAppChanged,
    this.onRefreshApp,
    this.onSaveSiteConfig,
    this.goToPublish,
    this.openUrl,
  });

  final AppInfo app;
  final ValueListenable<AppInfo>? appListenable;
  final AccessApi? access;
  final PublishedWorkflow workflow;
  final bool workflowPending, workflowError;
  final bool canDeploy, canManageAccessPoint, canReleaseAndVersion;
  final String? highlightedAccessPoint;
  final ValueChanged<AppInfo>? onAppChanged;
  final Future<void> Function()? onRefreshApp;
  final Future<void> Function(SiteConfigParams params)? onSaveSiteConfig;
  final VoidCallback? goToPublish;
  final void Function(String url)? openUrl;

  bool get _workflowLoading => isAdvancedApp(app.mode) && workflowPending;

  /// The workflow's state and the cards' availability (built-in-access-points.tsx).
  ({
    ({bool hasStartNode, bool hasTriggerNode, bool isUnpublished, bool isWorkflowApp}) state,
    AccessPointAvailability appCards,
    AccessPointAvailability trigger,
  })
  get availability {
    final state = publishedWorkflowState(app.mode, workflow);
    final loading = state.isWorkflowApp && _workflowLoading;
    final unavailable = state.isWorkflowApp && (state.isUnpublished || state.hasTriggerNode);
    return (
      state: state,
      appCards: loading
          ? AccessPointAvailability.loading
          : unavailable
          ? AccessPointAvailability.unavailable
          : AccessPointAvailability.available,
      trigger: loading
          ? AccessPointAvailability.loading
          : state.isUnpublished || !state.hasTriggerNode
          ? AccessPointAvailability.unavailable
          : AccessPointAvailability.available,
    );
  }

  Widget _banner() => Container(
    key: const ValueKey('access-point-unpublished'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            DifyTextLine(
              _t('deployments', 'studio.accessPoint.noPublishedTitle'),
              style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
            ),
            DifyTextLine(
              _t('deployments', 'studio.accessPoint.noPublishedDescription'),
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
            ),
          ],
        ),
        DifyButton(
          key: const ValueKey('access-point-go-to-publish'),
          variant: DifyButtonVariant.primary,
          disabled: !canReleaseAndVersion,
          onPressed: canReleaseAndVersion ? goToPublish : null,
          trailing: const RemixIcon('arrow-right-line', size: 16),
          child: DifyTextLine(_t('deployments', 'studio.accessPoint.goToPublish')),
        ),
      ],
    ),
  );

  Widget _triggerNotice() => Container(
    key: const ValueKey('access-point-trigger-notice'),
    margin: const EdgeInsets.only(top: 8),
    constraints: const BoxConstraints(minHeight: 40),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: Row(
      spacing: 8,
      children: [
        RemixIcon('information-line', size: 16, color: DifyColors.textTertiary),
        Expanded(
          child: DifyTextLine.rich(
            TextSpan(
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
              children: [
                TextSpan(text: '${_t('deployments', 'studio.accessPoint.triggerExclusiveNotice')} '),
                TextSpan(
                  text: _t('common', 'operation.learnMore'),
                  style: TextStyle(color: DifyColors.textAccent),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () {
                      final url = difyDocLink('/use-dify/nodes/start');
                      (openUrl ?? (u) => unawaited(openExternalUrl(u)))(url);
                    },
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = availability;
    final state = a.state;
    final cards = <Widget>[
      WebAppAccessPointCard(
        app: app,
        appListenable: appListenable,
        api: access,
        availability: a.appCards,
        canDeploy: canDeploy,
        canManageAccess: canReleaseAndVersion,
        canManageAccessPoint: canManageAccessPoint,
        workflow: workflow,
        highlighted: highlightedAccessPoint == AccessPoints.webApp,
        onRefreshApp: onRefreshApp,
        onSaveSiteConfig: onSaveSiteConfig,
        onAppChanged: onAppChanged,
        openUrl: openUrl,
      ),
      ServiceApiAccessPointCard(
        app: app,
        api: access,
        availability: a.appCards,
        canManage: canManageAccessPoint,
        highlighted: highlightedAccessPoint == AccessPoints.serviceApi,
        onAppChanged: onAppChanged,
        onOpen: openUrl,
      ),
      MCPAccessPointCard(
        canManageAccessPoint: canManageAccessPoint,
        workflowLoading: _workflowLoading,
        triggerModeDisabled: state.hasTriggerNode,
        highlighted: highlightedAccessPoint == AccessPoints.mcp,
      ),
      if (state.isWorkflowApp)
        TriggerAccessPointCard(
          availability: a.trigger,
          canManageAccessPoint: canManageAccessPoint,
          highlighted: highlightedAccessPoint == AccessPoints.trigger,
          openUrl: openUrl,
        ),
    ];
    // Tailwind's `xl:grid-cols-2`: two columns from a 1280 px wide viewport; a row's cards share its height.
    final twoColumns = MediaQuery.sizeOf(context).width >= 1280;
    final grid = twoColumns
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              for (var i = 0; i < cards.length; i += 2)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      Expanded(child: cards[i]),
                      Expanded(child: i + 1 < cards.length ? cards[i + 1] : const SizedBox()),
                    ],
                  ),
                ),
            ],
          )
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 12, children: cards);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (state.isUnpublished && !workflowPending && !workflowError) _banner(),
        grid,
        if (state.hasTriggerNode) _triggerNotice(),
      ],
    );
  }
}

/// `getAppACLCapabilities` of [app]'s permission keys.
AppACLCapabilities appACLCapabilitiesOf(AppInfo app) => appACLCapabilities(app.permissionKeys);

/// The environment tabs (`TabsList min-w-max gap-1`) with the built-in environment, selected: `h-8 rounded-lg px-2.5`,
/// `bg-state-base-active system-sm-semibold text-text-secondary`.
class EnvironmentTabs extends StatelessWidget {
  const EnvironmentTabs({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('access-point-environment-tabs'),
      container: true,
      label: _t('deployments', 'studio.environments'),
      // dify-sf has the built-in environment only: its tab is always the active one.
      child: DifyTab(
        style: DifyTabStyle.pill,
        label: _t('workflow', 'nodes.common.memories.builtIn'),
        active: true,
        onPressed: () {},
      ),
    );
  }
}
