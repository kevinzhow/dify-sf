/// Overview statistics and logs (docs/protocol.md section 2 "App detail pages", protocol 1.11), with **Dify 1.17.1's
/// console API paths and shapes** under `/v1` (`api/controllers/console/app/statistic.py`, `workflow_statistic.py`,
/// `workflow_app_log.py`, `conversation.py`, `message.py`, `workflow_run.py`).
///
/// dify-sf has **no runtime yet**: nothing is ever run outside the editor's debugger (whose runs Dify does not log
/// either), so every statistic is an empty series and every log list an empty page, exactly as Dify answers an app
/// nobody has used. The endpoints exist so the client calls the real paths now and shows data once a runtime fills
/// them. Demos, tests and visual cases use `FakeStatsApi(mock: true)` / `FakeLogsApi(mock: true)`
/// (`package:collab_client/testing.dart`) for plausible data.
///
/// ## Statistics (Overview charts)
///
/// [StatsApi.statistic] with an [AppStatistic] and Dify's time range (`start` / `end` as `YYYY-MM-DD HH:mm` in the
/// account's time zone; null = unbounded) -> rows `{date: "YYYY-MM-DD", <value key>: n}` ([StatisticRow]). The charts of
/// a mode are [AppStatistic.forMode], in Dify's order. Dify's chart fills the days without a row with zeros
/// (`app-chart-utils.ts`), so the empty answer draws Dify's empty chart. A malformed time is `400 bad_request`; a
/// statistic of another mode `404 app_not_found` ("App mode is not in the supported list"). Any member (Dify's
/// `app.acl.monitor`, which every CE role but dataset_operator holds; the server, like Dify, does not refuse it).
///
/// ## Logs
///
/// * Workflow apps: [LogsApi.workflowLogs] (Dify's `GET /workflow-app-logs`: keyword, status, created_at range, page,
///   limit 1-100) -> [WorkflowLogPage]; any member. The drawer's run: [LogsApi.workflowRun] and
///   [LogsApi.workflowRunNodeExecutions] (Dify's `/workflow-runs/{id}`, `/node-executions`): `404 not_found` on
///   dify-sf until runs exist.
/// * Chatflows: [LogsApi.chatConversations] (Dify's `GET /chat-conversations`: keyword, start, end, annotation_status,
///   sort_by, page, limit) -> [ChatConversationPage]; the transcript drawer: [LogsApi.chatConversation] and
///   [LogsApi.chatMessages] (`404 not_found` until conversations exist). Owner, admin, editor (Dify's
///   `edit_permission_required`); others `403`.
///
/// Mode errors (Dify's `get_app_model(mode=...)`): workflow logs of a chatflow, chat logs of a workflow ->
/// `404 app_not_found`.
///
/// Implementations: `HttpStatsApi`, `HttpLogsApi`, `FakeStatsApi`, `FakeLogsApi`.
library;

import 'apps_api.dart';

/// One Overview chart: Dify's statistic endpoints, their value member, and the modes Dify serves them for.
enum AppStatistic {
  /// Chatflow "Total Messages" (`message_count`).
  dailyMessages('statistics/daily-messages', 'message_count'),

  /// Chatflow "Total Conversations" (`conversation_count`).
  dailyConversations('statistics/daily-conversations', 'conversation_count'),

  /// Chatflow "Active Users" (`terminal_count`).
  dailyEndUsers('statistics/daily-end-users', 'terminal_count'),

  /// Chatflow "Token Usage" (`token_count`, `total_price`, `currency`).
  tokenCosts('statistics/token-costs', 'token_count'),

  /// Chatflow "Avg. Session Interactions" (`interactions`; chat modes only).
  averageSessionInteractions('statistics/average-session-interactions', 'interactions'),

  /// Chatflow "User Satisfaction Rate" (`rate`, per mille).
  userSatisfactionRate('statistics/user-satisfaction-rate', 'rate'),

  /// "Avg. Response Time" (`latency`; completion apps only: `404 app_not_found` for dify-sf's modes).
  averageResponseTime('statistics/average-response-time', 'latency'),

  /// Chatflow "Token Output Speed" (`tps`).
  tokensPerSecond('statistics/tokens-per-second', 'tps'),

  /// Workflow "Total Runs" (`runs`).
  workflowDailyRuns('workflow/statistics/daily-conversations', 'runs'),

  /// Workflow "Active Users" (`terminal_count`).
  workflowDailyTerminals('workflow/statistics/daily-terminals', 'terminal_count'),

  /// Workflow "Token Usage" (`token_count`).
  workflowTokenCosts('workflow/statistics/token-costs', 'token_count'),

