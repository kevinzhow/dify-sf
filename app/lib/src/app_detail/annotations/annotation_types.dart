/// What the Annotations page (web/app/components/app/annotation) calls: Dify's `@/service/annotation` and
/// `useAnnotationsCount` for one app ([AnnotationServices]), bound to collab_client's [AnnotationsApi]
/// ([AnnotationsApiServices]); `@/config`'s `APP_PAGE_LIMIT` and `ANNOTATION_DEFAULT`. The data types are
/// collab_client's ([Annotation], [AnnotationSetting], [AnnotationJob], [AnnotationHitHistory]) and so are the export
/// and template files ([AnnotationFiles]).
library;

import 'dart:typed_data';

import 'package:collab_client/collab_client.dart';

/// `APP_PAGE_LIMIT`.
const appPageLimit = 10;

/// `ANNOTATION_DEFAULT.score_threshold`.
const annotationDefaultScoreThreshold = 0.9;

/// `AnnotationItemBasic`: what is added or exported.
typedef AnnotationItemBasic = ({String question, String answer});

/// `EmbeddingModelConfig`.
typedef EmbeddingModelConfig = ({String embeddingProviderName, String embeddingModelName});

/// `AnnotationEnableStatus`.
enum AnnotationEnableStatus { enable, disable }

/// A page of a list (`{data, total}`).
typedef AnnotationListPage<T> = ({List<T> data, int total});

/// The setting's embedding model, if it has one.
EmbeddingModelConfig? embeddingModelOf(AnnotationSetting s) =>
    s.embeddingProviderName == null || s.embeddingModelName == null
    ? null
    : (embeddingProviderName: s.embeddingProviderName!, embeddingModelName: s.embeddingModelName!);

/// Dify's `@/service/annotation` (and `useAnnotationsCount`) for one app. Each call throws when refused.
abstract interface class AnnotationServices {
  /// `fetchAnnotationList(appId, {page, limit, keyword})`.
  Future<AnnotationListPage<Annotation>> list({required int page, required int limit, String keyword = ''});

  /// `useAnnotationsCount(appId)`.
  Future<int> count();

  /// `addAnnotation(appId, payload)`.
  Future<Annotation> add(AnnotationItemBasic payload);

  /// `editAnnotation(appId, annotationId, {question, answer})`.
  Future<void> edit(String annotationId, {required String question, required String answer});

  /// `delAnnotation(appId, annotationId)`.
  Future<void> delete(String annotationId);

  /// `delAnnotations(appId, ids)`.
  Future<void> deleteMany(List<String> ids);

  /// `clearAllAnnotations(appId)`.
  Future<void> clearAll();

  /// `fetchExportAnnotationList(appId)`.
  Future<List<Annotation>> exportList();

  /// `annotationBatchImport` (the CSV file) and `checkAnnotationBatchImportProgress`.
  Future<AnnotationJob> batchImport(Uint8List csv, String fileName);
  Future<AnnotationJob> batchImportStatus(String jobId);

  /// `fetchAnnotationConfig(appId)`.
  Future<AnnotationSetting> fetchConfig();

  /// `updateAnnotationStatus(appId, action, embeddingModel, score)`: the job.
  Future<AnnotationJob> updateStatus(
    AnnotationEnableStatus action,
    EmbeddingModelConfig? embeddingModel,
    double? score,
  );

  /// `queryAnnotationJobStatus(appId, action, jobId)`.
  Future<AnnotationJob> jobStatus(AnnotationEnableStatus action, String jobId);

  /// `updateAnnotationScore(appId, annotationSettingId, score)`.
  Future<void> updateScore(String settingId, double score);

  /// `fetchHitHistoryList(appId, annotationId, {page, limit})`.
  Future<AnnotationListPage<AnnotationHitHistory>> hitHistories(
    String annotationId, {
    required int page,
    required int limit,
  });
}

/// [AnnotationServices] on a server ([AnnotationsApi], protocol 1.11) for the app [appId].
class AnnotationsApiServices implements AnnotationServices {
  const AnnotationsApiServices(this.api, this.appId);

  final AnnotationsApi api;
  final String appId;

  @override
  Future<AnnotationListPage<Annotation>> list({required int page, required int limit, String keyword = ''}) async {
    final p = await api.list(appId, page: page, limit: limit, keyword: keyword);
    return (data: p.data, total: p.total);
  }

  @override
  Future<int> count() => api.count(appId);

  @override
  Future<Annotation> add(AnnotationItemBasic payload) =>
      api.create(appId, question: payload.question, answer: payload.answer);

  @override
  Future<void> edit(String annotationId, {required String question, required String answer}) =>
      api.update(appId, annotationId, question: question, answer: answer);

  @override
  Future<void> delete(String annotationId) => api.delete(appId, annotationId);

  @override
  Future<void> deleteMany(List<String> ids) => api.deleteMany(appId, ids);

  @override
  Future<void> clearAll() => api.clearAll(appId);

  @override
  Future<List<Annotation>> exportList() => api.export(appId);

  @override
  Future<AnnotationJob> batchImport(Uint8List csv, String fileName) async {
    final job = await api.batchImport(appId, csv, filename: fileName);
    // A refused file is an answer on dify-sf; Dify's request layer throws it (the modal toasts "Run batch failed: …").
    if (job.refused) throw AnnotationImportRefused(job.errorMsg);
    return job;
  }

  @override
  Future<AnnotationJob> batchImportStatus(String jobId) => api.batchImportStatus(appId, jobId);

  @override
  Future<AnnotationSetting> fetchConfig() => api.setting(appId);

  @override
  Future<AnnotationJob> updateStatus(
    AnnotationEnableStatus action,
    EmbeddingModelConfig? embeddingModel,
    double? score,
  ) => switch (action) {
    AnnotationEnableStatus.enable => api.enableReply(
      appId,
      scoreThreshold: score ?? annotationDefaultScoreThreshold,
      embeddingProviderName: embeddingModel?.embeddingProviderName ?? '',
      embeddingModelName: embeddingModel?.embeddingModelName ?? '',
    ),
    AnnotationEnableStatus.disable => api.disableReply(appId),
  };

  @override
  Future<AnnotationJob> jobStatus(AnnotationEnableStatus action, String jobId) =>
      api.replyStatus(appId, action.name, jobId);

  @override
  Future<void> updateScore(String settingId, double score) =>
      api.updateSetting(appId, settingId, scoreThreshold: score);

  @override
  Future<AnnotationListPage<AnnotationHitHistory>> hitHistories(
    String annotationId, {
    required int page,
    required int limit,
  }) async {
    final p = await api.hitHistories(appId, annotationId, page: page, limit: limit);
    return (data: p.data, total: p.total);
  }
}

/// A batch import the server refused (Dify's `error_msg`); its text is the message.
class AnnotationImportRefused implements Exception {
  const AnnotationImportRefused(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Dify's `e.message` of a failed request: a [TransportException]'s message, an exception's text without its type
/// prefix; `''` for anything else (a thrown string has no `message`).
String errorMessageOf(Object e) {
  if (e is TransportException) return e.message;
  if (e is AnnotationImportRefused) return e.message;
  if (e is! Exception && e is! Error) return '';
  final s = '$e';
  for (final prefix in ['Exception: ', 'Bad state: ']) {
    if (s.startsWith(prefix)) return s.substring(prefix.length);
  }
  return s;
}
