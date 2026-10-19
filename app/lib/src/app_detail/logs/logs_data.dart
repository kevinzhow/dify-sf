/// What the Logs pages read and write, in Dify 1.17.1's console API shapes (`service/log.ts`, `service/use-log.ts`):
/// workflow app logs, workflow runs and their node executions, chat conversations, their messages, the annotation
/// count and admin feedback.
///
/// dify-sf has no runtime yet (debugger runs are never logged in Dify either), so the server answers empty pages; the
/// [MockAppLogsSource] fills the pages for tests, the demo and the visual cases.
library;

import 'package:collab_client/collab_client.dart'
    show AnnotationsApi, AppInfo, ChatConversationQuery, LogsApi, TransportException, WorkflowLogQuery;

import '../detail_page_slot.dart';

typedef Json = Map<String, Object?>;

/// The Logs pages' data. Methods answer Dify's JSON; the path each one stands for is in its comment.
abstract class AppLogsSource {
  /// `GET /apps/{appId}/workflow-app-logs?page&limit&detail&status&keyword&created_at__after&created_at__before`:
  /// `{data, has_more, limit, total, page}`.
  Future<Json> workflowLogs(String appId, Map<String, Object?> params);

  /// `GET /apps/{appId}/workflow-runs/{runId}`.
  Future<Json> workflowRun(String appId, String runId);

  /// `GET /apps/{appId}/workflow-runs/{runId}/node-executions`: the `data` list.
  Future<List<Json>> nodeExecutions(String appId, String runId);

  /// `GET /apps/{appId}/chat-conversations?page&limit&start&end&annotation_status&keyword&sort_by`:
  /// `{data, has_more, limit, total, page}`.
  Future<Json> chatConversations(String appId, Map<String, Object?> params);

  /// `GET /apps/{appId}/chat-conversations/{conversationId}`.
  Future<Json> chatConversation(String appId, String conversationId);

  /// `GET /apps/{appId}/chat-messages?conversation_id&limit&first_id`: `{data, has_more, limit}`.
  Future<Json> chatMessages(String appId, Map<String, Object?> params);

  /// `GET /apps/{appId}/annotations/count`: `{count}`.
  Future<Json> annotationsCount(String appId);

  /// `POST /apps/{appId}/feedbacks` `{message_id, rating, content}` (rating null clears the admin's feedback).
  Future<void> updateFeedback(String appId, Json body);

  /// `DELETE /apps/{appId}/annotations/{annotationId}` (service/annotation.ts `delAnnotation`).
  Future<void> deleteAnnotation(String appId, String annotationId);
}

/// No runtime: every list is empty (Dify's empty pages), no annotation yet.
class EmptyAppLogsSource implements AppLogsSource {
  const EmptyAppLogsSource();

  static Json _page(Map<String, Object?> params) => {
    'data': const <Json>[],
    'has_more': false,
    'limit': params['limit'] ?? 10,
    'total': 0,
    'page': params['page'] ?? 1,
  };

  @override
  Future<Json> workflowLogs(String appId, Map<String, Object?> params) async => _page(params);

  @override
  Future<Json> workflowRun(String appId, String runId) async => {'id': runId};

  @override
  Future<List<Json>> nodeExecutions(String appId, String runId) async => const [];

  @override
  Future<Json> chatConversations(String appId, Map<String, Object?> params) async => _page(params);

  @override
  Future<Json> chatConversation(String appId, String conversationId) async => {'id': conversationId};

  @override
  Future<Json> chatMessages(String appId, Map<String, Object?> params) async => {
    'data': const <Json>[],
    'has_more': false,
    'limit': params['limit'] ?? 10,
  };

  @override
  Future<Json> annotationsCount(String appId) async => {'count': 0};

  @override
  Future<void> updateFeedback(String appId, Json body) async {}

  @override
  Future<void> deleteAnnotation(String appId, String annotationId) async {}
}

