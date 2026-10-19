/// The workflow app's logs, Dify 1.17.1 `app/components/app/workflow-log/*`: the page (index.tsx: title, filter,
/// list or empty state, pagination), the filter (status, period, keyword), the list (unread mark, start time sorted
/// either way, status, run time, tokens, user, trigger) and the run detail drawer (the workflow RunPanel: Result /
/// Detail / Tracing, and "Test With Params" for replayable runs).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppInfo, AppModes;
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show SvgPicture;

import '../../cards/card_chrome.dart' show BlockIcon;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../auth/account_time.dart';
import '../../workflow_editor/run/ui/run_panel.dart';
import '../../workflow_editor/store/workflow_store_scope.dart';
import 'log_widgets.dart';
import 'logs_data.dart';

String _l(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app-log', key, params);
String _c(String key) => DifyI18n.tr('common', key);

/// The filter's state (`QueryParam`): `period` (a [timePeriodMapping] key), `status`, `keyword`.
@immutable
class WorkflowLogFilterQuery {
  const WorkflowLogFilterQuery({required this.period, this.status, this.keyword});

  final String period;
  final String? status, keyword;

  WorkflowLogFilterQuery copyWith({String? period, String? status, String? keyword}) => WorkflowLogFilterQuery(
    period: period ?? this.period,
    status: status ?? this.status,
    keyword: keyword ?? this.keyword,
  );

  @override
  bool operator ==(Object other) =>
      other is WorkflowLogFilterQuery && other.period == period && other.status == status && other.keyword == keyword;

  @override
  int get hashCode => Object.hash(period, status, keyword);

  @override
  String toString() => 'WorkflowLogFilterQuery(status: $status, period: $period, keyword: $keyword)';
}

/// The status filter's items (Dify's hard-coded English names).
const workflowLogStatusItems = <ChipItem>[
  (value: 'all', name: 'All'),
  (value: 'succeeded', name: 'Success'),
  (value: 'failed', name: 'Fail'),
  (value: 'stopped', name: 'Stop'),
  (value: 'partial-succeeded', name: 'Partial Success'),
];

/// The period chip's items: every [timePeriodMapping] entry with its `appLog.filter.period.*` name.
List<ChipItem> logPeriodItems([DateTime? today]) => [
  for (final e in timePeriodMapping(today).entries) (value: e.key, name: _l('filter.period.${e.value.name}')),
];

/// workflow-log/filter.tsx: status, period (cleared: all time) and keyword.
class WorkflowLogFilter extends StatelessWidget {
  const WorkflowLogFilter({super.key, required this.queryParams, required this.setQueryParams});

  final WorkflowLogFilterQuery queryParams;
  final ValueChanged<WorkflowLogFilterQuery> setQueryParams;

  @override
  Widget build(BuildContext context) {
    final q = queryParams;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          DifyChip(
            key: const ValueKey('workflow-log-status'),
            value: q.status ?? 'all',
            items: workflowLogStatusItems,
            onSelect: (item) => setQueryParams(q.copyWith(status: item.value)),
            onClear: () => setQueryParams(q.copyWith(status: 'all')),
          ),
          DifyChip(
            key: const ValueKey('workflow-log-period'),
            minWidth: 150,
            panelWidth: 270,
            leftIcon: RemixIcon('calendar-line', size: 16, color: DifyColors.textSecondary),
            value: q.period,
            items: logPeriodItems(),
            onSelect: (item) => setQueryParams(q.copyWith(period: item.value)),
            onClear: () => setQueryParams(q.copyWith(period: '9')),
          ),
          DifySearchInput(
            key: const ValueKey('workflow-log-keyword'),
            width: 200,
            value: q.keyword ?? '',
            placeholder: _c('operation.search'),
            onValueChange: (v) =>
                setQueryParams(WorkflowLogFilterQuery(period: q.period, status: q.status, keyword: v)),
          ),
        ],
      ),
    );
  }
}

