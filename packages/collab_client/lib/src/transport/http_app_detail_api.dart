import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../files_api.dart';

import '../access_api.dart';
import '../agent_composer_api.dart';
import '../annotations_api.dart';
import '../apps_api.dart';
import '../auth/auth_api.dart';
import '../auth/auth_session.dart';
import '../client/replace.dart';
import '../client/transport.dart';
import '../monitor_api.dart';
import '../versions_api.dart';
import '../workflow_run_api.dart';
import 'sse_parser.dart';

/// The app detail pages' APIs (protocol 1.11) against a real server at [baseUrl]: [HttpAccessApi], [HttpAnnotationsApi],
/// [HttpVersionsApi], [HttpStatsApi], [HttpLogsApi]. Pass the signed-in user's `auth`: every request carries its bearer
/// token (refreshed once on a `401`).
abstract class HttpConsoleApi {
  HttpConsoleApi(
    this.baseUrl, {
    http.Client? client,
    TokenProvider? auth,
    this.timeout = const Duration(seconds: 20),
  }) : _client = auth == null ? (client ?? http.Client()) : AuthenticatedClient(client ?? http.Client(), auth);

  final Uri baseUrl;

  /// Per request.
  final Duration timeout;
  final http.Client _client;

  String get _basePath =>
      baseUrl.path.endsWith('/') ? baseUrl.path.substring(0, baseUrl.path.length - 1) : baseUrl.path;

  Uri _url(String path, [Map<String, List<String>>? query]) => baseUrl.replace(
    path: '$_basePath$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  static String _app(String id) => '/v1/apps/${Uri.encodeComponent(id)}';
  static String _seg(String s) => Uri.encodeComponent(s);

  static Map<String, Object?> _map(Object? json) =>
      json is Map<String, Object?> ? json : throw const TransportException('malformed answer: not an object');

  static List<Map<String, Object?>> _data(Object? json) {
    final m = _map(json);
    final d = m['data'];
    if (d is! List<Object?>) {
      throw const TransportException('malformed answer: no data');
    }
    return [
      for (final x in d)
        if (x is Map<String, Object?>) x,
    ];
  }

  Future<({int status, String text, Object? json})> _send(
    String method,
    String path, {
    required List<int> ok,
    Map<String, Object?>? body,
    Map<String, List<String>>? query,
    http.BaseRequest? request,
  }) async {
    final http.BaseRequest req;
    if (request != null) {
      req = request;
    } else {
      final r = http.Request(method, _url(path, query));
      if (body != null) {
        r
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
      }
      req = r;
    }
    final http.Response res;
    try {
      // `send` is awaited **outside** `Response.fromStream`: the stream is read in this zone, where the client's own
      // socket handling (and a test's `runAsync`) runs, instead of in whatever zone `.fromStream` was created in.
      final streamed = await _client.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw TransportException('$method $path timed out', timeout: true);
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (!ok.contains(res.statusCode)) {
      throw transportErrorOf(res.statusCode, text);
    }
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) {
      return (status: res.statusCode, text: text, json: null);
    }
    try {
      return (status: res.statusCode, text: text, json: jsonDecode(text));
    } on FormatException catch (e) {
      if (res.statusCode >= 400) throw transportErrorOf(res.statusCode, text);
      throw TransportException(
        'malformed answer to $method $path: ${e.message}',
      );
    }
  }

  void close() => _client.close();
}

/// [AccessApi] against a real server (protocol 1.11).
class HttpAccessApi extends HttpConsoleApi implements AccessApi {
  HttpAccessApi(super.baseUrl, {super.client, super.auth, super.timeout});

  @override
  Future<AppSite> updateSite(String appId, AppSiteUpdate update) async => AppSite.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/site',
        ok: const [200],
        body: update.toJson(),
      )).json,
    ),
  );

  @override
  Future<AppSite> resetAccessToken(String appId) async => AppSite.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/site/access-token-reset',
        ok: const [200],
      )).json,
    ),
  );

  @override
  Future<AppInfo> setSiteEnabled(String appId, bool enable) async => AppInfo.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/site-enable',
        ok: const [200],
        body: {'enable_site': enable},
      )).json,
    ),
  );

  @override
  Future<AppInfo> setApiEnabled(String appId, bool enable) async => AppInfo.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/api-enable',
        ok: const [200],
        body: {'enable_api': enable},
      )).json,
    ),
  );

  @override
  Future<List<AppApiKey>> listApiKeys(String appId) async => [
    for (final m in HttpConsoleApi._data(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/api-keys',
        ok: const [200],
      )).json,
    ))
      AppApiKey.fromJson(m),
  ];

  @override
  Future<AppApiKey> createApiKey(String appId) async => AppApiKey.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/api-keys',
        ok: const [201, 200],
      )).json,
    ),
  );

  @override
  Future<void> deleteApiKey(String appId, String keyId) => _send(
    'DELETE',
    '${HttpConsoleApi._app(appId)}/api-keys/${HttpConsoleApi._seg(keyId)}',
    ok: const [204, 200],
  );
}

