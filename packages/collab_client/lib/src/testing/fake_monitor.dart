import '../apps_api.dart';
import '../auth/account.dart';
import '../client/transport.dart';
import '../monitor_api.dart';
import 'fake_apps.dart';

/// An in-memory [StatsApi] (protocol 1.11). By default it answers as the server does today: every statistic is an empty
/// series (no runtime). With [mock] it answers a plausible, deterministic series (one row per day of the range, values
/// seeded by app, statistic and date) for demos, tests and visual cases.
///
/// With [apps] it also applies the server's checks: the app must exist (`404 not_found` / `app_deleted`) and the
/// statistic must serve its mode ([AppStatistic.servesMode], else `404 app_not_found`); any member may read. Without
/// [apps] every app id is accepted and [modeOf] (default: workflow) decides the mode. Times are Dify's `YYYY-MM-DD
/// HH:mm` (else `400 bad_request`); without a range the mock covers the 7 days up to [clock]'s today.
class FakeStatsApi implements StatsApi {
  FakeStatsApi({this.apps, this.mock = false, DateTime Function()? clock, this.modeOf}) : clock = clock ?? DateTime.now;

  final FakeAppsApi? apps;

  /// Answer mock data instead of the server's empty series.
  bool mock;
  DateTime Function() clock;

  /// Without [apps]: the mode of an app id (default: workflow).
  final String Function(String appId)? modeOf;

  /// Calls so far, by statistic.
  final Map<AppStatistic, int> requests = {};

  static final _time = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$');

  static DateTime? _parse(String? s, String label) {
    if (s == null || s.isEmpty) return null;
    final m = _time.firstMatch(s);
    if (m == null) {
      throw TransportException(
        "Invalid $label time format: time data '$s' does not match format '%Y-%m-%d %H:%M'",
        statusCode: 400,
        code: 'bad_request',
      );
    }
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!));
  }

  Future<String> _mode(String appId) async =>
      apps != null ? (await apps!.get(appId)).mode : (modeOf?.call(appId) ?? AppModes.workflow);

  @override
  Future<List<StatisticRow>> statistic(String appId, AppStatistic stat, {String? start, String? end}) async {
    requests[stat] = (requests[stat] ?? 0) + 1;
    final from = _parse(start, 'start'), to = _parse(end, 'end');
    if (from != null && to != null && from.isAfter(to)) {
      throw const TransportException(
        'start must be earlier than or equal to end',
        statusCode: 400,
        code: 'bad_request',
      );
    }
    final mode = await _mode(appId);
    if (!stat.servesMode(mode)) {
      throw const TransportException('App mode is not in the supported list', statusCode: 404, code: 'app_not_found');
    }
    if (!mock) return const [];
    final today = clock();
    final last = DateTime(today.year, today.month, today.day);
    final first = from == null
        ? (to == null
              ? last.subtract(const Duration(days: 6))
              : DateTime(to.year, to.month, to.day).subtract(const Duration(days: 6)))
        : DateTime(from.year, from.month, from.day);
    final stop = to == null ? last : DateTime(to.year, to.month, to.day);
    final rows = <StatisticRow>[];
    for (var d = first; !d.isAfter(stop); d = DateTime(d.year, d.month, d.day + 1)) {
      final date =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      rows.add(StatisticRow.fromJson(_mockRow(appId, stat, date), stat.valueKey));
      if (rows.length > 400) break;
    }
    return rows;
  }

  static int _seed(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  static Map<String, Object?> _mockRow(String appId, AppStatistic stat, String date) {
    final r = _seed('$appId/${stat.name}/$date');
    final f = (r % 1000) / 1000.0; // 0 .. 1
    final Object value = switch (stat) {
      AppStatistic.dailyMessages => 40 + (f * 160).round(),
      AppStatistic.dailyConversations => 10 + (f * 60).round(),
      AppStatistic.dailyEndUsers || AppStatistic.workflowDailyTerminals => 3 + (f * 25).round(),
      AppStatistic.tokenCosts || AppStatistic.workflowTokenCosts => 2000 + (f * 18000).round(),
      AppStatistic.averageSessionInteractions ||
      AppStatistic.workflowAverageInteractions => double.parse((1 + f * 4).toStringAsFixed(2)),
      AppStatistic.userSatisfactionRate => double.parse((600 + f * 350).toStringAsFixed(2)),
      AppStatistic.averageResponseTime => double.parse((300 + f * 1200).toStringAsFixed(2)),
      AppStatistic.tokensPerSecond => double.parse((20 + f * 60).toStringAsFixed(4)),
      AppStatistic.workflowDailyRuns => 5 + (f * 80).round(),
    };
    return {
      'date': date,
      stat.valueKey: value,
      if (stat == AppStatistic.tokenCosts) ...{
        'total_price': ((value as int) * 0.000002).toStringAsFixed(7),
        'currency': 'USD',
      },
    };
  }
}

