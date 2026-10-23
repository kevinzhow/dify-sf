/// The Overview page of an opened app (Dify 1.17.1's `[appId]/overview`: `view.tsx`, `chart-view.tsx`): the
/// "set up a model provider" panel, the "Monitoring" header with its period picker, and the statistics charts of the
/// app's mode. Only for members with `app.acl.monitor`.
///
/// The tracing entry (`TracingPanel`, `canConfigureTracing`) is not shown yet: per-app tracing configuration is a
/// later phase of dify-sf.
library;

import 'package:collab_client/collab_client.dart' show AppInfo, AppModes, StatsApi;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import '../../settings/integrations_page.dart' show showModelProviderSettings;
import '../../workflow/workspace_models.dart';
import '../app_permission.dart';
import '../detail_page_slot.dart';
import 'apikey_info_panel.dart';
import 'app_chart.dart';
import 'time_range.dart';

/// The registered page builder.
Widget buildOverviewPage(BuildContext context, AppDetailContext detail) => OverviewView(
  app: detail.app,
  models: detail.models,
  role: detail.account?.role,
  stats: detail.service<StatsApi>(),
);

/// `docLink('/use-dify/monitor/analysis')` on the community edition (the path exists for cloud and self-host, so it
/// gets the `/self-host` product prefix).
String overviewDocLink() {
  final lang = switch (DifyI18n.current) {
    DifyI18n(:final language) => language,
    _ => DifyI18n.fallbackLanguage,
  };
  final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[lang] ?? 'en';
  return 'https://docs.dify.ai/$docLanguage/self-host/use-dify/monitor/analysis';
}

/// `OverviewView`: nothing without `canMonitor`; else the API key panel over the [ChartView].
class OverviewView extends StatelessWidget {
  const OverviewView({
    super.key,
    required this.app,
    this.models,
    this.role,
    this.stats,
    this.now,
    this.openUrl,
    this.openProviderSettings,
    this.tracingPanel,
  });

  final ValueListenable<AppInfo> app;
  final WorkspaceModels? models;

  /// The signed-in member's role (the model provider settings' rights).
  final String? role;
  final StatsApi? stats;

  /// Dify's `today` (the periods); the system clock when null.
  final DateTime Function()? now;
  final void Function(String url)? openUrl;

  /// Opens the model provider settings; by default [showModelProviderSettings] over [models].
  final void Function(BuildContext context)? openProviderSettings;

  /// The tracing entry for members with `canConfigureTracing` (`TracingPanel`); none yet in dify-sf.
  final Widget? tracingPanel;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppInfo>(
    valueListenable: app,
    builder: (context, info, _) {
      final acl = appACLCapabilities(info.permissionKeys);
      if (!acl.canMonitor) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ApikeyInfoPanel(
            models: models,
            openUrl: openUrl,
            openProviderSettings: () {
              if (openProviderSettings case final open?) return open(context);
              if (models case final m?) showModelProviderSettings(context, models: m, role: role);
            },
          ),
          Expanded(
            child: ChartView(
              app: info,
              stats: stats,
              now: now,
              openUrl: openUrl,
              headerRight: acl.canConfigureTracing ? tracingPanel : null,
            ),
          ),
        ],
      );
    },
  );
}

/// `ChartView`: the header (`h-26.5`: the title, the description with "Learn more", the period picker and
/// [headerRight]) over the scrolling chart grid (one column, two from Tailwind's `xl`, 1280 px).
class ChartView extends StatefulWidget {
  const ChartView({super.key, required this.app, this.stats, this.headerRight, this.now, this.openUrl});

  final AppInfo app;
  final StatsApi? stats;
  final Widget? headerRight;
  final DateTime Function()? now;
  final void Function(String url)? openUrl;

  @override
  State<ChartView> createState() => _ChartViewState();
}

class _ChartViewState extends State<ChartView> {
  /// Dify's module-level `today`, taken when the page is first shown.
  late final DateTime _today = widget.now?.call() ?? DateTime.now();
  late PeriodParams _period = defaultOverviewPeriod(_today);

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (!appACLCapabilities(app.permissionKeys).canMonitor) return const SizedBox.shrink();
    final isWorkflow = app.mode == AppModes.workflow;
    final isChatApp = app.mode != AppModes.completion && !isWorkflow;
    final charts = isWorkflow
        ? const [
            BizCharts.workflowMessages,
            BizCharts.workflowDailyTerminals,
            BizCharts.workflowCost,
            BizCharts.avgUserInteractions,
          ]
        : [
            BizCharts.conversations,
            BizCharts.endUsers,
            isChatApp ? BizCharts.avgSessionInteractions : BizCharts.avgResponseTime,
            BizCharts.tokenPerSecond,
            BizCharts.userSatisfactionRate,
            BizCharts.cost,
            if (isChatApp) BizCharts.messages,
          ];
    final twoColumns = MediaQuery.sizeOf(context).width >= 1280;
    final cells = [
      for (final c in charts)
        BizChart(
          key: ValueKey(c.statistic),
          config: c,
          appId: app.id,
          period: _period,
          source: widget.stats,
          now: widget.now,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 106, child: _header(context)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (!twoColumns)
                  ...cells
                else
                  for (var i = 0; i < cells.length; i += 2)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        Expanded(child: cells[i]),
                        Expanded(child: i + 1 < cells.length ? cells[i + 1] : const SizedBox.shrink()),
                      ],
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 24,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Semantics(
                  header: true,
                  child: DifyTextLine(
                    DifyI18n.tr('common', 'appMenus.overview'),
                    style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Flexible(
                    child: DifyTextLine(
                      DifyI18n.tr('appLog', 'monitoring.description'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                    ),
                  ),
                  _LearnMore(onOpen: () => (widget.openUrl ?? openExternalUrl)(overviewDocLink())),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.only(left: 24, right: 40),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              LongTimeRangePicker(today: _today, onSelect: (p) => setState(() => _period = p)),
              ?widget.headerRight,
            ],
          ),
        ),
      ),
    ],
  );
}

/// "Learn more" (`inline-flex items-center text-text-accent hover:underline` + `i-ri-external-link-line size-3`).
class _LearnMore extends StatelessWidget {
  const _LearnMore({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('common', 'operation.learnMore');
    return Semantics(
      link: true,
      label: label,
      excludeSemantics: true,
      onTap: onOpen,
      child: DifyPressable(
        onPressed: onOpen,
        builder: (context, hovered, focused) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DifyTextLine(
              label,
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textAccent).copyWith(
                decoration: hovered ? TextDecoration.underline : null,
                decorationColor: DifyColors.textAccent,
              ),
            ),
            RemixIcon('external-link-line', size: 12, color: DifyColors.textAccent),
          ],
        ),
      ),
    );
  }
}