/// [AnnotationsApi] against a real server (protocol 1.11).
class HttpAnnotationsApi extends HttpConsoleApi implements AnnotationsApi {
  HttpAnnotationsApi(super.baseUrl, {super.client, super.auth, super.timeout});

  String _a(String appId) => '${HttpConsoleApi._app(appId)}/annotations';

  @override
  Future<AnnotationPage> list(
    String appId, {
    int page = 1,
    int limit = 20,
    String keyword = '',
  }) async => AnnotationPage.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        _a(appId),
        ok: const [200],
        query: {
          'page': ['$page'],
          'limit': ['$limit'],
          if (keyword.isNotEmpty) 'keyword': [keyword],
        },
      )).json,
    ),
  );

  @override
  Future<int> count(String appId) async {
    final m = HttpConsoleApi._map(
      (await _send('GET', '${_a(appId)}/count', ok: const [200])).json,
    );
    return m['count'] is num ? (m['count']! as num).toInt() : 0;
  }

  @override
  Future<List<Annotation>> export(String appId) async => [
    for (final m in HttpConsoleApi._data(
      (await _send('GET', '${_a(appId)}/export', ok: const [200])).json,
    ))
      Annotation.fromJson(m),
  ];

  @override
  Future<Annotation> create(
    String appId, {
    required String question,
    required String answer,
  }) async => Annotation.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        _a(appId),
        ok: const [201, 200],
        body: {'question': question, 'answer': answer},
      )).json,
    ),
  );

  @override
  Future<Annotation> update(
    String appId,
    String annotationId, {
    required String question,
    required String answer,
  }) async => Annotation.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${_a(appId)}/${HttpConsoleApi._seg(annotationId)}',
        ok: const [200],
        body: {'question': question, 'answer': answer},
      )).json,
    ),
  );

  @override
  Future<void> delete(String appId, String annotationId) => _send(
    'DELETE',
    '${_a(appId)}/${HttpConsoleApi._seg(annotationId)}',
    ok: const [204, 200],
  );

  @override
  Future<void> deleteMany(String appId, List<String> annotationIds) async {
    if (annotationIds.isEmpty) return;
    await _send(
      'DELETE',
      _a(appId),
      ok: const [204, 200],
      query: {'annotation_id': annotationIds},
    );
  }

  @override
  Future<void> clearAll(String appId) => _send('DELETE', _a(appId), ok: const [204, 200]);

  /// The upload is a `multipart/form-data` body built here as a plain request (so a `401` refresh can replay it).
  @override
  Future<AnnotationJob> batchImport(
    String appId,
    List<int> csvBytes, {
    String filename = 'annotations.csv',
  }) async {
    final boundary = 'dify-sf-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final safeName = filename.replaceAll('"', '_').replaceAll('\r', '').replaceAll('\n', '');
    final body = <int>[
      ...utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$safeName"\r\n'
        'Content-Type: text/csv\r\n\r\n',
      ),
      ...csvBytes,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final req = http.Request('POST', _url('${_a(appId)}/batch-import'))
      ..headers['Content-Type'] = 'multipart/form-data; boundary=$boundary'
      ..bodyBytes = body;
    return AnnotationJob.fromJson(
      HttpConsoleApi._map(
        (await _send(
          'POST',
          '${_a(appId)}/batch-import',
          ok: const [200],
          request: req,
        )).json,
      ),
    );
  }

  @override
  Future<AnnotationJob> batchImportStatus(String appId, String jobId) async => AnnotationJob.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${_a(appId)}/batch-import-status/${HttpConsoleApi._seg(jobId)}',
        ok: const [200],
      )).json,
    ),
  );

  @override
  Future<AnnotationSetting> setting(String appId) async => AnnotationSetting.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/annotation-setting',
        ok: const [200],
      )).json,
    ),
  );

  @override
  Future<AnnotationJob> enableReply(
    String appId, {
    required double scoreThreshold,
    required String embeddingProviderName,
    required String embeddingModelName,
  }) async => AnnotationJob.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/annotation-reply/enable',
        ok: const [200],
        body: {
          'score_threshold': scoreThreshold,
          'embedding_provider_name': embeddingProviderName,
          'embedding_model_name': embeddingModelName,
        },
      )).json,
    ),
  );

  @override
  Future<AnnotationJob> disableReply(String appId) async => AnnotationJob.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/annotation-reply/disable',
        ok: const [200],
        body: const {},
      )).json,
    ),
  );

  @override
  Future<AnnotationJob> replyStatus(
    String appId,
    String action,
    String jobId,
  ) async => AnnotationJob.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/annotation-reply/${HttpConsoleApi._seg(action)}/status/${HttpConsoleApi._seg(jobId)}',
        ok: const [200],
      )).json,
    ),
  );

  @override
  Future<AnnotationSetting> updateSetting(
    String appId,
    String settingId, {
    required double scoreThreshold,
  }) async => AnnotationSetting.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${HttpConsoleApi._app(appId)}/annotation-settings/${HttpConsoleApi._seg(settingId)}',
        ok: const [200],
        body: {'score_threshold': scoreThreshold},
      )).json,
    ),
  );

  @override
  Future<AnnotationHitHistoryPage> hitHistories(
    String appId,
    String annotationId, {
    int page = 1,
    int limit = 20,
  }) async => AnnotationHitHistoryPage.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${_a(appId)}/${HttpConsoleApi._seg(annotationId)}/hit-histories',
        ok: const [200],
        query: {
          'page': ['$page'],
          'limit': ['$limit'],
        },
      )).json,
    ),
  );
}