/// An in-memory [LogsApi] (protocol 1.11). By default it answers as the server does today: empty pages, `404 not_found`
/// for a run, a conversation or its messages, and no node executions (nothing was ever run). With [mock] it answers a deterministic
/// set of log rows (12 workflow runs or 12 chat conversations per app, newest first, the filters and pages applied), a
/// run detail and node executions in Dify's shapes ([workflowRunOf] / [nodeExecutionsOf] replace them, e.g. with the
/// app's mock run service JSON), and a short transcript per conversation.
///
/// With [apps]: the app must exist; workflow logs need a workflow app, chat logs a chatflow (`404 app_not_found`); chat
/// logs need owner, admin or editor (`403 forbidden`); workflow logs any member. Without [apps], [modeOf] decides.
class FakeLogsApi implements LogsApi {
  FakeLogsApi({
    this.apps,
    this.mock = false,
    DateTime Function()? clock,
    this.modeOf,
    this.workflowRunOf,
    this.nodeExecutionsOf,
  }) : clock = clock ?? DateTime.now;

  final FakeAppsApi? apps;
  bool mock;
  DateTime Function() clock;

  /// Without [apps]: the mode of an app id (default: workflow).
  final String Function(String appId)? modeOf;

  /// Replaces the mock's run detail (Dify's `WorkflowRunDetailResponse`).
  Map<String, Object?> Function(String appId, String runId)? workflowRunOf;

  /// Replaces the mock's node executions.
  List<Map<String, Object?>> Function(String appId, String runId)? nodeExecutionsOf;

  static const _mockCount = 12;

  Future<String> _mode(String appId) async =>
      apps != null ? (await apps!.get(appId)).mode : (modeOf?.call(appId) ?? AppModes.workflow);

  Future<void> _require(String appId, String mode, {bool edit = false}) async {
    if (edit && apps != null && !AccountRole.canEdit(apps!.role)) {
      throw TransportException('the ${apps!.role} role cannot edit', statusCode: 403, code: 'forbidden');
    }
    final m = await _mode(appId);
    if (m != mode) {
      throw TransportException(
        "App mode is not in the supported list: {'$mode'}",
        statusCode: 404,
        code: 'app_not_found',
      );
    }
  }

  int _now() => clock().millisecondsSinceEpoch ~/ 1000;

  static const _statuses = ['succeeded', 'succeeded', 'failed', 'succeeded', 'partial-succeeded', 'stopped'];

  Map<String, Object?> _runRow(String appId, int i) {
    final created = _now() - 3600 * (i * 5 + 1);
    final status = _statuses[i % _statuses.length];
    return {
      'id': 'log-$appId-$i',
      'workflow_run': {
        'id': 'run-$appId-$i',
        'version': '2026-10-19 08:00:00.000000',
        'status': status,
        'triggered_from': i.isEven ? 'app-run' : 'service-api',
        'error': status == 'failed' ? 'Node LLM run failed: rate limited' : null,
        'elapsed_time': 0.8 + (i % 5) * 1.3,
        'total_tokens': 120 + i * 37,
        'total_steps': 3 + i % 4,
        'created_at': created,
        'finished_at': created + 2,
        'exceptions_count': status == 'partial-succeeded' ? 1 : 0,
      },
      'details': null,
      'created_from': i.isEven ? 'web-app' : 'service-api',
      'created_by_role': i.isEven ? 'end_user' : 'account',
      'created_by_account': i.isEven ? null : {'id': 'account-owner', 'name': 'Owner', 'email': 'owner@example.com'},
      'created_by_end_user': i.isEven
          ? {'id': 'end-user-$i', 'type': 'browser', 'is_anonymous': true, 'session_id': 'session-${i ~/ 2}'}
          : null,
      'created_at': created,
    };
  }