/// The Logs pages' source for [detail]: an injected [AppLogsSource], else the session's [LogsApi] (with its
/// [AnnotationsApi] for the annotation count), else the empty one.
AppLogsSource appLogsSourceOf(AppDetailContext detail) {
  if (detail.service<AppLogsSource>() case final s?) return s;
  if (detail.service<LogsApi>() case final logs?) {
    return LogsApiSource(logs, annotations: detail.service<AnnotationsApi>());
  }
  return const EmptyAppLogsSource();
}

/// [AppLogsSource] over collab_client's [LogsApi] (protocol 1.11). dify-sf has no feedback endpoint yet (no
/// runtime messages to rate): [updateFeedback] fails with `501`, which the drawer shows as Dify's failure toast.
class LogsApiSource implements AppLogsSource {
  LogsApiSource(this.logs, {this.annotations});

  final LogsApi logs;
  final AnnotationsApi? annotations;

  static int _int(Object? v, int fallback) => switch (v) {
    final num n => n.toInt(),
    final String s => int.tryParse(s) ?? fallback,
    _ => fallback,
  };

  static String? _str(Object? v) => v is String ? v : null;

  @override
  Future<Json> workflowLogs(String appId, Map<String, Object?> params) async => (await logs.workflowLogs(
    appId,
    WorkflowLogQuery(
      keyword: _str(params['keyword']),
      status: _str(params['status']),
      createdAtAfter: _str(params['created_at__after']),
      createdAtBefore: _str(params['created_at__before']),
      detail: params['detail'] == true,
      page: _int(params['page'], 1),
      limit: _int(params['limit'], 10),
    ),
  )).toJson();

  @override
  Future<Json> workflowRun(String appId, String runId) => logs.workflowRun(appId, runId);

  @override
  Future<List<Json>> nodeExecutions(String appId, String runId) => logs.workflowRunNodeExecutions(appId, runId);

  @override
  Future<Json> chatConversations(String appId, Map<String, Object?> params) async => (await logs.chatConversations(
    appId,
    ChatConversationQuery(
      keyword: _str(params['keyword']),
      start: _str(params['start']),
      end: _str(params['end']),
      annotationStatus: _str(params['annotation_status']) ?? 'all',
      sortBy: _str(params['sort_by']) ?? '-created_at',
      page: _int(params['page'], 1),
      limit: _int(params['limit'], 10),
    ),
  )).toJson();

  @override
  Future<Json> chatConversation(String appId, String conversationId) => logs.chatConversation(appId, conversationId);

  @override
  Future<Json> chatMessages(String appId, Map<String, Object?> params) async {
    final page = await logs.chatMessages(
      appId,
      '${params['conversation_id']}',
      firstId: _str(params['first_id']),
      limit: _int(params['limit'], 10),
    );
    return {'data': page.data, 'has_more': page.hasMore, 'limit': page.limit};
  }

  @override
  Future<Json> annotationsCount(String appId) async => {'count': await annotations?.count(appId) ?? 0};

  @override
  Future<void> updateFeedback(String appId, Json body) async =>
      throw TransportException('dify-sf has no message feedback yet', statusCode: 501, code: 'not_implemented');

  @override
  Future<void> deleteAnnotation(String appId, String annotationId) async => annotations?.delete(appId, annotationId);
}