/// [VersionsApi] against a real server (protocol 1.11).
class HttpVersionsApi extends HttpConsoleApi implements VersionsApi {
  HttpVersionsApi(super.baseUrl, {super.client, super.auth, super.timeout});

  String _w(String appId) => '${HttpConsoleApi._app(appId)}/workflows';

  @override
  Future<WorkflowVersion?> published(String appId) async {
    final json = (await _send(
      'GET',
      '${_w(appId)}/publish',
      ok: const [200],
    )).json;
    return json is Map<String, Object?> ? WorkflowVersion.fromJson(json) : null;
  }

  @override
  Future<PublishResult> publish(
    String appId, {
    String? markedName,
    String? markedComment,
  }) async => PublishResult.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${_w(appId)}/publish',
        ok: const [200, 201],
        body: {'marked_name': ?markedName, 'marked_comment': ?markedComment},
      )).json,
    ),
  );

  @override
  Future<WorkflowVersionPage> list(
    String appId, {
    int page = 1,
    int limit = 10,
    String? userId,
    bool namedOnly = false,
  }) async => WorkflowVersionPage.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        _w(appId),
        ok: const [200],
        query: {
          'page': ['$page'],
          'limit': ['$limit'],
          if (userId != null && userId.isNotEmpty) 'user_id': [userId],
          if (namedOnly) 'named_only': ['true'],
        },
      )).json,
    ),
  );

  @override
  Future<WorkflowVersion> get(String appId, String versionId) async => WorkflowVersion.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${_w(appId)}/${HttpConsoleApi._seg(versionId)}',
        ok: const [200],
      )).json,
    ),
  );

  @override
  Future<String> exportDsl(
    String appId,
    String versionId, {
    bool includeSecret = false,
  }) async {
    final json = HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/export',
        ok: const [200],
        query: {
          'include_secret': ['$includeSecret'],
          'workflow_id': [versionId],
        },
      )).json,
    );
    final data = json['data'];
    if (data is! String) {
      throw const TransportException('malformed answer: no data');
    }
    return data;
  }

  @override
  Future<WorkflowVersion> update(
    String appId,
    String versionId, {
    String? markedName,
    String? markedComment,
  }) async => WorkflowVersion.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'PATCH',
        '${_w(appId)}/${HttpConsoleApi._seg(versionId)}',
        ok: const [200],
        body: {'marked_name': ?markedName, 'marked_comment': ?markedComment},
      )).json,
    ),
  );

  @override
  Future<void> delete(String appId, String versionId) => _send(
    'DELETE',
    '${_w(appId)}/${HttpConsoleApi._seg(versionId)}',
    ok: const [204, 200],
  );

  @override
  Future<ReplaceResult> restore(
    String appId,
    String versionId,
    String clientId, {
    required int cseq,
  }) async => ReplaceResult.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'POST',
        '${_w(appId)}/${HttpConsoleApi._seg(versionId)}/restore',
        ok: const [200],
        body: {'client': clientId, 'cseq': cseq},
      )).json,
    ),
  );
}

