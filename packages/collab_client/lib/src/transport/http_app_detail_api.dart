import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../access_api.dart';
import '../annotations_api.dart';
import '../apps_api.dart';
import '../auth/auth_api.dart';
import '../auth/auth_session.dart';
import '../client/replace.dart';
import '../client/transport.dart';
import '../monitor_api.dart';
import '../versions_api.dart';

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

  Uri _url(String path, [Map<String, List<String>>? query]) =>
      baseUrl.replace(path: '$_basePath$path', queryParameters: query == null || query.isEmpty ? null : query);

  static String _app(String id) => '/v1/apps/${Uri.encodeComponent(id)}';
  static String _seg(String s) => Uri.encodeComponent(s);

  static Map<String, Object?> _map(Object? json) =>
      json is Map<String, Object?> ? json : throw const TransportException('malformed answer: not an object');

  static List<Map<String, Object?>> _data(Object? json) {
    final m = _map(json);
    final d = m['data'];
    if (d is! List<Object?>) throw const TransportException('malformed answer: no data');
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
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
    } on TimeoutException {
      throw TransportException('$method $path timed out', timeout: true);
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (!ok.contains(res.statusCode)) throw transportErrorOf(res.statusCode, text);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return (status: res.statusCode, text: text, json: null);
    try {
      return (status: res.statusCode, text: text, json: jsonDecode(text));
    } on FormatException catch (e) {
      if (res.statusCode >= 400) throw transportErrorOf(res.statusCode, text);
      throw TransportException('malformed answer to $method $path: ${e.message}');
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
      (await _send('POST', '${HttpConsoleApi._app(appId)}/site', ok: const [200], body: update.toJson())).json,
    ),
  );

  @override
  Future<AppSite> resetAccessToken(String appId) async => AppSite.fromJson(
    HttpConsoleApi._map(
      (await _send('POST', '${HttpConsoleApi._app(appId)}/site/access-token-reset', ok: const [200])).json,
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
      (await _send('GET', '${HttpConsoleApi._app(appId)}/api-keys', ok: const [200])).json,
    ))
      AppApiKey.fromJson(m),
  ];

  @override
  Future<AppApiKey> createApiKey(String appId) async => AppApiKey.fromJson(
    HttpConsoleApi._map((await _send('POST', '${HttpConsoleApi._app(appId)}/api-keys', ok: const [201, 200])).json),
  );

  @override
  Future<void> deleteApiKey(String appId, String keyId) =>
      _send('DELETE', '${HttpConsoleApi._app(appId)}/api-keys/${HttpConsoleApi._seg(keyId)}', ok: const [204, 200]);
}

/// [AnnotationsApi] against a real server (protocol 1.11).
class HttpAnnotationsApi extends HttpConsoleApi implements AnnotationsApi {
  HttpAnnotationsApi(super.baseUrl, {super.client, super.auth, super.timeout});

  String _a(String appId) => '${HttpConsoleApi._app(appId)}/annotations';

  @override
  Future<AnnotationPage> list(String appId, {int page = 1, int limit = 20, String keyword = ''}) async =>
      AnnotationPage.fromJson(
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
    final m = HttpConsoleApi._map((await _send('GET', '${_a(appId)}/count', ok: const [200])).json);
    return m['count'] is num ? (m['count']! as num).toInt() : 0;
  }

  @override
  Future<List<Annotation>> export(String appId) async => [
    for (final m in HttpConsoleApi._data((await _send('GET', '${_a(appId)}/export', ok: const [200])).json))
      Annotation.fromJson(m),
  ];

