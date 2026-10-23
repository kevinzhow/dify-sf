/// Annotations (docs/protocol.md section 2 "App detail pages", protocol 1.11): a chatflow's question/answer annotations
/// and its Annotation Reply setting, with **Dify 1.17.1's console API paths and shapes** under `/v1`
/// (`api/controllers/console/app/annotation.py`, `message.py` `annotations/count`).
///
/// ## What to use it for (the Annotations page; chatflow apps only)
///
/// * **List**: [AnnotationsApi.list] (`page`, `limit` 1-100, `keyword` matching question or answer, case-insensitive)
///   -> [AnnotationPage], newest first. Dify's `has_more` is `data.length == limit` (so a full last page says `true`).
///   The nav badge / header count: [AnnotationsApi.count].
/// * **Add / edit / remove**: [AnnotationsApi.create] (Dify's "create next" just calls it again), [AnnotationsApi.update],
///   [AnnotationsApi.delete]; batch delete of the checked rows: [AnnotationsApi.deleteMany]; "clear all":
///   [AnnotationsApi.clearAll]. Plain writes, effective at once.
/// * **Export**: [AnnotationsApi.export] (every annotation, newest first), then [AnnotationFiles.csv] (Dify's CSV with a
///   BOM) or [AnnotationFiles.jsonl] (Dify's fine-tuning JSONL); file names [AnnotationFiles.csvName] /
///   [AnnotationFiles.jsonlName].
/// * **Import**: the template is [AnnotationFiles.templateCsv]; [AnnotationsApi.batchImport] uploads a CSV (at most 2
///   MB; the first row is the header; columns question, answer; 1-10000 usable rows; question at most 2000, answer at
///   most 10000 characters). A refused file is an answer, not an exception: [AnnotationJob.errorMsg] is Dify's message
///   (`job_id` null). Otherwise poll [AnnotationsApi.batchImportStatus] as Dify does (every 2.5 s) until
///   [AnnotationJob.done]: dify-sf imports synchronously, so the first poll already answers `completed`.
/// * **Annotation Reply** switch: [AnnotationsApi.setting]; Dify's `ConfigParamModal` -> [AnnotationsApi.enableReply]
///   (score threshold, embedding provider and model) or [AnnotationsApi.disableReply], then poll
///   [AnnotationsApi.replyStatus] (Dify: every 2 s) until done (dify-sf: `completed` at once); a later score change is
///   [AnnotationsApi.updateSetting]. dify-sf **stores** the setting only: no embedding is computed and nothing is matched
///   until a runtime exists.
/// * **Hit history** (the view modal's second tab): [AnnotationsApi.hitHistories]: always an empty page (hits come from
///   a runtime).
///
/// ## Modes
///
/// Dify's server accepts these calls for any app; its UI offers Annotations for chat apps only (not for `workflow`
/// apps). dify-sf refuses them for workflow apps with Dify's own wrong-mode error: `404 app_not_found` "App mode is not
/// in the supported list: {'advanced-chat'}" (what Dify's `get_app_model(mode=...)` answers).
///
/// ## Roles
///
/// Every call needs `owner`, `admin` or `editor` (Dify's `edit_permission_required`), except [AnnotationsApi.count],
/// which any member may read (Dify: no role check). Others get `403 forbidden`.
///
/// ## Errors
///
/// `TransportException` with the server's code: `not_found` (404: unknown app, annotation, job or setting),
/// `app_not_found` (404: a workflow app), `app_deleted` (404), `bad_request` (400: missing question or answer, a
/// malformed body), `forbidden` (403), `unauthorized` (401), `payload_too_large` (413: a CSV over 2 MB).
///
/// Implementations: `HttpAnnotationsApi` and `FakeAnnotationsApi` (`package:collab_client/testing.dart`).
library;

import 'dart:convert';

/// One annotation: Dify's `Annotation` (`{id, question, answer, hit_count, created_at}`).
final class Annotation {
  const Annotation({
    required this.id,
    required this.question,
    required this.answer,
    this.hitCount = 0,
    this.createdAt = 0,
    this.json = const {},
  });