/// [StatsApi] against a real server (protocol 1.11).
class HttpStatsApi extends HttpConsoleApi implements StatsApi {
  HttpStatsApi(super.baseUrl, {super.client, super.auth, super.timeout});

  @override
  Future<List<StatisticRow>> statistic(
    String appId,
    AppStatistic stat, {
    String? start,
    String? end,
  }) async => [
    for (final m in HttpConsoleApi._data(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/${stat.path}',
        ok: const [200],
        query: {
          if (start != null && start.isNotEmpty) 'start': [start],
          if (end != null && end.isNotEmpty) 'end': [end],
        },
      )).json,
    ))
      StatisticRow.fromJson(m, stat.valueKey),
  ];
}

/// [LogsApi] against a real server (protocol 1.11).
class HttpLogsApi extends HttpConsoleApi implements LogsApi {
  HttpLogsApi(super.baseUrl, {super.client, super.auth, super.timeout});

  @override
  Future<WorkflowLogPage> workflowLogs(
    String appId, [
    WorkflowLogQuery query = const WorkflowLogQuery(),
  ]) async => WorkflowLogPage.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/workflow-app-logs',
        ok: const [200],
        query: query.toQuery(),
      )).json,
    ),
  );

  @override
  Future<Map<String, Object?>> workflowRun(
    String appId,
    String runId,
  ) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/workflow-runs/${HttpConsoleApi._seg(runId)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<List<Map<String, Object?>>> workflowRunNodeExecutions(
    String appId,
    String runId,
  ) async => HttpConsoleApi._data(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/workflow-runs/${HttpConsoleApi._seg(runId)}/node-executions',
      ok: const [200],
    )).json,
  );

  @override
  Future<ChatConversationPage> chatConversations(
    String appId, [
    ChatConversationQuery query = const ChatConversationQuery(),
  ]) async => ChatConversationPage.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/chat-conversations',
        ok: const [200],
        query: query.toQuery(),
      )).json,
    ),
  );

  @override
  Future<Map<String, Object?>> chatConversation(
    String appId,
    String conversationId,
  ) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/chat-conversations/${HttpConsoleApi._seg(conversationId)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<ChatMessagePage> chatMessages(
    String appId,
    String conversationId, {
    String? firstId,
    int limit = 20,
  }) async => ChatMessagePage.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/chat-messages',
        ok: const [200],
        query: {
          'conversation_id': [conversationId],
          if (firstId != null && firstId.isNotEmpty) 'first_id': [firstId],
          'limit': ['$limit'],
        },
      )).json,
    ),
  );

  @override
  Future<void> updateFeedback(
    String appId, {
    required String messageId,
    String? rating,
    String? content,
  }) async => _send(
    'POST',
    '${HttpConsoleApi._app(appId)}/feedbacks',
    ok: const [200],
    body: {'message_id': messageId, 'rating': rating, 'content': content},
  );
}

/// [WorkflowRunApi] against a real server (protocol 1.13). A single run waits for the model, so the default per-request
/// timeout is 10 minutes (the server's plugin daemon bound) instead of the console's 20 seconds.
class HttpWorkflowRunApi extends HttpConsoleApi implements WorkflowRunApi {
  HttpWorkflowRunApi(
    super.baseUrl, {
    super.client,
    super.auth,
    super.timeout = const Duration(minutes: 10),
  });

  String _node(String appId, String nodeId) =>
      '${HttpConsoleApi._app(appId)}/workflows/draft/nodes/${HttpConsoleApi._seg(nodeId)}';

  @override
  Future<Map<String, Object?>> singleNodeRun(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  ) async => HttpConsoleApi._map(
    (await _send(
      'POST',
      '${_node(appId, nodeId)}/run',
      ok: const [200],
      body: body,
    )).json,
  );

  @override
  Future<Map<String, Object?>?> nodeLastRun(String appId, String nodeId) async {
    try {
      return HttpConsoleApi._map(
        (await _send(
          'GET',
          '${_node(appId, nodeId)}/last-run',
          ok: const [200],
        )).json,
      );
    } on TransportException catch (e) {
      if (e.statusCode == 404 && e.code == 'not_found') return null;
      rethrow;
    }
  }