  /// Workflow "Avg. User Interactions" (`interactions`; workflow apps only).
  workflowAverageInteractions('workflow/statistics/average-app-interactions', 'interactions');

  const AppStatistic(this.path, this.valueKey);

  /// The path below `/v1/apps/{id}/`.
  final String path;

  /// The row member holding the value.
  final String valueKey;

  /// Dify's Overview charts of [mode], in Dify's order (`overview/chart-view.tsx`).
  static List<AppStatistic> forMode(String mode) => mode == AppModes.workflow
      ? const [workflowDailyRuns, workflowDailyTerminals, workflowTokenCosts, workflowAverageInteractions]
      : const [
          dailyConversations,
          dailyEndUsers,
          averageSessionInteractions,
          tokensPerSecond,
          userSatisfactionRate,
          tokenCosts,
          dailyMessages,
        ];

  /// Whether the server serves this statistic for [mode] (else `404 app_not_found`, as Dify).
  bool servesMode(String mode) => switch (this) {
    averageSessionInteractions => mode == AppModes.advancedChat,
    averageResponseTime => mode == AppModes.completion,
    workflowAverageInteractions => mode == AppModes.workflow,
    _ => true,
  };
}

/// One row of a statistic: `{date, <value>}` (token costs also `total_price` and `currency`).
final class StatisticRow {
  const StatisticRow({required this.date, required this.value, this.json = const {}});

  factory StatisticRow.fromJson(Map<String, Object?> m, String valueKey) => StatisticRow(
    date: m['date'] is String ? m['date']! as String : '',
    value: m[valueKey] is num ? m[valueKey]! as num : 0,
    json: m,
  );

  /// `YYYY-MM-DD`.
  final String date;
  final num value;
  final Map<String, Object?> json;

  /// Token costs: Dify's `total_price` (a decimal string or number), else null.
  num? get totalPrice => switch (json['total_price']) {
    final num n => n,
    final String s => num.tryParse(s),
    _ => null,
  };

  /// Token costs: `USD`.
  String? get currency => json['currency'] is String ? json['currency']! as String : null;
}

/// See the library documentation above.
abstract interface class StatsApi {
  /// `GET /v1/apps/{appId}/<stat.path>?start&end` -> Dify's `{data: [...]}` rows.
  Future<List<StatisticRow>> statistic(String appId, AppStatistic stat, {String? start, String? end});
}

/// Dify's `WorkflowExecutionStatus` values for [WorkflowLogQuery.status].
abstract final class WorkflowRunStatus {
  static const running = 'running';
  static const succeeded = 'succeeded';
  static const failed = 'failed';
  static const stopped = 'stopped';
  static const partialSucceeded = 'partial-succeeded';
  static const paused = 'paused';
}

/// Dify's `WorkflowAppLogQuery`.
final class WorkflowLogQuery {
  const WorkflowLogQuery({
    this.keyword,
    this.status,
    this.createdAtBefore,
    this.createdAtAfter,
    this.createdByEndUserSessionId,
    this.createdByAccount,
    this.detail = false,
    this.page = 1,
    this.limit = 20,
  });

  final String? keyword;

  /// [WorkflowRunStatus]; null = all.
  final String? status;

  /// ISO 8601 times.
  final String? createdAtBefore;
  final String? createdAtAfter;
  final String? createdByEndUserSessionId;
  final String? createdByAccount;
  final bool detail;

  /// 1-99999.
  final int page;

  /// 1-100 (Dify's page asks for 10, 25 or 50).
  final int limit;

  Map<String, List<String>> toQuery() => {
    if (keyword != null && keyword!.isNotEmpty) 'keyword': [keyword!],
    if (status != null && status!.isNotEmpty) 'status': [status!],
    if (createdAtBefore != null) 'created_at__before': [createdAtBefore!],
    if (createdAtAfter != null) 'created_at__after': [createdAtAfter!],
    if (createdByEndUserSessionId != null) 'created_by_end_user_session_id': [createdByEndUserSessionId!],
    if (createdByAccount != null) 'created_by_account': [createdByAccount!],
    if (detail) 'detail': ['true'],
    'page': ['$page'],
    'limit': ['$limit'],
  };
}

/// One workflow log row: Dify's `WorkflowAppLogPartialResponse` (typed getters over [json]).
final class WorkflowLogEntry {
  const WorkflowLogEntry(this.json);

  final Map<String, Object?> json;

  String get id => json['id'] is String ? json['id']! as String : '';