  factory Annotation.fromJson(Map<String, Object?> m) => Annotation(
    id: _str(m['id']),
    question: _str(m['question']),
    answer: _str(m['answer']),
    hitCount: m['hit_count'] is num ? (m['hit_count']! as num).toInt() : 0,
    createdAt: m['created_at'] is num ? (m['created_at']! as num).toInt() : 0,
    json: m,
  );

  final String id;
  final String question;
  final String answer;

  /// Always 0 until a runtime matches annotations.
  final int hitCount;

  /// Epoch seconds.
  final int createdAt;
  final Map<String, Object?> json;

  Map<String, Object?> toJson() => json.isNotEmpty
      ? json
      : {'id': id, 'question': question, 'answer': answer, 'hit_count': hitCount, 'created_at': createdAt};
}

/// Dify's `AnnotationList`.
final class AnnotationPage {
  const AnnotationPage({
    required this.data,
    required this.hasMore,
    required this.limit,
    required this.total,
    required this.page,
  });

  factory AnnotationPage.fromJson(Map<String, Object?> m) => AnnotationPage(
    data: [
      if (m['data'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) Annotation.fromJson(x),
    ],
    hasMore: m['has_more'] == true,
    limit: _int(m['limit'], 20),
    total: _int(m['total'], 0),
    page: _int(m['page'], 1),
  );

  final List<Annotation> data;

  /// Dify's rule: `data.length == limit`.
  final bool hasMore;
  final int limit;

  /// Matching annotations in all pages.
  final int total;
  final int page;
}

/// Dify's job states (`waiting`, `processing`, `completed`, `error`).
abstract final class AnnotationJobStatus {
  static const waiting = 'waiting';
  static const processing = 'processing';
  static const completed = 'completed';
  static const error = 'error';
}

/// A job answer: Dify's `AnnotationBatchImportResponse` (`{job_id, job_status, record_count}` or `{error_msg}`),
/// `AnnotationJobStatusResponse` and `AnnotationJobStatusDetailResponse` (`{job_id, job_status, error_msg}`).
final class AnnotationJob {
  const AnnotationJob({this.jobId, this.jobStatus, this.recordCount, this.errorMsg = ''});

  factory AnnotationJob.fromJson(Map<String, Object?> m) => AnnotationJob(
    jobId: m['job_id'] is String ? m['job_id']! as String : null,
    jobStatus: m['job_status'] is String ? m['job_status']! as String : null,
    recordCount: m['record_count'] is num ? (m['record_count']! as num).toInt() : null,
    errorMsg: _str(m['error_msg']),
  );

  /// Null when a batch import was refused ([errorMsg]).
  final String? jobId;

  /// [AnnotationJobStatus]; null when refused.
  final String? jobStatus;

  /// Usable rows of a batch import.
  final int? recordCount;

  /// Dify's message for a refused import or a failed job; `""` otherwise.
  final String errorMsg;

  /// The import was refused before a job started (show [errorMsg]).
  bool get refused => jobId == null;

  /// Stop polling: completed, failed or refused.
  bool get done => refused || jobStatus == AnnotationJobStatus.completed || jobStatus == AnnotationJobStatus.error;

  bool get failed => refused || jobStatus == AnnotationJobStatus.error;

  Map<String, Object?> toJson() => {
    'job_id': ?jobId,
    'job_status': ?jobStatus,
    'record_count': ?recordCount,
    if (errorMsg.isNotEmpty || jobId == null) 'error_msg': errorMsg,
  };
}

/// Dify's `AnnotationSettingResponse`: `{enabled: false}` or `{id, enabled: true, score_threshold, embedding_model:
/// {embedding_provider_name, embedding_model_name}}`.
final class AnnotationSetting {
  const AnnotationSetting({
    required this.enabled,
    this.id,
    this.scoreThreshold,
    this.embeddingProviderName,
    this.embeddingModelName,
  });

  factory AnnotationSetting.fromJson(Map<String, Object?> m) {
    final em = m['embedding_model'] is Map<String, Object?> ? m['embedding_model']! as Map<String, Object?> : const {};
    return AnnotationSetting(
      enabled: m['enabled'] == true,
      id: m['id'] is String ? m['id']! as String : null,
      scoreThreshold: m['score_threshold'] is num ? (m['score_threshold']! as num).toDouble() : null,
      embeddingProviderName: em['embedding_provider_name'] is String ? em['embedding_provider_name']! as String : null,
      embeddingModelName: em['embedding_model_name'] is String ? em['embedding_model_name']! as String : null,
    );
  }