  @override
  Stream<Map<String, Object?>> chatDraftRun(
    String appId,
    Map<String, Object?> body,
  ) => _runStream(
    '${HttpConsoleApi._app(appId)}/advanced-chat/workflows/draft/run',
    body,
  );

  @override
  Future<void> stopChatRun(String appId, String taskId) async => _send(
    'POST',
    '${HttpConsoleApi._app(appId)}/chat-messages/${HttpConsoleApi._seg(taskId)}/stop',
    ok: const [200],
  );

  Future<List<Map<String, Object?>>> _chatList(
    String path,
    String conversationId,
  ) async {
    final response = HttpConsoleApi._map(
      (await _send(
        'GET',
        path,
        ok: const [200],
        query: {
          'conversation_id': [conversationId],
        },
      )).json,
    );
    return [
      for (final item in response['data'] as List? ?? const [])
        if (item is Map<String, Object?>) item,
    ];
  }

  @override
  Future<List<Map<String, Object?>>> chatMessages(
    String appId,
    String conversationId,
  ) => _chatList('${HttpConsoleApi._app(appId)}/chat-messages', conversationId);

  @override
  Future<List<Map<String, Object?>>> conversationVariables(
    String appId,
    String conversationId,
  ) => _chatList(
    '${HttpConsoleApi._app(appId)}/advanced-chat/workflows/draft/conversation-variables',
    conversationId,
  );

  String _draft(String appId) => '${HttpConsoleApi._app(appId)}/workflows/draft';

  /// The SSE stream of a draft run: the response head within [timeout], then frames for as long as the run lasts.
  @override
  Stream<Map<String, Object?>> draftRun(
    String appId,
    Map<String, Object?> body,
  ) => _runStream('${_draft(appId)}/run', body);

  @override
  Stream<Map<String, Object?>> iterationSingleRun(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  ) => _runStream(
    '${_draft(appId)}/iteration/nodes/${HttpConsoleApi._seg(nodeId)}/run',
    body,
  );

  @override
  Stream<Map<String, Object?>> loopSingleRun(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  ) => _runStream(
    '${_draft(appId)}/loop/nodes/${HttpConsoleApi._seg(nodeId)}/run',
    body,
  );

  Stream<Map<String, Object?>> _runStream(
    String path,
    Map<String, Object?> body,
  ) async* {
    final req = http.Request('POST', _url(path))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode(body);
    yield* _frames(req, 'POST', path);
  }

  /// `sseGet` (`service/base.ts`): a GET stream (`Accept: text/event-stream`), the same frames.
  Stream<Map<String, Object?>> _getStream(
    String path,
    Map<String, List<String>> query,
  ) async* {
    final req = http.Request('GET', _url(path, query))..headers['Accept'] = 'text/event-stream';
    yield* _frames(req, 'GET', path);
  }