  /// Dify's `workflow_run` (`id, version, status, triggered_from, error, elapsed_time, total_tokens, total_steps,
  /// created_at, finished_at, exceptions_count`).
  Map<String, Object?> get workflowRun =>
      json['workflow_run'] is Map<String, Object?> ? json['workflow_run']! as Map<String, Object?> : const {};

  String get runId => workflowRun['id'] is String ? workflowRun['id']! as String : '';
  String? get status => workflowRun['status'] is String ? workflowRun['status']! as String : null;
  String? get triggeredFrom =>
      workflowRun['triggered_from'] is String ? workflowRun['triggered_from']! as String : null;
  num? get elapsedTime => workflowRun['elapsed_time'] is num ? workflowRun['elapsed_time']! as num : null;
  int? get totalTokens => workflowRun['total_tokens'] is num ? (workflowRun['total_tokens']! as num).toInt() : null;

  /// `web-app`, `service-api`, ...
  String? get createdFrom => json['created_from'] is String ? json['created_from']! as String : null;

  /// `account` or `end_user`.
  String? get createdByRole => json['created_by_role'] is String ? json['created_by_role']! as String : null;
  Map<String, Object?>? get createdByAccount =>
      json['created_by_account'] is Map<String, Object?> ? json['created_by_account']! as Map<String, Object?> : null;
  Map<String, Object?>? get createdByEndUser =>
      json['created_by_end_user'] is Map<String, Object?> ? json['created_by_end_user']! as Map<String, Object?> : null;

  /// Epoch seconds.
  int get createdAt => json['created_at'] is num ? (json['created_at']! as num).toInt() : 0;
}

/// Dify's `WorkflowAppLogPaginationResponse`.
final class WorkflowLogPage {
  const WorkflowLogPage({
    required this.page,
    required this.limit,
    required this.total,
    required this.hasMore,
    required this.data,
  });

  factory WorkflowLogPage.fromJson(Map<String, Object?> m) => WorkflowLogPage(
    page: m['page'] is num ? (m['page']! as num).toInt() : 1,
    limit: m['limit'] is num ? (m['limit']! as num).toInt() : 20,
    total: m['total'] is num ? (m['total']! as num).toInt() : 0,
    hasMore: m['has_more'] == true,
    data: [
      if (m['data'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) WorkflowLogEntry(x),
    ],
  );

  final int page;
  final int limit;
  final int total;
  final bool hasMore;
  final List<WorkflowLogEntry> data;

  Map<String, Object?> toJson() => {
    'page': page,
    'limit': limit,
    'total': total,
    'has_more': hasMore,
    'data': [for (final e in data) e.json],
  };
}

/// Dify's `ChatConversationQuery`.
final class ChatConversationQuery {
  const ChatConversationQuery({
    this.keyword,
    this.start,
    this.end,
    this.annotationStatus = 'all',
    this.sortBy = '-updated_at',
    this.page = 1,
    this.limit = 20,
  });

  final String? keyword;

  /// `YYYY-MM-DD HH:mm`.
  final String? start;
  final String? end;

  /// `annotated`, `not_annotated`, `all`.
  final String annotationStatus;

  /// `created_at`, `-created_at`, `updated_at`, `-updated_at`.
  final String sortBy;
  final int page;
  final int limit;

  Map<String, List<String>> toQuery() => {
    if (keyword != null && keyword!.isNotEmpty) 'keyword': [keyword!],
    if (start != null && start!.isNotEmpty) 'start': [start!],
    if (end != null && end!.isNotEmpty) 'end': [end!],
    'annotation_status': [annotationStatus],
    'sort_by': [sortBy],
    'page': ['$page'],
    'limit': ['$limit'],
  };
}

/// One chat log row: Dify's `ConversationWithSummary` (typed getters over [json]).
final class ChatConversation {
  const ChatConversation(this.json);

  final Map<String, Object?> json;

  String get id => json['id'] is String ? json['id']! as String : '';
  String get name => json['name'] is String ? json['name']! as String : '';

  /// The first query (Dify's `summary_or_query`).
  String get summary => json['summary'] is String ? json['summary']! as String : '';
  String? get status => json['status'] is String ? json['status']! as String : null;
  String? get fromSource => json['from_source'] is String ? json['from_source']! as String : null;
  String? get fromEndUserSessionId =>
      json['from_end_user_session_id'] is String ? json['from_end_user_session_id']! as String : null;
  String? get fromAccountName => json['from_account_name'] is String ? json['from_account_name']! as String : null;
  int get messageCount => json['message_count'] is num ? (json['message_count']! as num).toInt() : 0;
  bool get annotated => json['annotated'] == true;