  static const disabled = AnnotationSetting(enabled: false);

  final bool enabled;

  /// The setting's id ([AnnotationsApi.updateSetting]); null when disabled.
  final String? id;

  /// 0.8-1.0 in Dify's slider (any number is stored).
  final double? scoreThreshold;
  final String? embeddingProviderName;
  final String? embeddingModelName;

  Map<String, Object?> toJson() => enabled
      ? {
          'id': id,
          'enabled': true,
          'score_threshold': scoreThreshold,
          'embedding_model': {
            'embedding_provider_name': ?embeddingProviderName,
            'embedding_model_name': ?embeddingModelName,
          },
        }
      : {'enabled': false};
}

/// Dify's `AnnotationHitHistory`.
final class AnnotationHitHistory {
  const AnnotationHitHistory({
    required this.id,
    this.source,
    this.score,
    this.question,
    this.createdAt,
    this.match,
    this.response,
  });

  factory AnnotationHitHistory.fromJson(Map<String, Object?> m) => AnnotationHitHistory(
    id: _str(m['id']),
    source: m['source'] is String ? m['source']! as String : null,
    score: m['score'] is num ? (m['score']! as num).toDouble() : null,
    question: m['question'] is String ? m['question']! as String : null,
    createdAt: m['created_at'] is num ? (m['created_at']! as num).toInt() : null,
    match: m['match'] is String ? m['match']! as String : null,
    response: m['response'] is String ? m['response']! as String : null,
  );

  final String id;
  final String? source;
  final double? score;
  final String? question;
  final int? createdAt;
  final String? match;
  final String? response;
}

/// Dify's `AnnotationHitHistoryList` (always empty on dify-sf).
final class AnnotationHitHistoryPage {
  const AnnotationHitHistoryPage({
    required this.data,
    required this.hasMore,
    required this.limit,
    required this.total,
    required this.page,
  });

  factory AnnotationHitHistoryPage.fromJson(Map<String, Object?> m) => AnnotationHitHistoryPage(
    data: [
      if (m['data'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) AnnotationHitHistory.fromJson(x),
    ],
    hasMore: m['has_more'] == true,
    limit: _int(m['limit'], 20),
    total: _int(m['total'], 0),
    page: _int(m['page'], 1),
  );

  final List<AnnotationHitHistory> data;
  final bool hasMore;
  final int limit;
  final int total;
  final int page;
}

/// Dify's annotation files (`annotation/header-opts`, `batch-add-annotation-modal/csv-downloader.tsx`), byte for byte.
abstract final class AnnotationFiles {
  /// Dify's `LanguagesSupported[1]`: the locale that gets Chinese headers.
  static const _chinese = 'zh-Hans';

  /// The export as Dify's CSV: a BOM, the header `Question,Answer` (`问题,答案` for `zh-Hans`), one row per annotation,
  /// papaparse's quoting (a field with a comma, a quote, a line break or a leading/trailing space is quoted, quotes
  /// doubled), lines joined with `\r\n`.
  static String csv(List<Annotation> list, {String locale = 'en-US'}) {
    final header = locale == _chinese ? const ['问题', '答案'] : const ['Question', 'Answer'];
    return '﻿${_rows([
      header,
      for (final a in list) [a.question, a.answer],
    ])}';
  }

  /// The export as Dify's JSONL: one `{"messages": [system "", user question, assistant answer]}` line per annotation,
  /// joined with `\n` (no trailing newline).
  static String jsonl(List<Annotation> list) => [
    for (final a in list)
      '{"messages": [{"role": "system", "content": ""}, {"role": "user", "content": ${jsonEncode(a.question)}}, '
          '{"role": "assistant", "content": ${jsonEncode(a.answer)}}]}',
  ].join('\n');

  /// Dify's import template (with a BOM, as its downloader writes it).
  static String templateCsv({String locale = 'en-US'}) =>
      '﻿${_rows(locale == _chinese ? const [
              ['问题', '答案'],
              ['问题 1', '答案 1'],
              ['问题 2', '答案 2'],
            ] : const [
              ['question', 'answer'],
              ['question1', 'answer1'],
              ['question2', 'answer2'],
            ])}';

  /// Dify's download names.
  static String csvName(String locale) => 'annotations-$locale.csv';
  static String jsonlName(String locale) => 'annotations-$locale.jsonl';
  static String templateName(String locale) => 'template-$locale.csv';

  static String _rows(List<List<String>> rows) => rows.map((r) => r.map(_field).join(',')).join('\r\n');

  static String _field(String s) {
    final quote =
        s.contains(',') ||
        s.contains('"') ||
        s.contains('\n') ||
        s.contains('\r') ||
        s.startsWith(' ') ||
        s.endsWith(' ');
    return quote ? '"${s.replaceAll('"', '""')}"' : s;
  }
}