  Stream<Map<String, Object?>> _frames(
    http.Request req,
    String method,
    String path,
  ) async* {
    final http.StreamedResponse res;
    try {
      res = await _client.send(req).timeout(timeout);
    } on TimeoutException {
      throw TransportException('$method $path timed out', timeout: true);
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    if (res.statusCode != 200) {
      final text = utf8.decode(
        await res.stream.toBytes(),
        allowMalformed: true,
      );
      throw transportErrorOf(res.statusCode, text);
    }
    final parser = SseParser();
    try {
      await for (final chunk in res.stream.cast<List<int>>().transform(
        utf8.decoder,
      )) {
        for (final m in parser.add(chunk)) {
          if (m.event != 'message') continue; // `event: ping`
          final Object? json;
          try {
            json = jsonDecode(m.data);
          } on FormatException {
            continue;
          }
          if (json is Map<String, Object?>) yield json;
        }
      }
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      // The connection died mid-stream (a server that restarts closes it): the same `TransportException` a refused
      // connection gives, so the stream's callers have one failure to reason about instead of a raw socket error.
      throw TransportException('$method $path ended: $e');
    }
  }

  @override
  Future<void> stopRun(String appId, String taskId) async => _send(
    'POST',
    '${HttpConsoleApi._app(appId)}/workflow-runs/tasks/${HttpConsoleApi._seg(taskId)}/stop',
    ok: const [200],
  );

  @override
  Future<Map<String, Object?>> runHistory(
    String appId, {
    String? lastId,
    int limit = 20,
  }) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/workflow-runs',
      ok: const [200],
      query: {
        'limit': ['$limit'],
        if (lastId != null && lastId.isNotEmpty) 'last_id': [lastId],
      },
    )).json,
  );

  @override
  Future<Map<String, Object?>> runDetail(
    String appId,
    String runId,
  ) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/workflow-runs/${HttpConsoleApi._seg(runId)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<List<Map<String, Object?>>> runNodeExecutions(
    String appId,
    String runId,
  ) async => HttpConsoleApi._data(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/workflow-runs/${HttpConsoleApi._seg(runId)}/node-executions',
      ok: const [200],
    )).json,
  );

  static List<Map<String, Object?>> _items(Object? json) {
    final items = HttpConsoleApi._map(json)['items'];
    if (items is! List<Object?>) {
      throw const TransportException('malformed answer: no items');
    }
    return [
      for (final x in items)
        if (x is Map<String, Object?>) x,
    ];
  }

  @override
  Future<Map<String, Object?>> draftVariables(
    String appId, {
    int page = 1,
    int limit = 20,
  }) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${_draft(appId)}/variables',
      ok: const [200],
      query: {
        'page': ['$page'],
        'limit': ['$limit'],
      },
    )).json,
  );

  @override
  Future<List<Map<String, Object?>>> nodeVariables(
    String appId,
    String nodeId,
  ) async => _items(
    (await _send(
      'GET',
      '${_draft(appId)}/nodes/${HttpConsoleApi._seg(nodeId)}/variables',
      ok: const [200],
    )).json,
  );

  @override
  Future<List<Map<String, Object?>>> draftVariablesOfKind(
    String appId,
    String kind,
  ) async {
    if (!const {'conversation', 'system', 'environment'}.contains(kind)) {
      throw ArgumentError.value(
        kind,
        'kind',
        'conversation, system or environment',
      );
    }
    return _items(
      (await _send(
        'GET',
        '${_draft(appId)}/$kind-variables',
        ok: const [200],
      )).json,
    );
  }

  @override
  Future<Map<String, Object?>> draftVariable(
    String appId,
    String variableId,
  ) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${_draft(appId)}/variables/${HttpConsoleApi._seg(variableId)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<Map<String, Object?>> updateDraftVariable(
    String appId,
    String variableId,
    Map<String, Object?> patch,
  ) async => HttpConsoleApi._map(
    (await _send(
      'PATCH',
      '${_draft(appId)}/variables/${HttpConsoleApi._seg(variableId)}',
      ok: const [200],
      body: patch,
    )).json,
  );

  @override
  Future<Map<String, Object?>?> resetDraftVariable(
    String appId,
    String variableId,
  ) async {
    final r = await _send(
      'PUT',
      '${_draft(appId)}/variables/${HttpConsoleApi._seg(variableId)}/reset',
      ok: const [200, 204],
    );
    return r.status == 204 ? null : HttpConsoleApi._map(r.json);
  }

  @override
  Future<void> deleteDraftVariables(
    String appId, {
    String? variableId,
    String? nodeId,
  }) async {
    final path = variableId != null
        ? '${_draft(appId)}/variables/${HttpConsoleApi._seg(variableId)}'
        : nodeId != null
        ? '${_draft(appId)}/nodes/${HttpConsoleApi._seg(nodeId)}/variables'
        : '${_draft(appId)}/variables';
    await _send('DELETE', path, ok: const [200, 204]);
  }

  // ---- human input (1.16) ----

  @override
  Future<Map<String, Object?>> humanInputForm(String token) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '/v1/form/human_input/${HttpConsoleApi._seg(token)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<void> submitHumanInputForm(
    String token,
    Map<String, Object?> body,
  ) async => _send(
    'POST',
    '/v1/form/human_input/${HttpConsoleApi._seg(token)}',
    ok: const [200],
    body: body,
  );

  /// `sseGet`: the response head within [timeout], then frames for as long as the run lasts (a paused run with
  /// `continue_on_pause` holds the connection open).
  @override
  Stream<Map<String, Object?>> workflowEvents(
    String runId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  }) => _getStream('/v1/workflow/${HttpConsoleApi._seg(runId)}/events', {
    'include_state_snapshot': ['$includeStateSnapshot'],
    'continue_on_pause': ['$continueOnPause'],
  });

  @override
  Future<void> humanInputDeliveryTest(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  ) async => _send(
    'POST',
    '${_draft(appId)}/human-input/nodes/${HttpConsoleApi._seg(nodeId)}/delivery-test',
    ok: const [200],
    body: body,
  );

  @override
  Future<Map<String, Object?>> humanInputFormPreview(
    String url,
    Map<String, Object?> body,
  ) async => HttpConsoleApi._map(
    (await _send('POST', '/v1$url/preview', ok: const [200], body: body)).json,
  );

  @override
  Future<Map<String, Object?>> humanInputFormRun(
    String url,
    Map<String, Object?> body,
  ) async => HttpConsoleApi._map(
    (await _send('POST', '/v1$url/run', ok: const [200], body: body)).json,
  );
}