  @override
  Future<WorkflowLogPage> workflowLogs(String appId, [WorkflowLogQuery query = const WorkflowLogQuery()]) async {
    await _require(appId, AppModes.workflow);
    _page(query.page, query.limit);
    if (!mock) return WorkflowLogPage(page: query.page, limit: query.limit, total: 0, hasMore: false, data: const []);
    final k = query.keyword?.toLowerCase();
    bool keep(int i) {
      final run = _runRow(appId, i)['workflow_run']! as Map<String, Object?>;
      if (query.status != null && query.status!.isNotEmpty && run['status'] != query.status) return false;
      return k == null || k.isEmpty || 'run-$appId-$i'.contains(k) || 'session-${i ~/ 2}'.contains(k);
    }

    final all = [
      for (var i = 0; i < _mockCount; i++)
        if (keep(i)) WorkflowLogEntry(_runRow(appId, i)),
    ];
    final start = (query.page - 1) * query.limit;
    final data = start >= all.length
        ? const <WorkflowLogEntry>[]
        : all.sublist(start, (start + query.limit).clamp(0, all.length));
    return WorkflowLogPage(
      page: query.page,
      limit: query.limit,
      total: all.length,
      hasMore: start + query.limit < all.length,
      data: data,
    );
  }

  void _page(int page, int limit) {
    if (page < 1 || page > 99999) {
      throw const TransportException('page must be 1-99999', statusCode: 400, code: 'bad_request');
    }
    if (limit < 1 || limit > 100) {
      throw const TransportException('limit must be 1-100', statusCode: 400, code: 'bad_request');
    }
  }

  int? _runIndex(String appId, String runId) {
    final prefix = 'run-$appId-';
    if (!runId.startsWith(prefix)) return null;
    final i = int.tryParse(runId.substring(prefix.length));
    return i != null && i >= 0 && i < _mockCount ? i : null;
  }

  @override
  Future<Map<String, Object?>> workflowRun(String appId, String runId) async {
    await _mode(appId);
    final i = mock ? _runIndex(appId, runId) : null;
    if (i == null) throw const TransportException('Workflow run not found', statusCode: 404, code: 'not_found');
    if (workflowRunOf != null) return workflowRunOf!(appId, runId);
    final row = _runRow(appId, i);
    final run = row['workflow_run']! as Map<String, Object?>;
    return {
      'id': runId,
      'version': run['version'],
      'graph': {'nodes': const <Object?>[], 'edges': const <Object?>[]},
      'inputs': {'query': 'Question $i'},
      'inputs_truncated': false,
      'status': run['status'],
      'outputs': {'result': 'Answer $i'},
      'outputs_truncated': false,
      'error': run['error'],
      'elapsed_time': run['elapsed_time'],
      'total_tokens': run['total_tokens'],
      'total_steps': run['total_steps'],
      'created_by_role': row['created_by_role'],
      'created_by_account': row['created_by_account'],
      'created_by_end_user': row['created_by_end_user'],
      'created_at': run['created_at'],
      'finished_at': run['finished_at'],
      'exceptions_count': run['exceptions_count'],
    };
  }