  /// `{like, dislike}`.
  Map<String, Object?> get userFeedbackStats => json['user_feedback_stats'] is Map<String, Object?>
      ? json['user_feedback_stats']! as Map<String, Object?>
      : const {};
  Map<String, Object?> get adminFeedbackStats => json['admin_feedback_stats'] is Map<String, Object?>
      ? json['admin_feedback_stats']! as Map<String, Object?>
      : const {};

  /// `{success, failed, partial_success, paused}`.
  Map<String, Object?> get statusCount =>
      json['status_count'] is Map<String, Object?> ? json['status_count']! as Map<String, Object?> : const {};
  int? get readAt => json['read_at'] is num ? (json['read_at']! as num).toInt() : null;
  int get createdAt => json['created_at'] is num ? (json['created_at']! as num).toInt() : 0;
  int get updatedAt => json['updated_at'] is num ? (json['updated_at']! as num).toInt() : 0;
}

/// Dify's `ConversationWithSummaryPagination`.
final class ChatConversationPage {
  const ChatConversationPage({
    required this.page,
    required this.limit,
    required this.total,
    required this.hasMore,
    required this.data,
  });

  factory ChatConversationPage.fromJson(Map<String, Object?> m) => ChatConversationPage(
    page: m['page'] is num ? (m['page']! as num).toInt() : 1,
    limit: m['limit'] is num ? (m['limit']! as num).toInt() : 20,
    total: m['total'] is num ? (m['total']! as num).toInt() : 0,
    hasMore: m['has_more'] == true,
    data: [
      if (m['data'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) ChatConversation(x),
    ],
  );

  final int page;
  final int limit;
  final int total;
  final bool hasMore;
  final List<ChatConversation> data;

  Map<String, Object?> toJson() => {
    'page': page,
    'limit': limit,
    'total': total,
    'has_more': hasMore,
    'data': [for (final c in data) c.json],
  };
}

/// Dify's `MessageInfiniteScrollPagination` (`{limit, has_more, data}`) of [LogsApi.chatMessages]; messages are Dify's
/// `MessageDetail` maps.
final class ChatMessagePage {
  const ChatMessagePage({required this.limit, required this.hasMore, required this.data});

  factory ChatMessagePage.fromJson(Map<String, Object?> m) => ChatMessagePage(
    limit: m['limit'] is num ? (m['limit']! as num).toInt() : 20,
    hasMore: m['has_more'] == true,
    data: [
      if (m['data'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) x,
    ],
  );

  final int limit;
  final bool hasMore;
  final List<Map<String, Object?>> data;
}

/// See the library documentation above.
abstract interface class LogsApi {
  /// `GET /v1/apps/{appId}/workflow-app-logs` (workflow apps).
  Future<WorkflowLogPage> workflowLogs(String appId, [WorkflowLogQuery query = const WorkflowLogQuery()]);

  /// `GET /v1/apps/{appId}/workflow-runs/{runId}`: Dify's `WorkflowRunDetailResponse` map.
  Future<Map<String, Object?>> workflowRun(String appId, String runId);

  /// `GET /v1/apps/{appId}/workflow-runs/{runId}/node-executions`: Dify's `{data: [...]}` node execution maps.
  Future<List<Map<String, Object?>>> workflowRunNodeExecutions(String appId, String runId);

  /// `GET /v1/apps/{appId}/chat-conversations` (chatflows).
  Future<ChatConversationPage> chatConversations(
    String appId, [
    ChatConversationQuery query = const ChatConversationQuery(),
  ]);

  /// `GET /v1/apps/{appId}/chat-conversations/{conversationId}`: Dify's `ConversationDetail` map.
  Future<Map<String, Object?>> chatConversation(String appId, String conversationId);

  /// `GET /v1/apps/{appId}/chat-messages?conversation_id&first_id&limit`.
  Future<ChatMessagePage> chatMessages(String appId, String conversationId, {String? firstId, int limit = 20});

  /// `POST /v1/apps/{appId}/feedbacks` (1.11 amendment; any member; Dify's `MessageFeedbackApi`): the member's ("admin")
  /// [rating] of message [messageId], `like` or `dislike` with an optional [content] (a dislike's "what went wrong"),
  /// or null to remove it. `404 not_found` "Message Not Exists." for a message that is not the app's (every message until
  /// a runtime exists); `400 bad_request` for a null [rating] without a feedback to remove, or a [messageId] that is not
  /// a UUID.
  Future<void> updateFeedback(String appId, {required String messageId, String? rating, String? content});
}