/// The request's query (index.tsx `query`): page, `detail`, limit, the status unless "all", the keyword, and the
/// period's `created_at__after` / `created_at__before` (in local time) unless it is "all time".
Map<String, Object?> workflowLogsRequestParams(
  WorkflowLogFilterQuery q, {
  required int page,
  required int limit,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  final period = timePeriodMapping(t)[q.period] ?? timePeriodMapping(t)['2']!;
  return {
    'page': page + 1,
    'detail': true,
    'limit': limit,
    if (q.status != null && q.status != 'all') 'status': q.status,
    if (q.period != '9') ...{
      'created_at__after': formatDayjsIso(periodStart(period.value, t)),
      'created_at__before': formatDayjsIso(periodEnd(t)),
    },
    if (q.keyword != null) 'keyword': q.keyword,
  };
}

/// workflow-log/index.tsx: the workflow app's logs page.
class WorkflowLogs extends StatefulWidget {
  const WorkflowLogs({
    super.key,
    required this.app,
    required this.source,
    this.onReplay,
    this.onShare,
    this.onTest,
    this.testPath,
    this.debounce = const Duration(milliseconds: 500),
    this.runBuilder,
    this.now,
  });

  final AppInfo app;
  final AppLogsSource source;

  /// "Test With Params": opens the editor on the run (Dify's `/app/{id}/workflow?replayRunId=`).
  final ValueChanged<String>? onReplay;

  /// The empty state's links (see [LogEmptyElement]).
  final VoidCallback? onShare, onTest;
  final String? testPath;

  /// The request's debounce (ahooks `useDebounce`, 500 ms).
  final Duration debounce;

  /// Builds the drawer's run view from its URLs (tests replace Dify's `Run` this way).
  final WorkflowRunViewBuilder? runBuilder;

  /// The clock for the period's dates (tests).
  final DateTime Function()? now;

  @override
  State<WorkflowLogs> createState() => WorkflowLogsState();
}

class WorkflowLogsState extends State<WorkflowLogs> {
  var _query = const WorkflowLogFilterQuery(status: 'all', period: '2');
  late var _requestQuery = _query;
  var _page = 0, _limit = appPageLimit, _seq = 0;
  Json? _logs;
  Timer? _debounce;

  /// The last request's query (tests).
  Map<String, Object?>? lastParams;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(WorkflowLogs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.app.id != widget.app.id || old.source != widget.source) _fetch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final seq = ++_seq;
    final params = workflowLogsRequestParams(
      _requestQuery,
      page: _page,
      limit: _limit,
      now: widget.now?.call(),
    );
    lastParams = params;
    try {
      final logs = await widget.source.workflowLogs(widget.app.id, params);
      if (mounted && seq == _seq) setState(() => _logs = logs);
    } on Object {
      // Dify keeps showing the loading state when the query fails.
    }
  }

  void _setQuery(WorkflowLogFilterQuery q) {
    setState(() => _query = q);
    _debounce?.cancel();
    if (widget.debounce == Duration.zero) {
      _requestQuery = q;
      _fetch();
    } else {
      _debounce = Timer(widget.debounce, () {
        _requestQuery = q;
        _fetch();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = (_logs?['total'] as num?)?.toInt();
    final totalPages = total != null && total > 0 ? (total / _limit).ceil().clamp(1, 1 << 30) : 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LogPageTitle(title: _l('workflowTitle'), description: _l('workflowSubtitle')),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WorkflowLogFilter(queryParams: _query, setQueryParams: _setQuery),
                Expanded(
                  child: total == null
                      ? const LogLoading()
                      : total > 0
                      ? SingleChildScrollView(
                          child: WorkflowAppLogList(
                            logs: _logs,
                            app: widget.app,
                            source: widget.source,
                            onRefresh: _fetch,
                            onReplay: widget.onReplay,
                            runBuilder: widget.runBuilder,
                          ),
                        )
                      : LogEmptyElement(
                          shareUrl: LogEmptyElement.shareUrlOf(appSite(widget.app), widget.app.mode),
                          testPath: widget.testPath ?? '/app/${widget.app.id}/workflow',
                          onShare: widget.onShare,
                          onTest: widget.onTest,
                        ),
                ),
                if (total != null && total > appPageLimit)
                  DifyPagination(
                    page: _page + 1,
                    totalPages: totalPages,
                    onPageChange: (p) {
                      setState(() => _page = p - 1);
                      _fetch();
                    },
                    pageSize: _limit,
                    onPageSizeChange: (v) {
                      setState(() => _limit = v);
                      _fetch();
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Builds the run view of the drawer from Dify's `runDetailUrl` and `tracingListUrl` (`''` without a run).
typedef WorkflowRunViewBuilder = Widget Function(BuildContext context, String runDetailUrl, String tracingListUrl);

/// workflow-log/list.tsx: the logs' table and the run detail drawer.
class WorkflowAppLogList extends StatefulWidget {
  const WorkflowAppLogList({
    super.key,
    required this.logs,
    required this.app,
    required this.onRefresh,
    this.source = const EmptyAppLogsSource(),
    this.onReplay,
    this.runBuilder,
  });

  /// `WorkflowLogsResponse`; null: loading.
  final Json? logs;

  /// Null: loading (Dify's missing `appDetail`).
  final AppInfo? app;
  final VoidCallback onRefresh;
  final AppLogsSource source;
  final ValueChanged<String>? onReplay;
  final WorkflowRunViewBuilder? runBuilder;

  @override
  State<WorkflowAppLogList> createState() => _WorkflowAppLogListState();
}

class _WorkflowAppLogListState extends State<WorkflowAppLogList> {
  bool _asc = false;
  String? _current;
  final _triggers = <String, FocusNode>{};

  @override
  void dispose() {
    for (final f in _triggers.values) {
      f.dispose();
    }
    super.dispose();
  }

  List<Json> get _sorted {
    final data = [for (final l in (widget.logs?['data'] as List? ?? const [])) l as Json];
    data.sort((a, b) {
      final r = ((a['created_at'] as num?) ?? 0).compareTo((b['created_at'] as num?) ?? 0);
      return _asc ? r : -r;
    });
    return data;
  }

  Future<void> _open(Json log) async {
    final id = '${log['id']}';
    setState(() => _current = id);
    final run = (log['workflow_run'] as Json?) ?? const {};
    final from = run['triggered_from'];
    await showLogDrawer(
      context,
      builder: (context, close) => WorkflowLogDetailPanel(
        runID: '${run['id'] ?? ''}',
        appId: widget.app?.id,
        source: widget.source,
        onClose: close,
        canReplay: from == 'app-run' || from == 'debugging',
        onReplay: widget.onReplay,
        runBuilder: widget.runBuilder,
      ),
    );
    if (!mounted) return;
    widget.onRefresh();
    setState(() => _current = null);
    _triggers[id]?.requestFocus();
  }

  Widget _status(String? status) => switch (status) {
    'succeeded' => LogStatusLabel(
      dot: StatusDotKind.success,
      text: 'Success',
      color: DifyColors.utilColorsGreenGreen600,
    ),
    'failed' => LogStatusLabel(dot: StatusDotKind.error, text: 'Failure', color: DifyColors.utilColorsRedRed600),
    'stopped' => LogStatusLabel(
      dot: StatusDotKind.warning,
      text: 'Stop',
      color: DifyColors.utilColorsWarningWarning600,
    ),
    'paused' => LogStatusLabel(
      dot: StatusDotKind.warning,
      text: 'Pending',
      color: DifyColors.utilColorsWarningWarning600,
    ),
    'running' => LogStatusLabel(
      dot: StatusDotKind.normal,
      text: 'Running',
      color: DifyColors.utilColorsBlueLightBlueLight600,
    ),
    'partial-succeeded' => LogStatusLabel(
      dot: StatusDotKind.success,
      text: 'Partial Success',
      color: DifyColors.utilColorsGreenGreen600,
    ),
    _ => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (widget.logs == null || app == null) return const LogLoading();
    final isWorkflow = app.mode == AppModes.workflow;
    final columns = <LogColumn>[
      (header: null, width: 20),
      (
        header: DifyPressable(
          key: const ValueKey('workflow-log-sort'),
          semanticLabel: _l('table.header.startTime'),
          onPressed: () => setState(() => _asc = !_asc),
          builder: (context, hovered, focused) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.startTime')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: hovered ? DifyColors.textSecondary : null),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: RotatedBox(
                  key: ValueKey(_asc ? 'workflow-log-sort-asc' : 'workflow-log-sort-desc'),
                  quarterTurns: _asc ? 2 : 0,
                  child: SvgPicture.string(
                    _arrowDownSvg,
                    width: 12,
                    height: 12,
                    colorFilter: ColorFilter.mode(DifyColors.textTertiary, BlendMode.srcIn),
                  ),
                ),
              ),
            ],
          ),
        ),
        width: 180,
      ),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.status'))), width: null),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.runtime'))), width: null),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.tokens'))), width: null),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.user'))), width: null),
      if (isWorkflow)
        (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.triggered_from'))), width: null),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LogTable(
        columns: columns,
        rows: [
          for (final log in _sorted) _row(log, columns, isWorkflow),
        ],
      ),
    );
  }

  LogTableRow _row(Json log, List<LogColumn> columns, bool isWorkflow) {
    final run = (log['workflow_run'] as Json?) ?? const {};
    final endUser = switch ((log['created_by_end_user'], log['created_by_account'])) {
      (final Json u, _) => '${u['session_id']}',
      (_, final Json a) => '${a['name']}',
      _ => 'N/A',
    };
    final id = '${log['id']}';
    final elapsed = ((run['elapsed_time'] as num?) ?? 0).toDouble();
    final trigger = _triggers.putIfAbsent(id, () => FocusNode(debugLabel: 'log $id'));
    return LogTableRow(
      key: ValueKey('workflow-log-row-$id'),
      columns: columns,
      selected: _current == id,
      onTap: () => _open(log),
      cells: [
        log['read_at'] == null ? const LogUnreadDot() : const SizedBox(height: 16),
        logCell(
          LogDrawerTrigger(
            focusNode: trigger,
            text: AccountTime.of(context).formatTime(((log['created_at'] as num?) ?? 0).toInt(), _l('dateTimeFormat')),
            onPressed: () => _open(log),
          ),
        ),
        logCell(_status(run['status'] as String?)),
        logCell(
          Text(
            '${elapsed.toStringAsFixed(3)}s',
            style: elapsed == 0 ? TextStyle(color: DifyColors.textQuaternary) : null,
          ),
        ),
        logCell(Text('${run['total_tokens'] ?? 0}')),
        logCell(
          Text(
            endUser,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: endUser == 'N/A' ? DifyColors.textQuaternary : DifyColors.textSecondary),
          ),
        ),
        if (isWorkflow)
          logCell(
            TriggerByDisplay(
              triggeredFrom: '${run['triggered_from'] ?? ''}',
              triggerMetadata: (log['details'] as Json?)?['trigger_metadata'] as Json?,
            ),
          ),
      ],
    );
  }
}