class HttpFilesApi extends HttpConsoleApi implements FilesApi {
  HttpFilesApi(
    super.baseUrl, {
    super.client,
    super.auth,
    super.timeout = const Duration(seconds: 120),
  });

  @override
  Future<FileUploadLimits> limits() async => FileUploadLimits.fromJson(
    HttpConsoleApi._map(
      (await _send('GET', '/v1/files/upload', ok: const [200])).json,
    ),
  );

  @override
  Future<UploadedFile> upload(
    List<int> bytes, {
    required String filename,
    String? mimeType,
  }) async {
    final multipart = http.MultipartRequest('POST', _url('/v1/files/upload'))
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: mimeType == null ? null : MediaType.parse(mimeType),
        ),
      );
    // AuthenticatedClient replays a plain Request, not a consumed MultipartRequest stream.
    final payload = await multipart.finalize().toBytes();
    final request = http.Request('POST', multipart.url)
      ..headers.addAll(multipart.headers)
      ..bodyBytes = payload;
    return UploadedFile.fromJson(
      HttpConsoleApi._map(
        (await _send(
          'POST',
          '/v1/files/upload',
          ok: const [201],
          request: request,
        )).json,
      ),
    );
  }

  @override
  Future<String> textPreview(String fileId) async {
    final body = HttpConsoleApi._map(
      (await _send(
        'GET',
        '/v1/files/${HttpConsoleApi._seg(fileId)}/preview',
        ok: const [200],
      )).json,
    );
    final content = body['content'];
    if (content is! String) {
      throw const TransportException('malformed file preview');
    }
    return content;
  }
}

/// Published app transport. Its passport is a visitor credential, isolated from
/// AuthSession and console refresh. Existing SSE parsing and file transport are
/// reused, with only the public paths and audience changed.
class HttpPublicAppApi extends HttpWorkflowRunApi implements FilesApi {
  factory HttpPublicAppApi(
    Uri server, {
    required String code,
    String? passport,
    http.Client? client,
  }) {
    final scoped = _PublicAppClient(client ?? http.Client(), code, passport);
    return HttpPublicAppApi._(server, scoped);
  }
  HttpPublicAppApi._(super.baseUrl, this._publicClient) : super(client: _publicClient);
  final _PublicAppClient _publicClient;
  String? get passport => _publicClient.passport;

  Future<String> establishPassport() async {
    Map<String, Object?> value;
    try {
      value = HttpConsoleApi._map(
        (await _send('GET', '/v1/passport', ok: const [200])).json,
      );
    } on TransportException catch (e) {
      if (e.statusCode != 401 || _publicClient.passport == null) rethrow;
      _publicClient.passport = null;
      value = HttpConsoleApi._map(
        (await _send('GET', '/v1/passport', ok: const [200])).json,
      );
    }
    final token = value['access_token'];
    if (token is! String || token.isEmpty) {
      throw const TransportException('Missing visitor passport');
    }
    return _publicClient.passport = token;
  }

  Future<Map<String, Object?>> definition() async => HttpConsoleApi._map(
    (await _send('GET', '/v1/site', ok: const [200])).json,
  );
  Stream<Map<String, Object?>> runPublished(
    Map<String, Object?> body, {
    bool chat = false,
  }) => _runStream(chat ? '/v1/chat-messages' : '/v1/workflows/run', {
    ...body,
    'response_mode': 'streaming',
  });
  Future<void> stopPublished(String taskId, {bool chat = false}) async => _send(
    'POST',
    chat
        ? '/v1/chat-messages/${HttpConsoleApi._seg(taskId)}/stop'
        : '/v1/workflows/tasks/${HttpConsoleApi._seg(taskId)}/stop',
    ok: const [200],
    body: const {},
  );
  Future<List<Map<String, Object?>>> publicConversations() async => HttpConsoleApi._data(
    (await _send('GET', '/v1/conversations', ok: const [200])).json,
  );