/// Mock data in Dify's shapes: workflow runs (succeeded, failed, stopped, partial, running) with node executions,
/// chatflow conversations with messages, feedback and annotations. Filters, keyword, sort and paging behave like the
/// server's. Times are epoch seconds before [now].
class MockAppLogsSource implements AppLogsSource {
  MockAppLogsSource({DateTime? now, int workflowRuns = 23, int conversations = 14})
    : now = now ?? DateTime.now(),
      _runs = [],
      _conversations = [] {
    final base = this.now.millisecondsSinceEpoch ~/ 1000;
    const statuses = ['succeeded', 'succeeded', 'failed', 'succeeded', 'stopped', 'partial-succeeded', 'running'];
    const triggers = ['app-run', 'app-run', 'webhook', 'schedule', 'debugging', 'app-run', 'plugin'];
    for (var i = 0; i < workflowRuns; i++) {
      final status = statuses[i % statuses.length];
      final created = base - 3600 * 5 * i - 97 * i;
      final elapsed = status == 'running' ? 0.0 : 0.6 + (i * 0.731) % 9;
      final tokens = status == 'failed' ? 0 : 120 + (i * 137) % 2400;
      _runs.add({
        'id': 'log-$i',
        'workflow_run': {
          'id': 'run-$i',
          'version': 'draft',
          'status': status,
          'error': status == 'failed' ? 'Node LLM run failed: rate limit exceeded' : null,
          'elapsed_time': elapsed,
          'total_tokens': tokens,
          'total_price': tokens * 0.000002,
          'currency': 'USD',
          'total_steps': 3,
          'finished_at': status == 'running' ? null : created + elapsed.ceil(),
          'triggered_from': triggers[i % triggers.length],
        },
        'details': triggers[i % triggers.length] == 'plugin'
            ? {
                'trigger_metadata': {'event_name': 'Issue created'},
              }
            : null,
        'created_from': 'web-app',
        'created_by_role': i.isEven ? 'end_user' : 'account',
        'created_by_account': i.isEven ? null : {'id': 'account-1', 'name': 'Evan', 'email': 'evan@example.com'},
        'created_by_end_user': i.isEven
            ? {'id': 'end-user-$i', 'type': 'browser', 'is_anonymous': true, 'session_id': 'session-${1000 + i}'}
            : null,
        'created_at': created,
        'read_at': i % 3 == 0 ? null : created + 60,
      });
    }
    const titles = [
      'Summarize the quarterly report',
      'How do I reset my password?',
      'Translate this paragraph into French',
      'Draft a reply to the customer',
      'What is the refund policy?',
      'Plan a three-day trip to Kyoto',
      'Explain the error in my code',
    ];
    for (var i = 0; i < conversations; i++) {
      final created = base - 3600 * 7 * i - 61 * i;
      final count = 1 + (i * 3) % 5;
      final failed = i % 6 == 4 ? 1 : 0;
      _conversations.add({
        'id': 'conversation-$i',
        'status': 'normal',
        'from_source': 'api',
        'from_end_user_id': i.isEven ? 'end-user-$i' : null,
        'from_end_user_session_id': i.isEven ? 'session-${2000 + i}' : null,
        'from_account_id': i.isEven ? null : 'account-1',
        'from_account_name': i.isEven ? null : 'Evan',
        'name': titles[i % titles.length],
        'summary': titles[i % titles.length],
        'read_at': i % 4 == 0 ? null : created + 120,
        'created_at': created,
        'updated_at': created + 300 * count,
        'annotated': i % 5 == 1,
        'model_config': {'model': null, 'pre_prompt': null},
        'message_count': count,
        'user_feedback_stats': {'like': i % 3 == 0 ? 1 : 0, 'dislike': i % 7 == 2 ? 1 : 0},
        'admin_feedback_stats': {'like': i % 4 == 1 ? 1 : 0, 'dislike': 0},
        'status_count': {
          'paused': i == 3 ? 1 : 0,
          'success': count - failed,
          'failed': failed,
          'partial_success': i % 6 == 5 ? 1 : 0,
        },
      });
      _messages['conversation-$i'] = [
        for (var m = 0; m < count; m++)
          {
            'id': 'message-$i-$m',
            'conversation_id': 'conversation-$i',
            'parent_message_id': m == 0 ? null : 'message-$i-${m - 1}',
            'inputs': {'name': 'Evan', 'sys.query': m == 0 ? titles[i % titles.length] : 'Follow-up question $m'},
            'query': m == 0 ? titles[i % titles.length] : 'Follow-up question $m',
            'answer': m == 0
                ? 'Sure. Here is a short answer to **${titles[i % titles.length].toLowerCase()}**.'
                : 'Here is more detail on point $m.',
            'message': const <Json>[],
            'message_tokens': 40 + m,
            'answer_tokens': 120 + 7 * m,
            'provider_response_latency': 1.2 + m * 0.4,
            'created_at': created + 300 * m,
            'feedbacks': [
              if (m == 0 && i % 3 == 0) {'rating': 'like', 'content': null, 'from_source': 'user'},
              if (m == 0 && i % 4 == 1) {'rating': 'like', 'content': null, 'from_source': 'admin'},
            ],
            'workflow_run_id': 'chat-run-$i-$m',
            'annotation': null,
            'annotation_hit_history': null,
            'message_files': const <Json>[],
            'metadata': const <String, Object?>{},
            'agent_thoughts': const <Json>[],
            'status': 'normal',
          },
      ];
    }
  }