/// Heroicons `arrow-down` (24 outline, `stroke-2`).
const _arrowDownSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor">'
    '<path stroke-linecap="round" stroke-linejoin="round" d="M19.5 13.5 12 21m0 0-7.5-7.5M12 21V3"/></svg>';

/// workflow-log/detail.tsx: "Log Detail", "Test With Params" ([canReplay]), the close button, and the run
/// (Dify's `Run`: our [RunPanel] on `/apps/{appId}/workflow-runs/{runID}` and its `/node-executions`) in its own
/// workflow store (`WorkflowContextProvider`).
class WorkflowLogDetailPanel extends StatelessWidget {
  const WorkflowLogDetailPanel({
    super.key,
    required this.runID,
    required this.onClose,
    this.appId,
    this.canReplay = false,
    this.onReplay,
    this.source = const EmptyAppLogsSource(),
    this.runBuilder,
  });

  final String runID;
  final VoidCallback onClose;

  /// The open app (Dify's `appDetail` from the app store); null: none.
  final String? appId;
  final bool canReplay;
  final ValueChanged<String>? onReplay;
  final AppLogsSource source;
  final WorkflowRunViewBuilder? runBuilder;

  String get runDetailUrl => runID.isNotEmpty ? '/apps/$appId/workflow-runs/$runID' : '';
  String get tracingListUrl => runID.isNotEmpty ? '/apps/$appId/workflow-runs/$runID/node-executions' : '';