  @override
  Future<List<Map<String, Object?>>> workflowRunNodeExecutions(String appId, String runId) async {
    await _mode(appId);
    final i = mock ? _runIndex(appId, runId) : null;
    // Dify answers an unknown run's node executions with an empty list.
    if (i == null) return const [];
    if (nodeExecutionsOf != null) return nodeExecutionsOf!(appId, runId);
    final created = (_runRow(appId, i)['workflow_run']! as Map<String, Object?>)['created_at']! as int;
    Map<String, Object?> node(int index, String id, String type, String title) => {
      'id': 'exec-$runId-$index',
      'index': index,
      'predecessor_node_id': null,
      'node_id': id,
      'node_type': type,
      'title': title,
      'inputs': const <String, Object?>{},
      'process_data': const <String, Object?>{},
      'outputs': const <String, Object?>{},
      'status': 'succeeded',
      'error': null,
      'elapsed_time': 0.2 * index,
      'execution_metadata': const <String, Object?>{},
      'extras': const <String, Object?>{},
      'created_at': created,
      'created_by_role': 'account',
      'finished_at': created + index,
    };
    return [node(1, 'start', 'start', 'User Input'), node(2, 'llm', 'llm', 'LLM'), node(3, 'end', 'end', 'Output')];
  }

  Map<String, Object?> _conversation(String appId, int i) {
    final created = _now() - 3600 * (i * 7 + 2);
    return {
      'id': 'conv-$appId-$i',
      'status': 'normal',
      'from_source': i.isEven ? 'api' : 'console',
      'from_end_user_id': i.isEven ? 'end-user-$i' : null,
      'from_end_user_session_id': i.isEven ? 'session-$i' : null,
      'from_account_id': i.isEven ? null : 'account-owner',
      'from_account_name': i.isEven ? null : 'Owner',
      'name': 'Conversation $i',
      'summary': 'How do I configure step ${i + 1}?',
      'read_at': i < 3 ? null : created,
      'created_at': created,
      'updated_at': created + 600,
      'annotated': i % 4 == 0,
      'model_config': null,
      'message_count': 2 + i % 5,
      'user_feedback_stats': {'like': i % 3, 'dislike': i % 2},
      'admin_feedback_stats': {'like': i % 2, 'dislike': 0},
      'status_count': {'success': 2 + i % 5, 'failed': 0, 'partial_success': 0, 'paused': 0},
    };
  }

  @override
  Future<ChatConversationPage> chatConversations(
    String appId, [
    ChatConversationQuery query = const ChatConversationQuery(),
  ]) async {
    await _require(appId, AppModes.advancedChat, edit: true);
    _page(query.page, query.limit);
    if (!mock) {
      return ChatConversationPage(page: query.page, limit: query.limit, total: 0, hasMore: false, data: const []);
    }
    final k = query.keyword?.toLowerCase();
    final all = [
      for (var i = 0; i < _mockCount; i++)
        if (_conversation(appId, i) case final c
            when (k == null || k.isEmpty || (c['summary']! as String).toLowerCase().contains(k)) &&
                (query.annotationStatus == 'all' ||
                    (query.annotationStatus == 'annotated') == (c['annotated'] == true)))
          c,
    ];
    final key = query.sortBy.replaceFirst('-', '');
    all.sort((a, b) {
      final c = (a[key]! as int).compareTo(b[key]! as int);
      return query.sortBy.startsWith('-') ? -c : c;
    });
    final start = (query.page - 1) * query.limit;
    final data = start >= all.length
        ? const <Map<String, Object?>>[]
        : all.sublist(start, (start + query.limit).clamp(0, all.length));
    return ChatConversationPage(
      page: query.page,
      limit: query.limit,
      total: all.length,
      hasMore: start + query.limit < all.length,
      data: [for (final c in data) ChatConversation(c)],
    );
  }

  int? _conversationIndex(String appId, String id) {
    final prefix = 'conv-$appId-';
    if (!id.startsWith(prefix)) return null;
    final i = int.tryParse(id.substring(prefix.length));
    return i != null && i >= 0 && i < _mockCount ? i : null;
  }

  @override
  Future<Map<String, Object?>> chatConversation(String appId, String conversationId) async {
    await _require(appId, AppModes.advancedChat, edit: true);
    final i = mock ? _conversationIndex(appId, conversationId) : null;
    if (i == null) throw const TransportException('Conversation Not Exists.', statusCode: 404, code: 'not_found');
    final c = _conversation(appId, i);
    return {
      'id': conversationId,
      'status': c['status'],
      'from_source': c['from_source'],
      'from_end_user_id': c['from_end_user_id'],
      'from_account_id': c['from_account_id'],
      'created_at': c['created_at'],
      'model_config': null,
      'message': null,
    };
  }