  final DateTime now;
  final List<Json> _runs;
  final List<Json> _conversations;
  final _messages = <String, List<Json>>{};

  /// The feedback bodies posted, in order.
  final feedbackCalls = <Json>[];

  /// The annotations deleted, in order.
  final deletedAnnotations = <String>[];

  @override
  Future<void> deleteAnnotation(String appId, String annotationId) async => deletedAnnotations.add(annotationId);

  static int _int(Object? v, int fallback) => switch (v) {
    final int i => i,
    final String s => int.tryParse(s) ?? fallback,
    _ => fallback,
  };

  static Json _paged(List<Json> all, Map<String, Object?> params) {
    final limit = _int(params['limit'], 10), page = _int(params['page'], 1);
    final start = (page - 1) * limit;
    final data = start >= all.length ? <Json>[] : all.sublist(start, (start + limit).clamp(0, all.length));
    return {'data': data, 'has_more': start + limit < all.length, 'limit': limit, 'total': all.length, 'page': page};
  }

  static int? _iso(Object? v) => v is String ? (DateTime.tryParse(v)?.millisecondsSinceEpoch ?? 0) ~/ 1000 : null;

  static int? _dayjs(Object? v) =>
      v is String ? (DateTime.tryParse(v.replaceFirst(' ', 'T'))?.millisecondsSinceEpoch ?? 0) ~/ 1000 : null;

  @override
  Future<Json> workflowLogs(String appId, Map<String, Object?> params) async {
    final status = params['status'], keyword = '${params['keyword'] ?? ''}'.toLowerCase();
    final after = _iso(params['created_at__after']), before = _iso(params['created_at__before']);
    final rows = [
      for (final r in _runs)
        if ((status == null || (r['workflow_run']! as Json)['status'] == status) &&
            (after == null || (r['created_at']! as int) >= after) &&
            (before == null || (r['created_at']! as int) <= before) &&
            (keyword.isEmpty || '${r['id']} ${r['workflow_run']}'.toLowerCase().contains(keyword)))
          r,
    ];
    return _paged(rows, params);
  }

  @override
  Future<Json> workflowRun(String appId, String runId) async {
    final log = _runs.firstWhere((r) => (r['workflow_run']! as Json)['id'] == runId, orElse: () => const {});
    final run = (log['workflow_run'] as Json?) ?? {'id': runId, 'status': 'succeeded'};
    final failed = run['status'] == 'failed';
    return {
      ...run,
      'sequence_number': 1,
      'graph': const {'nodes': <Json>[], 'edges': <Json>[]},
      'inputs': {'topic': 'Collaborative editing'},
      'outputs': failed ? null : {'text': 'Collaborative editing lets several people change one document at once.'},
      'created_by_role': log['created_by_role'] ?? 'account',
      'created_by_account': log['created_by_account'],
      'created_by_end_user': log['created_by_end_user'],
      'created_at': log['created_at'] ?? 0,
      'finished_at': run['finished_at'],
      'exceptions_count': run['status'] == 'partial-succeeded' ? 1 : 0,
    };
  }