  /// The public protocol returns each page in chronological order. The shared
  /// runner consumes newest-first history, so normalize only at this boundary.
  Future<List<Map<String, Object?>>> publicMessages(String conversationId) async {
    final values = <Map<String, Object?>>[];
    String? first;
    while (true) {
      final page = HttpConsoleApi._map(
        (await _send(
          'GET',
          '/v1/messages',
          ok: const [200],
          query: {
            'conversation_id': [conversationId],
            'limit': ['100'],
            if (first != null) 'first_id': [first],
          },
        )).json,
      );
      final rows = HttpConsoleApi._data(page);
      values.addAll(rows.reversed);
      if (page['has_more'] != true || rows.isEmpty) return values;
      final next = rows.first['id'];
      if (next is! String || next.isEmpty || next == first) {
        throw const TransportException('Invalid message history cursor');
      }
      first = next;
    }
  }

  Future<Map<String, Object?>> publishedRun(String id) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '/v1/workflows/run/${HttpConsoleApi._seg(id)}',
      ok: const [200],
    )).json,
  );
  @override
  Future<FileUploadLimits> limits() async => FileUploadLimits.fromJson(
    HttpConsoleApi._map(
      (await _send('GET', '/v1/files/upload', ok: const [200])).json,
    ),
  );
  @override
  Future<UploadedFile> upload(
    List<int> bytes, {
    required String filename,
    String? mimeType,
  }) async {
    final request = http.MultipartRequest('POST', _url('/v1/files/upload'))
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    return UploadedFile.fromJson(
      HttpConsoleApi._map(
        (await _send(
          'POST',
          '/v1/files/upload',
          ok: const [201],
          request: request,
        )).json,
      ),
    );
  }

  @override
  Future<String> textPreview(String fileId) async {
    final body = HttpConsoleApi._map(
      (await _send('GET', '/v1/files/${HttpConsoleApi._seg(fileId)}/preview', ok: const [200])).json,
    );
    if (body['content'] is! String) throw const TransportException('Malformed file preview');
    return body['content']! as String;
  }
}

class _PublicAppClient extends http.BaseClient {
  _PublicAppClient(this.client, this.code, this.passport);
  final http.Client client;
  final String code;
  String? passport;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['X-App-Code'] = code;
    final token = passport;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    return client.send(request);
  }

  @override
  void close() => client.close();
}

/// Inline workflow Agent v2 composer, using the same authentication refresh and error projection as console APIs.
class HttpAgentComposerApi extends HttpConsoleApi implements AgentComposerApi, AgentClipboardApi, AgentExecutorProfilesApi {
  HttpAgentComposerApi(super.baseUrl, {super.client, super.auth, super.timeout});

  @override
  Future<Map<String, Object?>> agentExecutorProfiles(String appId) async => HttpConsoleApi._map(
    (await _send('GET', '${HttpConsoleApi._app(appId)}/agent-executor-profiles', ok: const [200])).json);

  @override
  Future<Map<String, Object?>> exportAgentClipboard(String appId, Map<String, Object?> body) async => HttpConsoleApi._map(
    (await _send('POST', '${HttpConsoleApi._app(appId)}/workflows/draft/agent-clipboard/export', ok: const [200], body: body)).json);

  @override
  Future<Map<String, Object?>> pasteAgentClipboard(String appId, Map<String, Object?> body) async => HttpConsoleApi._map(
    (await _send('POST', '${HttpConsoleApi._app(appId)}/workflows/draft/agent-clipboard/paste', ok: const [200], body: body)).json);

  static String _path(String app, String node) =>
      '${HttpConsoleApi._app(app)}/workflows/draft/nodes/${HttpConsoleApi._seg(node)}/agent-composer';

  @override
  Future<Map<String, Object?>> readInlineAgent(
    String appId,
    String nodeId, {
    String? snapshotId,
    String? agentId,
  }) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      _path(appId, nodeId),
      ok: const [200],
      query: {
        if (snapshotId != null) 'snapshot_id': [snapshotId],
        if (agentId != null) 'agent_id': [agentId],
      },
    )).json,
  );

  @override
  Future<Map<String, Object?>> saveInlineAgent(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  ) async => HttpConsoleApi._map(
    (await _send(
      'PUT',
      _path(appId, nodeId),
      ok: const [200],
      body: body,
    )).json,
  );
}