  @override
  Future<ChatMessagePage> chatMessages(String appId, String conversationId, {String? firstId, int limit = 20}) async {
    await _require(appId, AppModes.advancedChat, edit: true);
    final i = mock ? _conversationIndex(appId, conversationId) : null;
    if (i == null) throw const TransportException('Conversation Not Exists.', statusCode: 404, code: 'not_found');
    final c = _conversation(appId, i);
    final n = c['message_count']! as int;
    final created = c['created_at']! as int;
    final all = [
      for (var m = 0; m < n; m++)
        {
          'id': 'msg-$conversationId-$m',
          'conversation_id': conversationId,
          'parent_message_id': m == 0 ? null : 'msg-$conversationId-${m - 1}',
          'inputs': const <String, Object?>{},
          'query': m == 0 ? c['summary'] : 'Follow-up question $m',
          'answer': 'Here is how: step $m.',
          'message_tokens': 20 + m,
          'answer_tokens': 60 + m,
          'provider_response_latency': 1.2,
          'from_source': c['from_source'],
          'from_end_user_id': c['from_end_user_id'],
          'from_account_id': c['from_account_id'],
          'feedbacks': [
            if (_adminFeedback['msg-$conversationId-$m'] case final f?)
              {...f, 'from_source': 'admin', 'from_end_user_id': null},
          ],
          'workflow_run_id': null,
          'annotation': null,
          'annotation_hit_history': null,
          'created_at': created + m * 60,
          'agent_thoughts': const <Object?>[],
          'message_files': const <Object?>[],
          'metadata': const <String, Object?>{},
          'status': 'normal',
          'error': null,
        },
    ];
    // Dify pages backwards from `first_id` (older messages), oldest first within a page.
    var end = all.length;
    if (firstId != null && firstId.isNotEmpty) {
      end = all.indexWhere((m) => m['id'] == firstId);
      if (end < 0) throw const TransportException('First message not found', statusCode: 404, code: 'not_found');
    }
    final start = (end - limit).clamp(0, end);
    return ChatMessagePage(limit: limit, hasMore: start > 0, data: all.sublist(start, end));
  }

  /// The members' feedback by message id (`rating`, `content`, `from_account_id`).
  final Map<String, Map<String, Object?>> _adminFeedback = {};

  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$');

  /// Whether [messageId] is one of the mock's messages of [appId].
  bool _mockMessage(String appId, String messageId) {
    final m = RegExp(r'^msg-(.+)-(\d+)$').firstMatch(messageId);
    if (!mock || m == null) return false;
    final i = _conversationIndex(appId, m.group(1)!);
    return i != null && int.parse(m.group(2)!) < (_conversation(appId, i)['message_count']! as int);
  }

  @override
  Future<void> updateFeedback(String appId, {required String messageId, String? rating, String? content}) async {
    if (apps != null) await apps!.get(appId); // the app must exist (any member)
    final known = _mockMessage(appId, messageId);
    if (!known && !_uuid.hasMatch(messageId)) {
      throw TransportException('$messageId is not a valid uuid.', statusCode: 400, code: 'bad_request');
    }
    if (rating != null && rating != 'like' && rating != 'dislike') {
      throw const TransportException(
        'rating must be one of like, dislike or null',
        statusCode: 400,
        code: 'bad_request',
      );
    }
    if (!known) throw const TransportException('Message Not Exists.', statusCode: 404, code: 'not_found');
    final current = _adminFeedback[messageId];
    if (rating == null) {
      if (current == null) {
        throw const TransportException(
          'rating cannot be None when feedback not exists',
          statusCode: 400,
          code: 'bad_request',
        );
      }
      _adminFeedback.remove(messageId);
      return;
    }
    _adminFeedback[messageId] = {
      'rating': rating,
      'content': content,
      'from_account_id': current?['from_account_id'] ?? apps?.accountId,
    };
  }
}
