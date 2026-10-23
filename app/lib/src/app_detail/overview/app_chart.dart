/// web/app/components/app/overview/app-chart.tsx (Dify 1.17.1): the chart card (`Chart`) and the per-statistic
/// charts (`createBizChartComponent`), which fetch their series and fall back to Dify's empty rows.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppStatistic, StatsApi;
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'app_chart_canvas.dart';
import 'app_chart_utils.dart';
import 'time_range.dart';
import '../../design/widgets/widgets.dart';

/// `Chart`: a `h-79 rounded-xl` card with the title (and its explanation infotip), the summary (grey when it is
/// zero; token charts add the price) and the 240 px chart.
class AppChart extends StatelessWidget {
  const AppChart({
    super.key,
    required this.title,
    required this.explanation,
    required this.timePeriod,
    required this.chartType,
    required this.statistics,
    this.valueKey,
    this.isAvg = false,
    this.unit = '',
    this.yMax,
  });

  final String title, explanation;

  /// `basicInfo.timePeriod`: passed along, not shown (as in Dify).
  final String timePeriod;
  final ChartType chartType;
  final List<ChartRow> statistics;
  final String? valueKey;
  final bool isAvg;
  final String unit;
  final double? yMax;

  @override
  Widget build(BuildContext context) {
    final yField = getChartValueField(statistics, valueKey);
    final options = buildChartOptions(statistics: statistics, chartType: chartType, yField: yField, yMax: yMax);
    final summary = getSummaryValue(
      chartType: chartType,
      statistics: statistics,
      yField: yField,
      isAvg: isAvg,
      unit: unit,
    );
    final showTokenSummary = chartType.showTokens && hasNonZeroChartData(statistics, 'total_price');
    final zero = !hasNonZeroChartData(statistics, yField);
    final tertiary = difyTextStyle(DifyType.systemSmMedium, DifyColors.textTertiary);
    return Container(
      height: 316,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelOnPanelItemBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
      ),
      // border-box `h-79`: the 0.5 px border leaves 315 px for 316 px of rows; `overflow-hidden` clips the last pixel
      // of the chart's bottom padding.
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 316,
        maxHeight: 316,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // `flex h-11 items-center px-6 pt-6 pb-1`
            Container(
              height: 44,
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 4),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Flexible(
                    child: Semantics(
                      label: title,
                      tooltip: title,
                      excludeSemantics: true,
                      child: DifyTextLine(
                        difyTransform(DifyType.systemSmSemiboldUppercase, title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyType.systemSmSemiboldUppercase, DifyColors.textSecondary),
                      ),
                    ),
                  ),
                  if (explanation.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    DifyInfotip(
                      label: explanation,
                      width: 240,
                      content: DifyTextLine(
                        explanation,
                        style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // `flex h-8 items-baseline gap-1 px-6 py-1`
            SizedBox(
              height: 32,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  spacing: 4,
                  children: [
                    DifyTextLine(
                      summary,
                      key: const ValueKey('chart-summary'),
                      maxLines: 1,
                      style: difyTextStyle(
                        DifyType.title3xlSemiBold,
                        zero ? DifyColors.textQuaternary : DifyColors.textPrimary,
                      ),
                    ),
                    if (showTokenSummary)
                      Flexible(
                        child: DifyTextLine.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: '${DifyI18n.tr('appOverview', 'analysis.tokenUsage.consumed')} Tokens '),
                              const TextSpan(text: '('),
                              TextSpan(
                                text: '~${getTokenSummary(statistics)}',
                                style: TextStyle(color: DifyTailwind.orange400),
                              ),
                              const TextSpan(text: ')'),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tertiary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // `h-60 shrink-0 px-6 pb-4`
            SizedBox(
              height: 240,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: AppChartCanvas(options: options),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One `createBizChartComponent` config.
class BizChartConfig {
  const BizChartConfig({
    required this.statistic,
    required this.chartType,
    required this.titleKey,
    required this.explanationKey,
    required this.yMaxWhenEmpty,
    this.isAvg = false,
    this.unitKey,
  });

  final AppStatistic statistic;
  final ChartType chartType;
  final String titleKey, explanationKey;
  final double yMaxWhenEmpty;
  final bool isAvg;
  final String? unitKey;

  /// `valueKey` and `emptyValueKey` (always the same in Dify's configs).
  String get valueKey => statistic.valueKey;
}

/// The configs of app-chart.tsx's exported charts.
abstract final class BizCharts {
  static const messages = BizChartConfig(
    statistic: AppStatistic.dailyMessages,
    chartType: ChartType.messages,
    titleKey: 'analysis.totalMessages.title',
    explanationKey: 'analysis.totalMessages.explanation',
    yMaxWhenEmpty: 500,
  );
  static const conversations = BizChartConfig(
    statistic: AppStatistic.dailyConversations,
    chartType: ChartType.conversations,
    titleKey: 'analysis.totalConversations.title',
    explanationKey: 'analysis.totalConversations.explanation',
    yMaxWhenEmpty: 500,
  );
  static const endUsers = BizChartConfig(
    statistic: AppStatistic.dailyEndUsers,
    chartType: ChartType.endUsers,
    titleKey: 'analysis.activeUsers.title',
    explanationKey: 'analysis.activeUsers.explanation',
    yMaxWhenEmpty: 500,
  );
  static const avgSessionInteractions = BizChartConfig(
    statistic: AppStatistic.averageSessionInteractions,
    chartType: ChartType.conversations,
    titleKey: 'analysis.avgSessionInteractions.title',
    explanationKey: 'analysis.avgSessionInteractions.explanation',
    yMaxWhenEmpty: 500,
    isAvg: true,
  );
  static const avgResponseTime = BizChartConfig(
    statistic: AppStatistic.averageResponseTime,
    chartType: ChartType.conversations,
    titleKey: 'analysis.avgResponseTime.title',
    explanationKey: 'analysis.avgResponseTime.explanation',
    yMaxWhenEmpty: 500,
    isAvg: true,
    unitKey: 'analysis.ms',
  );
  static const tokenPerSecond = BizChartConfig(
    statistic: AppStatistic.tokensPerSecond,
    chartType: ChartType.conversations,
    titleKey: 'analysis.tps.title',
    explanationKey: 'analysis.tps.explanation',
    yMaxWhenEmpty: 100,
    isAvg: true,
    unitKey: 'analysis.tokenPS',
  );
  static const userSatisfactionRate = BizChartConfig(
    statistic: AppStatistic.userSatisfactionRate,
    chartType: ChartType.endUsers,
    titleKey: 'analysis.userSatisfactionRate.title',
    explanationKey: 'analysis.userSatisfactionRate.explanation',
    yMaxWhenEmpty: 1000,
    isAvg: true,
  );
  static const cost = BizChartConfig(
    statistic: AppStatistic.tokenCosts,
    chartType: ChartType.costs,
    titleKey: 'analysis.tokenUsage.title',
    explanationKey: 'analysis.tokenUsage.explanation',
    yMaxWhenEmpty: 100,
  );
  static const workflowMessages = BizChartConfig(
    statistic: AppStatistic.workflowDailyRuns,
    chartType: ChartType.conversations,
    titleKey: 'analysis.totalMessages.title',
    explanationKey: 'analysis.totalMessages.explanation',
    yMaxWhenEmpty: 500,
  );
  static const workflowDailyTerminals = BizChartConfig(
    statistic: AppStatistic.workflowDailyTerminals,
    chartType: ChartType.endUsers,
    titleKey: 'analysis.activeUsers.title',
    explanationKey: 'analysis.activeUsers.explanation',
    yMaxWhenEmpty: 500,
  );
  static const workflowCost = BizChartConfig(
    statistic: AppStatistic.workflowTokenCosts,
    chartType: ChartType.workflowCosts,
    titleKey: 'analysis.tokenUsage.title',
    explanationKey: 'analysis.tokenUsage.explanation',
    yMaxWhenEmpty: 100,
  );
  static const avgUserInteractions = BizChartConfig(
    statistic: AppStatistic.workflowAverageInteractions,
    chartType: ChartType.conversations,
    titleKey: 'analysis.avgUserInteractions.title',
    explanationKey: 'analysis.avgUserInteractions.explanation',
    yMaxWhenEmpty: 500,
    isAvg: true,
  );
}

/// A `createBizChartComponent` chart: fetches [config]'s series for [period] (again when the period changes),
/// shows base/loading until it arrives, and Dify's fallback rows (with the fixed empty maximum) when it is empty.
/// No [source]: an empty answer at once.
class BizChart extends StatefulWidget {
  const BizChart({super.key, required this.config, required this.appId, required this.period, this.source, this.now});

  final BizChartConfig config;
  final String appId;
  final PeriodParams period;

  /// The statistics API (protocol 1.11); null: every chart is empty.
  final StatsApi? source;

  /// The clock of `defaultPeriod` (all time); the system clock when null.
  final DateTime Function()? now;

  @override
  State<BizChart> createState() => _BizChartState();
}

class _BizChartState extends State<BizChart> {
  List<ChartRow>? _rows;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BizChart old) {
    super.didUpdateWidget(old);
    if (old.period.query != widget.period.query ||
        old.appId != widget.appId ||
        old.source != widget.source ||
        old.config != widget.config) {
      _load();
    }
  }

  void _load() {
    final n = ++_request;
    final source = widget.source;
    if (source == null) {
      _rows = const [];
      return;
    }
    // react-query keeps the previous answer while the next period loads only when it is cached; a new key loads.
    _rows = null;
    final q = widget.period.query;
    unawaited(
      source
          .statistic(widget.appId, widget.config.statistic, start: q?.start, end: q?.end)
          .then(
            (rows) {
              if (mounted && n == _request) setState(() => _rows = [for (final r in rows) r.json]);
            },
            onError: (Object _) {
              // useQuery's error leaves no data: base/loading stays, as in Dify.
            },
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) return const DifyLoading();
    final c = widget.config;
    final noData = rows.isEmpty;
    final period = widget.period.query ?? defaultChartPeriod(widget.now?.call());
    return AppChart(
      title: DifyI18n.tr('appOverview', c.titleKey),
      explanation: DifyI18n.tr('appOverview', c.explanationKey),
      timePeriod: widget.period.name,
      chartType: c.chartType,
      statistics: noData ? getDefaultChartData(start: period.start, end: period.end, key: c.valueKey) : rows,
      valueKey: c.valueKey,
      isAvg: c.isAvg,
      unit: c.unitKey == null ? '' : DifyI18n.tr('appOverview', c.unitKey!),
      yMax: noData ? c.yMaxWhenEmpty : null,
    );
  }
}