  @override
  Future<Annotation> create(String appId, {required String question, required String answer}) async =>
      Annotation.fromJson(
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
  Future<void> delete(String appId, String annotationId) =>
      _send('DELETE', '${_a(appId)}/${HttpConsoleApi._seg(annotationId)}', ok: const [204, 200]);

  @override
  Future<void> deleteMany(String appId, List<String> annotationIds) async {
    if (annotationIds.isEmpty) return;
    await _send('DELETE', _a(appId), ok: const [204, 200], query: {'annotation_id': annotationIds});
  }

  @override
  Future<void> clearAll(String appId) => _send('DELETE', _a(appId), ok: const [204, 200]);

  /// The upload is a `multipart/form-data` body built here as a plain request (so a `401` refresh can replay it).
  @override
  Future<AnnotationJob> batchImport(String appId, List<int> csvBytes, {String filename = 'annotations.csv'}) async {
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
      HttpConsoleApi._map((await _send('POST', '${_a(appId)}/batch-import', ok: const [200], request: req)).json),
    );
  }

  @override
  Future<AnnotationJob> batchImportStatus(String appId, String jobId) async => AnnotationJob.fromJson(
    HttpConsoleApi._map(
      (await _send('GET', '${_a(appId)}/batch-import-status/${HttpConsoleApi._seg(jobId)}', ok: const [200])).json,
    ),
  );

  @override
  Future<AnnotationSetting> setting(String appId) async => AnnotationSetting.fromJson(
    HttpConsoleApi._map((await _send('GET', '${HttpConsoleApi._app(appId)}/annotation-setting', ok: const [200])).json),
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
  Future<AnnotationJob> replyStatus(String appId, String action, String jobId) async => AnnotationJob.fromJson(
    HttpConsoleApi._map(
      (await _send(
        'GET',
        '${HttpConsoleApi._app(appId)}/annotation-reply/${HttpConsoleApi._seg(action)}/status/${HttpConsoleApi._seg(jobId)}',
        ok: const [200],
      )).json,
    ),
  );

  @override
  Future<AnnotationSetting> updateSetting(String appId, String settingId, {required double scoreThreshold}) async =>
      AnnotationSetting.fromJson(
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
    final json = (await _send('GET', '${_w(appId)}/publish', ok: const [200])).json;
    return json is Map<String, Object?> ? WorkflowVersion.fromJson(json) : null;
  }

  @override
  Future<PublishResult> publish(String appId, {String? markedName, String? markedComment}) async =>
      PublishResult.fromJson(
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
    HttpConsoleApi._map((await _send('GET', '${_w(appId)}/${HttpConsoleApi._seg(versionId)}', ok: const [200])).json),
  );

  @override
  Future<String> exportDsl(String appId, String versionId, {bool includeSecret = false}) async {
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
    if (data is! String) throw const TransportException('malformed answer: no data');
    return data;
  }

  @override
  Future<WorkflowVersion> update(String appId, String versionId, {String? markedName, String? markedComment}) async =>
      WorkflowVersion.fromJson(
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
  Future<void> delete(String appId, String versionId) =>
      _send('DELETE', '${_w(appId)}/${HttpConsoleApi._seg(versionId)}', ok: const [204, 200]);

  @override
  Future<ReplaceResult> restore(String appId, String versionId, String clientId, {required int cseq}) async =>
      ReplaceResult.fromJson(
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
  Future<List<StatisticRow>> statistic(String appId, AppStatistic stat, {String? start, String? end}) async => [
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
  Future<WorkflowLogPage> workflowLogs(String appId, [WorkflowLogQuery query = const WorkflowLogQuery()]) async =>
      WorkflowLogPage.fromJson(
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
  Future<Map<String, Object?>> workflowRun(String appId, String runId) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/workflow-runs/${HttpConsoleApi._seg(runId)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<List<Map<String, Object?>>> workflowRunNodeExecutions(String appId, String runId) async =>
      HttpConsoleApi._data(
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
  Future<Map<String, Object?>> chatConversation(String appId, String conversationId) async => HttpConsoleApi._map(
    (await _send(
      'GET',
      '${HttpConsoleApi._app(appId)}/chat-conversations/${HttpConsoleApi._seg(conversationId)}',
      ok: const [200],
    )).json,
  );

  @override
  Future<ChatMessagePage> chatMessages(String appId, String conversationId, {String? firstId, int limit = 20}) async =>
      ChatMessagePage.fromJson(
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
}