  @override
  Widget build(BuildContext context) {
    final id = appId;
    return Stack(
      key: const ValueKey('workflow-log-detail'),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                key: const ValueKey('workflow-log-detail-header'),
                color: DifyColors.componentsPanelBg,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Semantics(
                        header: true,
                        child: Text(
                          _l('runDetail.workflowTitle'),
                          style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
                        ),
                      ),
                    ),
                    if (canReplay)
                      DifyTooltip(
                        content: Text(_l('runDetail.testWithParams')),
                        child: DifyPressable(
                          key: const ValueKey('workflow-log-replay'),
                          semanticLabel: _l('runDetail.testWithParams'),
                          onPressed: () {
                            if (id == null || id.isEmpty) return;
                            onReplay?.call(runID);
                          },
                          builder: (context, hovered, focused) => Container(
                            width: 24,
                            height: 24,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              color: hovered ? DifyColors.stateBaseHover : null,
                              borderRadius: BorderRadius.circular(DifyRadius.md),
                            ),
                            child: Center(
                              child: RemixIcon('play-large-line', size: 16, color: DifyColors.textTertiary),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: WorkflowStoreProvider(
                  child: Builder(
                    builder: (context) =>
                        runBuilder?.call(context, runDetailUrl, tracingListUrl) ??
                        RunPanel(
                          key: ValueKey('workflow-log-run-$runID'),
                          runId: runID,
                          fetchRunDetail: id == null || runID.isEmpty ? null : (r) => source.workflowRun(id, r),
                          fetchTracingList: id == null || runID.isEmpty ? null : (r) => source.nodeExecutions(id, r),
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 16,
          right: 12,
          child: DifyPressable(
            key: const ValueKey('workflow-log-detail-close'),
            semanticLabel: _c('operation.close'),
            onPressed: onClose,
            builder: (context, hovered, focused) => Padding(
              padding: const EdgeInsets.all(4),
              child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
            ),
          ),
        ),
      ],
    );
  }
}

/// workflow-log/trigger-by-display.tsx: the trigger's icon tile and name (a plugin's event name when it has one).
class TriggerByDisplay extends StatelessWidget {
  const TriggerByDisplay({super.key, required this.triggeredFrom, this.showText = true, this.triggerMetadata});

  /// `WorkflowRunTriggeredFrom`.
  final String triggeredFrom;
  final bool showText;
  final Json? triggerMetadata;

  /// `getTriggerDisplayName`.
  static String displayName(String triggeredFrom, Json? metadata) {
    if (triggeredFrom == 'plugin' && metadata?['event_name'] is String) return metadata!['event_name']! as String;
    return switch (triggeredFrom) {
      'debugging' => _l('triggerBy.debugging'),
      'app-run' => _l('triggerBy.appRun'),
      'webhook' => _l('triggerBy.webhook'),
      'schedule' => _l('triggerBy.schedule'),
      'plugin' => _l('triggerBy.plugin'),
      'rag-pipeline-run' => _l('triggerBy.ragPipelineRun'),
      'rag-pipeline-debugging' => _l('triggerBy.ragPipelineDebugging'),
      _ => triggeredFrom,
    };
  }

  static Widget _tile(Color color, String icon) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
      boxShadow: DifyShadows.md,
    ),
    child: DifyIcon('vender/workflow/$icon', size: 16, color: DifyColors.textPrimaryOnSurface),
  );

  Widget _icon() {
    switch (triggeredFrom) {
      case 'webhook':
        return _tile(DifyColors.utilColorsBlueBlue500, 'webhook-line');
      case 'schedule':
        return _tile(DifyColors.utilColorsVioletViolet500, 'schedule');
      case 'plugin':
        final m = triggerMetadata;
        final icon = m == null
            ? null
            : DifyColors.isDark
            ? (m['icon_dark'] ?? m['icon']) as String?
            : (m['icon'] ?? m['icon_dark']) as String?;
        if (icon == null || icon.isEmpty) {
          return Semantics(
            image: true,
            label: 'Default plugin trigger icon',
            child: const BlockIcon(type: 'trigger-plugin'),
          );
        }
        return Semantics(
          image: true,
          label: 'Plugin trigger icon',
          value: icon,
          child: Container(
            key: ValueKey('trigger-plugin-icon-$icon'),
            width: 24,
            height: 24,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(DifyRadius.lg)),
            child: Image.network(icon, errorBuilder: (_, _, _) => const BlockIcon(type: 'trigger-plugin')),
          ),
        );
      case 'debugging':
        return _tile(DifyColors.utilColorsBlueBlue500, 'code');
      case 'rag-pipeline-run' || 'rag-pipeline-debugging':
        return _tile(DifyColors.utilColorsGreenGreen500, 'knowledge-retrieval');
      default:
        return _tile(DifyColors.utilColorsBlueBrandBlueBrand500, 'window-cursor');
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 6,
    children: [
      _icon(),
      if (showText)
        Flexible(
          child: Text(
            displayName(triggeredFrom, triggerMetadata),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
          ),
        ),
    ],
  );
}