/// See the library documentation above. [appId] arguments are app ids (= document ids).
abstract interface class AnnotationsApi {
  /// `GET /v1/apps/{appId}/annotations?page&limit&keyword`.
  Future<AnnotationPage> list(String appId, {int page = 1, int limit = 20, String keyword = ''});

  /// `GET /v1/apps/{appId}/annotations/count` -> Dify's `{count}` (any member).
  Future<int> count(String appId);

  /// `GET /v1/apps/{appId}/annotations/export` -> every annotation (Dify's `{data}`), newest first.
  Future<List<Annotation>> export(String appId);

  /// `POST /v1/apps/{appId}/annotations` `{question, answer}` -> `201` the annotation. [question] and [answer] must not
  /// be empty (Dify's "'question' is required when 'message_id' is not provided").
  Future<Annotation> create(String appId, {required String question, required String answer});

  /// `POST /v1/apps/{appId}/annotations/{annotationId}` `{question, answer}` -> the annotation (both required, as Dify).
  Future<Annotation> update(String appId, String annotationId, {required String question, required String answer});

  /// `DELETE /v1/apps/{appId}/annotations/{annotationId}` -> `204`.
  Future<void> delete(String appId, String annotationId);

  /// `DELETE /v1/apps/{appId}/annotations?annotation_id=a&annotation_id=b` -> `204` (unknown ids are ignored). An empty
  /// list does nothing (it would clear everything on the wire).
  Future<void> deleteMany(String appId, List<String> annotationIds);

  /// `DELETE /v1/apps/{appId}/annotations` (no ids) -> `204`: every annotation of the app.
  Future<void> clearAll(String appId);

  /// `POST /v1/apps/{appId}/annotations/batch-import` (multipart `file`, a `.csv` name) -> the job, or a refusal with
  /// [AnnotationJob.errorMsg].
  Future<AnnotationJob> batchImport(String appId, List<int> csvBytes, {String filename = 'annotations.csv'});

  /// `GET /v1/apps/{appId}/annotations/batch-import-status/{jobId}`.
  Future<AnnotationJob> batchImportStatus(String appId, String jobId);

  /// `GET /v1/apps/{appId}/annotation-setting`.
  Future<AnnotationSetting> setting(String appId);

  /// `POST /v1/apps/{appId}/annotation-reply/enable` `{score_threshold, embedding_provider_name, embedding_model_name}`
  /// -> the job.
  Future<AnnotationJob> enableReply(
    String appId, {
    required double scoreThreshold,
    required String embeddingProviderName,
    required String embeddingModelName,
  });

  /// `POST /v1/apps/{appId}/annotation-reply/disable` -> the job.
  Future<AnnotationJob> disableReply(String appId);

  /// `GET /v1/apps/{appId}/annotation-reply/{action}/status/{jobId}`; [action] `enable` or `disable`.
  Future<AnnotationJob> replyStatus(String appId, String action, String jobId);

  /// `POST /v1/apps/{appId}/annotation-settings/{settingId}` `{score_threshold}` -> the setting.
  Future<AnnotationSetting> updateSetting(String appId, String settingId, {required double scoreThreshold});

  /// `GET /v1/apps/{appId}/annotations/{annotationId}/hit-histories?page&limit` (always empty on dify-sf).
  Future<AnnotationHitHistoryPage> hitHistories(String appId, String annotationId, {int page = 1, int limit = 20});
}

String _str(Object? v) => v is String ? v : '';
int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
