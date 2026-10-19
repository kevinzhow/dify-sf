/// The chatflow's logs, Dify 1.17.1 `app/components/app/log/*`: the page (index.tsx: title with "Learn more", filter,
/// list or empty state, pagination, the per-app state cache), the filter (period, annotation status with its count,
/// keyword, sort), the conversation list (title, end user, status, messages, user / admin rating, updated, created)
/// and the conversation drawer (`?conversation_id=`: id with copy, the variables, the transcript loaded 10 messages at
/// a time from the newest, admin feedback).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppInfo, AppModes;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show SvgPicture;

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../auth/account_time.dart';
import '../../workflow_editor/run/ui/chat.dart' show ChatAnswer, ChatContext, ChatQuestion;
import '../access/access_point_utils.dart' show difyDocLink;
import 'list_utils.dart';
import 'log_widgets.dart';
import 'logs_data.dart';
import 'workflow_log.dart' show logPeriodItems;

String _l(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app-log', key, params);
String _c(String key) => DifyI18n.tr('common', key);

/// The chat logs' filter state (`QueryParam`).
@immutable
class ChatLogQuery {
  const ChatLogQuery({required this.period, this.annotationStatus, this.keyword, this.sortBy});

  final String period;
  final String? annotationStatus, keyword, sortBy;

  /// index.tsx `defaultQueryParams`.
  static const initial = ChatLogQuery(period: '2', annotationStatus: 'all', sortBy: '-created_at');

  ChatLogQuery copyWith({String? period, String? annotationStatus, String? keyword, String? sortBy}) => ChatLogQuery(
    period: period ?? this.period,
    annotationStatus: annotationStatus ?? this.annotationStatus,
    keyword: keyword ?? this.keyword,
    sortBy: sortBy ?? this.sortBy,
  );

  @override
  bool operator ==(Object other) =>
      other is ChatLogQuery &&
      other.period == period &&
      other.annotationStatus == annotationStatus &&
      other.keyword == keyword &&
      other.sortBy == sortBy;

  @override
  int get hashCode => Object.hash(period, annotationStatus, keyword, sortBy);

  @override
  String toString() =>
      'ChatLogQuery(period: $period, annotation_status: $annotationStatus, keyword: $keyword, sort_by: $sortBy)';
}

/// log/filter.tsx: period (cleared: all time), annotation status (its "annotated" item shows the count), keyword and,
/// for chat apps, the sort. Nothing renders until the annotation count is known ([annotationCount] null).
class ChatLogFilter extends StatelessWidget {
  const ChatLogFilter({
    super.key,
    required this.queryParams,
    required this.setQueryParams,
    required this.annotationCount,
    this.isChatMode = false,
  });

  final ChatLogQuery queryParams;
  final ValueChanged<ChatLogQuery> setQueryParams;
  final int? annotationCount;
  final bool isChatMode;

  @override
  Widget build(BuildContext context) {
    final count = annotationCount;
    if (count == null) return const SizedBox.shrink();
    final q = queryParams;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          LogChip(
            key: const ValueKey('chat-log-period'),
            minWidth: 150,
            panelWidth: 270,
            leftIcon: RemixIcon('calendar-line', size: 16, color: DifyColors.textSecondary),
            value: q.period,
            items: logPeriodItems(),
            onSelect: (item) => setQueryParams(q.copyWith(period: item.value)),
            onClear: () => setQueryParams(q.copyWith(period: '9')),
          ),
          LogChip(
            key: const ValueKey('chat-log-annotation'),
            minWidth: 150,
            panelWidth: 270,
            showLeftIcon: false,
            value: q.annotationStatus ?? 'all',
            items: [
              (value: 'all', name: _l('filter.annotation.all')),
              (value: 'annotated', name: _l('filter.annotation.annotated', {'count': count})),
              (value: 'not_annotated', name: _l('filter.annotation.not_annotated')),
            ],
            onSelect: (item) => setQueryParams(q.copyWith(annotationStatus: item.value)),
            onClear: () => setQueryParams(q.copyWith(annotationStatus: 'all')),
          ),
          SearchInput(
            key: const ValueKey('chat-log-keyword'),
            width: 200,
            value: q.keyword ?? '',
            placeholder: _c('operation.search'),
            onValueChange: (v) => setQueryParams(q.copyWith(keyword: v)),
          ),
          if (isChatMode) ...[
            Container(width: 1, height: 14, color: DifyColors.dividerRegular),
            LogSort(
              key: const ValueKey('chat-log-sort'),
              order: (q.sortBy ?? '').startsWith('-') ? '-' : '',
              value: (q.sortBy ?? '').replaceFirst('-', '').isEmpty ? 'created_at' : q.sortBy!.replaceFirst('-', ''),
              items: [
                (value: 'created_at', name: _l('table.header.time')),
                (value: 'updated_at', name: _l('table.header.updatedTime')),
              ],
              onSelect: (v) => setQueryParams(q.copyWith(sortBy: v)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The request's query (index.tsx `query`): page, limit, the period's `start` / `end` (`YYYY-MM-DD HH:mm`) unless it
/// is "all time", `sort_by` for chat apps, the annotation status and the keyword.
Map<String, Object?> chatLogsRequestParams(
  ChatLogQuery q, {
  required int page,
  required int limit,
  bool isChatMode = true,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  final period = timePeriodMapping(t)[q.period] ?? timePeriodMapping(t)['2']!;
  return {
    'page': page + 1,
    'limit': limit,
    if (q.period != '9') ...{
      'start': formatDayjsMinute(periodStart(period.value, t)),
      'end': formatDayjsMinute(periodEnd(t)),
    },
    if (isChatMode && q.sortBy != null) 'sort_by': q.sortBy,
    if (q.annotationStatus != null) 'annotation_status': q.annotationStatus,
    if (q.keyword != null) 'keyword': q.keyword,
  };
}

/// index.tsx's `logsStateCache`: the filter, page and page size per app, kept while the app stays open.
final chatLogsStateCache = <String, ({ChatLogQuery query, int page, int limit})>{};

/// log/index.tsx: the chatflow's logs page.
class ChatLogs extends StatefulWidget {
  const ChatLogs({
    super.key,
    required this.app,
    required this.source,
    this.initialPage = 0,
    this.onPageChange,
    this.conversationId,
    this.onConversationIdChange,
    this.onShare,
    this.onTest,
    this.testPath,
    this.debounce = const Duration(milliseconds: 500),
    this.chatBuilder,
    this.now,
  });

  final AppInfo app;
  final AppLogsSource source;

  /// The page from the address (`?page=`, zero-based here).
  final int initialPage;

  /// Dify's `router.replace(?page=)`: the page shown, zero-based.
  final ValueChanged<int>? onPageChange;

  /// `?conversation_id=`: the conversation whose drawer is open.
  final String? conversationId;
  final ValueChanged<String?>? onConversationIdChange;
  final VoidCallback? onShare, onTest;
  final String? testPath;
  final Duration debounce;
  final LogChatBuilder? chatBuilder;
  final DateTime Function()? now;

  @override
  State<ChatLogs> createState() => ChatLogsState();
}

class ChatLogsState extends State<ChatLogs> {
  late final _cached = chatLogsStateCache[widget.app.id];
  late var _query = _cached?.query ?? ChatLogQuery.initial;
  late var _requestQuery = _query;
  late var _page = _cached?.page ?? widget.initialPage;
  late var _limit = _cached?.limit ?? appPageLimit;
  var _seq = 0;
  Json? _logs;
  int? _annotationCount;
  Timer? _debounce;

  /// The last request's query (tests).
  Map<String, Object?>? lastParams;

  bool get _isChatMode => widget.app.mode != AppModes.completion;

  @override
  void initState() {
    super.initState();
    _fetch();
    _fetchCount();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _remember() => chatLogsStateCache[widget.app.id] = (query: _query, page: _page, limit: _limit);

  Future<void> _fetchCount() async {
    try {
      final r = await widget.source.annotationsCount(widget.app.id);
      if (mounted) setState(() => _annotationCount = (r['count'] as num?)?.toInt());
    } on Object {
      // Dify's filter stays hidden without the count.
    }
  }

  Future<void> _fetch() async {
    final seq = ++_seq;
    final params = chatLogsRequestParams(
      _requestQuery,
      page: _page,
      limit: _limit,
      isChatMode: _isChatMode,
      now: widget.now?.call(),
    );
    lastParams = params;
    try {
      final logs = await widget.source.chatConversations(widget.app.id, params);
      if (mounted && seq == _seq) setState(() => _logs = logs);
    } on Object {
      // Dify keeps showing the loading state when the query fails.
    }
  }

  void _setQuery(ChatLogQuery q) {
    setState(() {
      _page = 0;
      _query = q;
    });
    _remember();
    _debounce?.cancel();
    void run() {
      _requestQuery = q;
      _fetch();
    }

    if (widget.debounce == Duration.zero) {
      run();
    } else {
      _debounce = Timer(widget.debounce, run);
    }
  }

  void _setPage(int page) {
    setState(() => _page = page);
    _remember();
    widget.onPageChange?.call(page);
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final total = (_logs?['total'] as num?)?.toInt();
    final totalPages = total != null && total > 0 ? (total / _limit).ceil().clamp(1, 1 << 30) : 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LogPageTitle(
          title: _l('title'),
          description: _l('description'),
          learnMoreHref: difyDocLink('/use-dify/monitor/logs'),
          learnMoreLabel: _c('operation.learnMore'),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChatLogFilter(
                  isChatMode: _isChatMode,
                  queryParams: _query,
                  setQueryParams: _setQuery,
                  annotationCount: _annotationCount,
                ),
                Expanded(
                  child: total == null
                      ? const LogLoading()
                      : total > 0
                      ? SingleChildScrollView(
                          child: ConversationList(
                            logs: _logs,
                            app: widget.app,
                            source: widget.source,
                            onRefresh: _fetch,
                            conversationId: widget.conversationId,
                            onConversationIdChange: widget.onConversationIdChange,
                            chatBuilder: widget.chatBuilder,
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
                  LogPagination(
                    page: _page + 1,
                    totalPages: totalPages,
                    onPageChange: (p) => _setPage(p - 1),
                    pageSize: _limit,
                    onPageSizeChange: (v) {
                      setState(() => _limit = v);
                      _remember();
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

/// What the drawer's chat gets (Dify's `Chat` props as the log uses them).
typedef LogChatProps = ({
  List<Json> chatList,
  Future<bool> Function(String messageId, Json feedback) onFeedback,
  void Function(String annotationId, String authorName, String query, String answer, int index) onAnnotationAdded,
  void Function(String query, String answer, int index) onAnnotationEdited,
  Future<bool> Function(int index) onAnnotationRemoved,
  ValueChanged<String> switchSibling,
  bool hideLogModal,
  bool showPromptLog,
});

/// Builds the drawer's chat (tests replace Dify's `Chat` this way).
typedef LogChatBuilder = Widget Function(BuildContext context, LogChatProps props);

/// Heroicons `hand-thumb-up` / `hand-thumb-down` (24 outline).
const _thumbUpSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">'
    '<path stroke-linecap="round" stroke-linejoin="round" d="M6.633 10.25c.806 0 1.533-.446 2.031-1.08a9.041 9.041 0 0 '
    '1 2.861-2.4c.723-.384 1.35-.956 1.653-1.715a4.498 4.498 0 0 0 .322-1.672V2.75a.75.75 0 0 1 .75-.75 2.25 2.25 0 0 1 '
    '2.25 2.25c0 1.152-.26 2.243-.723 3.218-.266.558.107 1.282.725 1.282m0 0h3.126c1.026 0 1.945.694 2.054 1.715.045.422'
    '.068.85.068 1.285a11.95 11.95 0 0 1-2.649 7.521c-.388.482-.987.729-1.605.729H13.48c-.483 0-.964-.078-1.423-.23l-3.114'
    '-1.04a4.501 4.501 0 0 0-1.423-.23H5.904m10.598-9.75H14.25M5.904 18.5c.083.205.173.405.27.602.197.4-.078.898-.523.898'
    'h-.908c-.889 0-1.713-.518-1.972-1.368a12 12 0 0 1-.521-3.507c0-1.553.295-3.036.831-4.398C3.387 9.953 4.167 9.5 5 9.5'
    'h1.053c.472 0 .745.556.5.96a8.958 8.958 0 0 0-1.302 4.665c0 1.194.232 2.333.654 3.375Z"/></svg>';
const _thumbDownSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">'
    '<path stroke-linecap="round" stroke-linejoin="round" d="M7.498 15.25H4.372c-1.026 0-1.945-.694-2.054-1.715a12.137 '
    '12.137 0 0 1-.068-1.285c0-2.848.992-5.464 2.649-7.521C5.287 4.247 5.886 4 6.504 4h4.016a4.5 4.5 0 0 1 1.423.23l3.114'
    ' 1.04a4.5 4.5 0 0 0 1.423.23h1.294M7.498 15.25c.618 0 .991.724.725 1.282A7.471 7.471 0 0 0 7.5 19.75 2.25 2.25 0 0 0'
    ' 9.75 22a.75.75 0 0 0 .75-.75v-.633c0-.573.11-1.14.322-1.672.304-.76.93-1.33 1.653-1.715a9.04 9.04 0 0 0 2.86-2.4c.'
    '498-.634 1.226-1.08 2.032-1.08h.384m-10.253 1.5H9.7m8.075-9.75c.01.05.027.1.05.148.593 1.2.925 2.55.925 3.977 0 1.487'
    '-.36 2.89-.999 4.125m.023-8.25c-.076-.365.183-.75.575-.75h.908c.889 0 1.713.518 1.972 1.368.339 1.11.521 2.287.521 '
    '3.507 0 1.553-.295 3.036-.831 4.398-.306.774-1.086 1.227-1.918 1.227h-1.053c-.472 0-.745-.556-.5-.96a8.95 8.95 0 0 0'
    ' .303-.54"/></svg>';

/// `HandThumbIconWithCount`: `inline-flex rounded-md p-1 text-xs mr-1`, primary for likes, red for dislikes.
class HandThumbIconWithCount extends StatelessWidget {
  const HandThumbIconWithCount({super.key, required this.count, required this.up});
  final int count;
  final bool up;

  @override
  Widget build(BuildContext context) {
    final fg = up ? DifyColors.utilColorsBlueBrandBlueBrand600 : DifyColors.utilColorsRedRed600;
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: up ? DifyColors.utilColorsBlueBrandBlueBrand50 : DifyColors.utilColorsRedRed50,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: SvgPicture.string(
              up ? _thumbUpSvg : _thumbDownSvg,
              width: 12,
              height: 12,
              colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
            ),
          ),
          if (count > 0)
            Text(
              '$count',
              style: TextStyle(fontSize: 12, height: 16 / 12, color: fg),
            ),
        ],
      ),
    );
  }
}

/// log/list.tsx `statusTdRender` (chatflows): Pending while a run is paused, Success, Partial Success, or the
/// failure count.
Widget? chatflowStatusCell(Map<String, Object?>? statusCount) {
  if (statusCount == null) return null;
  int n(String k) => (statusCount[k] as num?)?.toInt() ?? 0;
  if (n('paused') > 0) {
    return LogStatusLabel(dot: StatusDotKind.warning, text: 'Pending', color: DifyColors.utilColorsWarningWarning600);
  }
  if (n('partial_success') + n('failed') == 0) {
    return LogStatusLabel(dot: StatusDotKind.success, text: 'Success', color: DifyColors.utilColorsGreenGreen600);
  }
  if (n('failed') == 0) {
    return LogStatusLabel(
      dot: StatusDotKind.success,
      text: 'Partial Success',
      color: DifyColors.utilColorsGreenGreen600,
    );
  }
  final failed = n('failed');
  return LogStatusLabel(
    dot: StatusDotKind.error,
    text: '$failed ${failed > 1 ? 'Failures' : 'Failure'}',
    color: DifyColors.utilColorsRedRed600,
  );
}

/// log/list.tsx `ConversationList`.
class ConversationList extends StatefulWidget {
  const ConversationList({
    super.key,
    required this.logs,
    required this.app,
    required this.onRefresh,
    this.source = const EmptyAppLogsSource(),
    this.conversationId,
    this.onConversationIdChange,
    this.chatBuilder,
  });

  final Json? logs;
  final AppInfo app;
  final VoidCallback onRefresh;
  final AppLogsSource source;

  /// `?conversation_id=` when the list appears (opens its drawer).
  final String? conversationId;

  /// Dify's `setConversationIdInUrl` (push on open, null on close).
  final ValueChanged<String?>? onConversationIdChange;
  final LogChatBuilder? chatBuilder;

  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  String? _current;
  final _triggers = <String, FocusNode>{};

  bool get _isChatMode => widget.app.mode != AppModes.completion;
  bool get _isChatflow => widget.app.mode == AppModes.advancedChat;

  @override
  void initState() {
    super.initState();
    final id = widget.conversationId;
    if (id != null && id.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _open(id) : null);
  }

  @override
  void dispose() {
    for (final f in _triggers.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _open(String id) async {
    if (_current == id) return;
    setState(() => _current = id);
    widget.onConversationIdChange?.call(id);
    await showLogDrawer(
      context,
      maxWidth: 640,
      bottom: 16,
      bordered: false,
      builder: (context, close) => ConversationDetail(
        app: widget.app,
        conversationId: id,
        source: widget.source,
        onClose: close,
        chatBuilder: widget.chatBuilder,
      ),
    );
    if (!mounted) return;
    widget.onRefresh();
    setState(() => _current = null);
    widget.onConversationIdChange?.call(null);
    _triggers[id]?.requestFocus();
  }

  Widget _value(Object? value, bool empty, {bool highlight = false}) => Container(
    color: highlight ? DifyColors.utilColorsOrangeOrange100 : null,
    child: Text(
      _truthy(value) ? '$value' : '-',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: difyTextStyle(DifyType.systemSmRegular, empty ? DifyColors.textQuaternary : DifyColors.textSecondary),
    ),
  );

  static bool _truthy(Object? v) => v != null && v != '' && v != 0;

  Widget _rating(Map? stats) {
    final like = (stats?['like'] as num?)?.toInt() ?? 0, dislike = (stats?['dislike'] as num?)?.toInt() ?? 0;
    if (like == 0 && dislike == 0) return _value('N/A', true);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (like > 0) HandThumbIconWithCount(up: true, count: like),
        if (dislike > 0) HandThumbIconWithCount(up: false, count: dislike),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final logs = widget.logs;
    if (logs == null) return const LogLoading();
    final columns = <LogColumn>[
      (header: null, width: 20),
      (
        header: Text(
          difyTransform(
            DifyType.systemXsMediumUppercase,
            _l(_isChatMode ? 'table.header.summary' : 'table.header.input'),
          ),
        ),
        width: 160,
      ),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.endUser'))), width: null),
      if (_isChatflow)
        (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.status'))), width: 160),
      (
        header: Text(
          difyTransform(
            DifyType.systemXsMediumUppercase,
            _l(_isChatMode ? 'table.header.messageCount' : 'table.header.output'),
          ),
        ),
        width: null,
      ),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.userRate'))), width: null),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.adminRate'))), width: null),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.updatedTime'))), width: 160),
      (header: Text(difyTransform(DifyType.systemXsMediumUppercase, _l('table.header.time'))), width: 160),
    ];
    final format = _l('dateTimeFormat');
    final time = AccountTime.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LogTable(
        columns: columns,
        rows: [
          for (final log in (logs['data'] as List? ?? const []).cast<Json>())
            () {
              final id = '${log['id']}';
              final row = getConversationRowValues(
                isChatMode: _isChatMode,
                log: log,
                noChatLabel: _l('table.empty.noChat'),
                noOutputLabel: _l('table.empty.noOutput'),
              );
              final trigger = _triggers.putIfAbsent(id, () => FocusNode(debugLabel: 'conversation $id'));
              return LogTableRow(
                key: ValueKey('chat-log-row-$id'),
                columns: columns,
                selected: _current == id,
                onTap: () => _open(id),
                cells: [
                  log['read_at'] == null ? const LogUnreadDot() : const SizedBox(height: 16),
                  logCell(_value(row.leftValue, row.isLeftEmpty, highlight: _isChatMode && log['annotated'] == true)),
                  logCell(_value(row.endUser ?? 'N/A', row.endUser == null)),
                  if (_isChatflow) logCell(chatflowStatusCell(log['status_count'] as Json?) ?? const SizedBox.shrink()),
                  logCell(_value(row.rightValue, row.isRightEmpty)),
                  logCell(_rating(log['user_feedback_stats'] as Map?)),
                  logCell(_rating(log['admin_feedback_stats'] as Map?)),
                  logCell(Text(time.formatTime(((log['updated_at'] as num?) ?? 0).toInt(), format))),
                  logCell(
                    LogDrawerTrigger(
                      focusNode: trigger,
                      text: time.formatTime(((log['created_at'] as num?) ?? 0).toInt(), format),
                      onPressed: () => _open(id),
                    ),
                  ),
                ],
              );
            }(),
        ],
      ),
    );
  }
}

/// `ChatConversationDetailComp`: loads the conversation (`/chat-conversations/{id}`), then its [ConversationDetailPanel].
class ConversationDetail extends StatefulWidget {
  const ConversationDetail({
    super.key,
    required this.app,
    required this.conversationId,
    required this.onClose,
    this.source = const EmptyAppLogsSource(),
    this.chatBuilder,
  });

  final AppInfo app;
  final String conversationId;
  final VoidCallback onClose;
  final AppLogsSource source;
  final LogChatBuilder? chatBuilder;

  @override
  State<ConversationDetail> createState() => _ConversationDetailState();
}

class _ConversationDetailState extends State<ConversationDetail> {
  Json? _detail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.chatConversation(widget.app.id, widget.conversationId);
      if (mounted) setState(() => _detail = d);
    } on Object {
      // Nothing to show (Dify renders nothing until the detail arrives).
    }
  }

  Future<bool> _feedback(String messageId, Json feedback) async {
    try {
      await widget.source.updateFeedback(widget.app.id, {
        'message_id': messageId,
        'rating': feedback['rating'],
        'content': ?feedback['content'],
      });
      toast.success(_c('actionMsg.modifiedSuccessfully'));
      return true;
    } on Object {
      toast.error(_c('actionMsg.modifiedUnsuccessfully'));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    return ConversationDetailPanel(
      app: widget.app,
      detail: d,
      source: widget.source,
      onClose: widget.onClose,
      onFeedback: _feedback,
      chatBuilder: widget.chatBuilder,
    );
  }
}

/// log/list.tsx `DetailPanel` for chat apps: the header (conversation id with copy, close), the variables, and the
/// transcript (newest first, older pages of 10 loaded near the top with "loading...").
class ConversationDetailPanel extends StatefulWidget {
  const ConversationDetailPanel({
    super.key,
    required this.app,
    required this.detail,
    required this.onClose,
    required this.onFeedback,
    this.source = const EmptyAppLogsSource(),
    this.chatBuilder,
  });

  final AppInfo app;
  final Json detail;
  final VoidCallback onClose;
  final Future<bool> Function(String messageId, Json feedback) onFeedback;
  final AppLogsSource source;
  final LogChatBuilder? chatBuilder;

  @override
  State<ConversationDetailPanel> createState() => ConversationDetailPanelState();
}

class ConversationDetailPanelState extends State<ConversationDetailPanel> {
  static const minItemsForScrollLoading = 8, maxRetryCount = 3;

  bool _hasMore = true, _loading = false;
  Map<String, Object?> _varValues = const {};
  List<Json> _all = const [], _tree = const [], _thread = const [];
  String? _oldestAnswerId;
  int _retry = 0;
  final _scroll = ScrollController();

  /// The `chat-messages` requests made, in order (tests).
  final requests = <Map<String, Object?>>[];

  String get _id => '${widget.detail['id']}';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _fetch(initial: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool initial = false}) async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final params = <String, Object?>{'conversation_id': _id, 'limit': 10, 'first_id': ?_oldestAnswerId};
    requests.add(params);
    try {
      final res = await widget.source.chatMessages(widget.app.id, params);
      if (!mounted) return;
      final data = [for (final m in (res['data'] as List? ?? const [])) (m as Map).cast<String, Object?>()];
      if (!initial && data.isEmpty) {
        setState(() {
          _hasMore = false;
          _retry = 0;
        });
        return;
      }
      final next = getFormattedChatList(
        data,
        _id,
        _l('dateTimeFormat'),
        timeFormatter: AccountTime.read(context).formatTime,
      );
      setState(() {
        if (data.isNotEmpty) _varValues = (data.last['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
        _hasMore = res['has_more'] == true;
        if (initial) {
          _all = mergeUniqueChatItems(_all, next);
        } else {
          final merged = mergePaginatedChatItems(
            maxRetryCount: maxRetryCount,
            newItems: next,
            prevItems: _all,
            retryCount: _retry,
          );
          _retry = merged.retryCount;
          _all = merged.items;
        }
        _derive();
      });
    } on Object {
      if (mounted && !initial) setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _derive() {
    if (_all.isEmpty) return;
    final introduction = ((widget.detail['model_config'] as Map?)?['configs'] as Map?)?['introduction'] as String?;
    final state = buildChatThreadState(allChatItems: _all, hasMore: _hasMore, introduction: introduction);
    _tree = state.chatItemTree;
    _thread = state.threadChatItems;
    if (state.oldestAnswerId != null) _oldestAnswerId = state.oldestAnswerId;
  }

  void _onScroll() {
    final p = _scroll.position;
    // The list is reversed: the top of the transcript is the end of the scroll extent.
    if (isNearTopLoadMore(
          clientHeight: p.viewportDimension,
          scrollHeight: p.maxScrollExtent + p.viewportDimension,
          scrollTop: -p.pixels,
        ) &&
        _hasMore &&
        !_loading) {
      _fetch();
    }
  }

  /// Loads the next older page (what scrolling near the top does).
  Future<void> loadMore() => _fetch();

  Future<bool> _annotationRemoved(int index) async {
    final annotation = index < _all.length ? _all[index]['annotation'] as Map? : null;
    try {
      if (annotation?['id'] case final String id) await widget.source.deleteAnnotation(widget.app.id, id);
      setState(() {
        _all = applyAnnotationRemoved(_all, index);
        _derive();
      });
      toast.success(_c('actionMsg.modifiedSuccessfully'));
      return true;
    } on Object {
      toast.error(_c('actionMsg.modifiedUnsuccessfully'));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isChatMode = widget.app.mode != AppModes.completion;
    final isAdvanced = widget.app.mode == AppModes.advancedChat;
    final varList = getDetailVarList(widget.detail, _varValues);
    final files = getCompletionMessageFiles(widget.detail, isChatMode);
    final LogChatProps props = (
      chatList: _thread,
      onFeedback: widget.onFeedback,
      onAnnotationAdded: (id, author, q, a, i) => setState(() {
        _all = applyAnnotationAdded(_all, id, author, q, a, i);
        _derive();
      }),
      onAnnotationEdited: (q, a, i) => setState(() {
        _all = applyAnnotationEdited(_all, q, a, i);
        _derive();
      }),
      onAnnotationRemoved: _annotationRemoved,
      switchSibling: (id) => setState(() => _thread = getThreadChatItems(_tree, id)),
      hideLogModal: true,
      showPromptLog: isAdvanced,
    );
    final chat = widget.chatBuilder?.call(context, props) ?? LogChatView(props: props);
    return Container(
      key: const ValueKey('conversation-detail'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(DifyRadius.xl)),
            ),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          difyTransform(
                            DifyType.systemXsSemiboldUppercase,
                            _l(isChatMode ? 'detail.conversationId' : 'detail.time'),
                          ),
                          style: difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textPrimary),
                        ),
                      ),
                      if (isChatMode)
                        Row(
                          children: [
                            Flexible(
                              child: DifyTooltip(
                                content: Text(_id),
                                child: Text(
                                  difyTransform(DifyType.system2xsRegularUppercase, _id),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: difyTextStyle(DifyType.system2xsRegularUppercase, DifyColors.textSecondary),
                                ),
                              ),
                            ),
                            _CopyIcon(content: _id),
                          ],
                        )
                      else
                        Text(
                          AccountTime.of(context)
                              .formatTime(((widget.detail['created_at'] as num?) ?? 0).toInt(), _l('dateTimeFormat')),
                          style: difyTextStyle(DifyType.system2xsRegularUppercase, DifyColors.textSecondary),
                        ),
                    ],
                  ),
                ),
                DifyIconButton(
                  key: const ValueKey('conversation-detail-close'),
                  label: _c('operation.close'),
                  size: DifyIconButtonSize.lg,
                  icon: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              decoration: BoxDecoration(
                color: DifyColors.backgroundSectionBurn,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(DifyRadius.xl)),
              ),
              child: varList.isNotEmpty || (!isChatMode && files.isNotEmpty)
                  ? LogVarPanel(varList: varList, messageFiles: files)
                  : null,
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: DifyColors.backgroundSectionBurn,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(DifyRadius.xl)),
              ),
              child: _thread.length < minItemsForScrollLoading
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 16, bottom: 16),
                      child: chat,
                    )
                  : SingleChildScrollView(
                      key: const ValueKey('conversation-scroll'),
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_hasMore)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                '${_l('detail.loading')}...',
                                textAlign: TextAlign.center,
                                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                              ),
                            ),
                          chat,
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// base/copy-icon: copies [content], then shows a check for a moment.
class _CopyIcon extends StatefulWidget {
  const _CopyIcon({required this.content});
  final String content;

  @override
  State<_CopyIcon> createState() => _CopyIconState();
}

class _CopyIconState extends State<_CopyIcon> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: _c(_copied ? 'operation.copied' : 'operation.copy'),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: widget.content));
      if (!mounted) return;
      setState(() => _copied = true);
      Timer(const Duration(seconds: 2), () => mounted ? setState(() => _copied = false) : null);
    },
    builder: (context, hovered, focused) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: RemixIcon(
        _copied ? 'clipboard-fill' : 'clipboard-line',
        size: 14,
        color: hovered ? DifyColors.textSecondary : DifyColors.textTertiary,
      ),
    ),
  );
}

/// The drawer's chat (base/chat in the logs: no input, the processes collapsed, the admin's feedback on answers).
class LogChatView extends StatelessWidget {
  const LogChatView({super.key, required this.props});
  final LogChatProps props;

  @override
  Widget build(BuildContext context) => ChatContext(
    readonly: true,
    onFeedback: props.onFeedback,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in props.chatList)
            if (item['isAnswer'] == true)
              ChatAnswer(
                key: ValueKey('log-answer-${item['id']}'),
                item: item,
                hideProcessDetail: true,
                noChatInput: true,
                switchSibling: props.switchSibling,
              )
            else
              ChatQuestion(
                key: ValueKey('log-question-${item['id']}'),
                item: item,
                enableEdit: false,
                switchSibling: props.switchSibling,
              ),
        ],
      ),
    ),
  );
}