  @override
  Future<List<Json>> nodeExecutions(String appId, String runId) async {
    final run = await workflowRun(appId, runId);
    final failed = run['status'] == 'failed';
    final created = (run['created_at'] as int?) ?? 0;
    Json node(
      int i,
      String id,
      String type,
      String title,
      String status,
      double elapsed, {
      Json? outputs,
      String? error,
    }) => {
      'id': '$runId-$id',
      'index': i,
      'predecessor_node_id': null,
      'node_id': id,
      'node_type': type,
      'title': title,
      'inputs': {'topic': 'Collaborative editing'},
      'process_data': null,
      'outputs': outputs,
      'status': status,
      'error': error,
      'elapsed_time': elapsed,
      'execution_metadata': type == 'llm'
          ? {'total_tokens': run['total_tokens'], 'total_price': run['total_price'], 'currency': 'USD'}
          : null,
      'extras': const <String, Object?>{},
      'created_at': created + i,
      'created_by_role': 'account',
      'finished_at': created + i + 1,
    };
    return [
      node(1, 'start', 'start', 'Start', 'succeeded', 0.012, outputs: {'topic': 'Collaborative editing'}),
      node(
        2,
        'llm',
        'llm',
        'LLM',
        failed ? 'failed' : 'succeeded',
        1.204,
        outputs: failed ? null : {'text': 'Collaborative editing lets several people change one document at once.'},
        error: failed ? 'rate limit exceeded' : null,
      ),
      if (!failed) node(3, 'end', 'end', 'End', 'succeeded', 0.004, outputs: run['outputs'] as Json?),
    ];
  }

  @override
  Future<Json> chatConversations(String appId, Map<String, Object?> params) async {
    final keyword = '${params['keyword'] ?? ''}'.toLowerCase(), annotation = params['annotation_status'];
    final start = _dayjs(params['start']), end = _dayjs(params['end']);
    final rows = [
      for (final c in _conversations)
        if ((start == null || (c['created_at']! as int) >= start) &&
            (end == null || (c['created_at']! as int) <= end + 59) &&
            (annotation == null || annotation == 'all' || (annotation == 'annotated') == (c['annotated'] == true)) &&
            (keyword.isEmpty || '${c['name']}'.toLowerCase().contains(keyword)))
          c,
    ];
    final sortBy = '${params['sort_by'] ?? '-created_at'}';
    final field = sortBy.replaceFirst('-', ''), desc = sortBy.startsWith('-');
    rows.sort((a, b) {
      final r = (a[field]! as int).compareTo(b[field]! as int);
      return desc ? -r : r;
    });
    return _paged(rows, params);
  }

  @override
  Future<Json> chatConversation(String appId, String conversationId) async {
    final c = _conversations.firstWhere((c) => c['id'] == conversationId, orElse: () => {'id': conversationId});
    final first = _messages[conversationId]?.firstOrNull;
    return {
      ...c,
      'model_config': {
        'model': null,
        'configs': {'introduction': ''},
        'user_input_form': [
          {
            'text-input': {'variable': 'name', 'label': 'Name'},
          },
        ],
      },
      'message': {'inputs': first?['inputs'] ?? const <String, Object?>{}},
    };
  }

  @override
  Future<Json> chatMessages(String appId, Map<String, Object?> params) async {
    final all = _messages['${params['conversation_id']}'] ?? const [];
    final limit = _int(params['limit'], 10);
    final firstId = params['first_id'];
    var end = all.length;
    if (firstId != null) {
      final i = all.indexWhere((m) => m['id'] == firstId);
      end = i < 0 ? 0 : i;
    }
    final start = (end - limit).clamp(0, end);
    return {'data': all.sublist(start, end), 'has_more': start > 0, 'limit': limit};
  }

  @override
  Future<Json> annotationsCount(String appId) async => {
    'count': _conversations.where((c) => c['annotated'] == true).length,
  };

  @override
  Future<void> updateFeedback(String appId, Json body) async {
    feedbackCalls.add(body);
    for (final list in _messages.values) {
      for (final m in list) {
        if (m['id'] != body['message_id']) continue;
        final feedbacks = [
          for (final f in (m['feedbacks'] as List? ?? const []).cast<Json>())
            if (f['from_source'] != 'admin') f,
          if (body['rating'] != null) {'rating': body['rating'], 'content': body['content'], 'from_source': 'admin'},
        ];
        m['feedbacks'] = feedbacks;
      }
    }
  }
}

/// [AppInfo.json]'s `site` (Dify's `AppDetailWithSite.site`), when the server sends it.
Json? appSite(AppInfo app) => switch (app.json['site']) {
  final Json site => site,
  _ => null,
};
