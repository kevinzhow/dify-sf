/// Publish and versions (docs/protocol.md section 2 "App detail pages", protocol 1.11): published versions of an app's
/// workflow, with **Dify 1.17.1's console API paths and shapes** under `/v1` (`api/controllers/console/app/workflow.py`:
/// `workflows/publish`, `workflows`, `workflows/{id}`, `workflows/{id}/restore`).
///
/// ## Model
///
/// The **draft** is the document itself (what the editor edits; its id is the app id, as `AppInfo.json['workflow']`).
/// [VersionsApi.publish] stores a **version**: a snapshot of the document at its head (graph, features, environment and
/// conversation variables, as the export renders them), with an optional name and comment, its creator and time. The
/// newest version is the app's **published** one ([VersionsApi.published]; Dify's `app.workflow_id`); it cannot be
/// deleted. Version numbers count per app from 1 and are never reused (Dify's `version_number`).
///
/// ## What to use it for
///
/// * **Publisher** (editor header): [VersionsApi.published] (null = never published: Dify's "unpublished" state, the
///   Access Point banner and unavailable cards for workflow apps); "Publish update" = [VersionsApi.publish] (Dify's
///   `{result: "success", created_at}`), then refetch [VersionsApi.published] (its [WorkflowVersion.createdAt] is
///   "Published at").
/// * **Version history panel**: [VersionsApi.list] (`page`, `limit` 1-100 (Dify's panel asks for 10), [userId] = "only
///   mine" (must be the caller's own id, else `403`), [namedOnly]). Dify's order: the draft first (its
///   [WorkflowVersion.version] is `draft`), then versions newest first. An app that was never published lists nothing
///   (not even the draft), as Dify. Rename / comment: [VersionsApi.update]; delete: [VersionsApi.delete] (not the
///   draft, not the published version: `400`).
/// * **Preview** a version: [VersionsApi.get] -> [WorkflowVersion.document] (render it read-only); **export** one:
///   [VersionsApi.exportDsl] (Dify's `export?workflow_id=`).
/// * **Restore** a version into the draft: through the editor's replacement path, so it is one ordinary, undoable-by-
///   history replacement of the open session: `session.replaceDocument((clientId, cseq) => versions.restore(appId,
///   versionId, clientId, cseq: cseq))`. The server renders the version as a Dify file and replaces the document with
///   it exactly like `POST /v1/docs/{id}/replace` (the same ops, conflict rules, `409`s and replay of a retry), with the
///   version's secret values kept on the server (they never travel). The answer is a `ReplaceResult` (plus Dify's
///   `result`, `hash`, `updated_at` in its JSON). Restoring does not change the published version (as Dify).
///
/// ## Roles
///
/// Every call needs `owner`, `admin` or `editor` (Dify's `edit_permission_required`, also for reading the published
/// version and the list); others get `403 forbidden`.
///
/// ## Errors
///
/// `TransportException` with the server's code: `not_found` (404: unknown app or version), `app_not_found` (404: an app
/// of another mode), `app_deleted` (404), `bad_request` (400: name over 20 or comment over 100 characters, an update
/// with neither, deleting the draft or the published version, restoring the draft: Dify's "source workflow must be
/// published"), `forbidden` (403), `unauthorized` (401), and for [VersionsApi.restore] the replacement's codes
/// (`409 outstanding_ops`, `cseq_used`, `conflict`).
///
/// Implementations: `HttpVersionsApi` and `FakeVersionsApi` (`package:collab_client/testing.dart`).
library;

import 'client/replace.dart';
import 'model/document.dart';

/// Dify's `SimpleAccount` (`{id, name, email}`) in a version.
final class VersionAccount {
  const VersionAccount({required this.id, required this.name, required this.email});

  factory VersionAccount.fromJson(Map<String, Object?> m) => VersionAccount(
    id: m['id'] is String ? m['id']! as String : '',
    name: m['name'] is String ? m['name']! as String : '',
    email: m['email'] is String ? m['email']! as String : '',
  );

  final String id;
  final String name;
  final String email;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'email': email};
}

/// One version (or the draft): Dify's `WorkflowResponse`.
final class WorkflowVersion {
  const WorkflowVersion({
    required this.id,
    required this.version,
    this.versionNumber,
    this.markedName = '',
    this.markedComment = '',
    this.hash = '',
    this.createdBy,
    this.createdAt = 0,
    this.updatedBy,
    this.updatedAt = 0,
    this.graph = const {},
    this.features = const {},
    this.environmentVariables = const [],
    this.conversationVariables = const [],
    this.document,
    this.json = const {},
  });

  factory WorkflowVersion.fromJson(Map<String, Object?> m) {
    List<Map<String, Object?>> list(Object? v) => [
      if (v is List<Object?>)
        for (final x in v)
          if (x is Map<String, Object?>) x,
    ];
    return WorkflowVersion(
      id: m['id'] is String ? m['id']! as String : '',
      version: m['version'] is String ? m['version']! as String : '',
      versionNumber: m['version_number'] is num ? (m['version_number']! as num).toInt() : null,
      markedName: m['marked_name'] is String ? m['marked_name']! as String : '',
      markedComment: m['marked_comment'] is String ? m['marked_comment']! as String : '',
      hash: m['hash'] is String ? m['hash']! as String : '',
      createdBy: m['created_by'] is Map<String, Object?>
          ? VersionAccount.fromJson(m['created_by']! as Map<String, Object?>)
          : null,
      createdAt: m['created_at'] is num ? (m['created_at']! as num).toInt() : 0,
      updatedBy: m['updated_by'] is Map<String, Object?>
          ? VersionAccount.fromJson(m['updated_by']! as Map<String, Object?>)
          : null,
      updatedAt: m['updated_at'] is num ? (m['updated_at']! as num).toInt() : 0,
      graph: m['graph'] is Map<String, Object?> ? m['graph']! as Map<String, Object?> : const {},
      features: m['features'] is Map<String, Object?> ? m['features']! as Map<String, Object?> : const {},
      environmentVariables: list(m['environment_variables']),
      conversationVariables: list(m['conversation_variables']),
      document: m['doc'] == null ? null : Document.fromJson(m['doc']),
      json: m,
    );
  }

  /// The version's id (the draft's is the app id).
  final String id;

  /// `draft`, or Dify's version string (the publish time, `YYYY-MM-DD HH:MM:SS.ffffff`, UTC).
  final String version;

  /// 1, 2, ... per app (never reused); null for the draft. Dify shows `#N` / "Untitled Version".
  final int? versionNumber;

  /// At most 20 characters; `""` = unnamed.
  final String markedName;

  /// At most 100 characters.
  final String markedComment;

  /// SHA-256 of the graph and features (Dify's `unique_hash`).
  final String hash;
  final VersionAccount? createdBy;

  /// Epoch seconds: the publish time (the draft: the app's creation).
  final int createdAt;
  final VersionAccount? updatedBy;

  /// Epoch seconds: the last rename (the draft: the last edit).
  final int updatedAt;

  /// Dify's graph (`nodes`, `edges`, `viewport`) as the export renders it.
  final Map<String, Object?> graph;
  final Map<String, Object?> features;

  /// Secret values are `""` here (never sent).
  final List<Map<String, Object?>> environmentVariables;
  final List<Map<String, Object?>> conversationVariables;

  /// The version as a document (the snapshot format, ready to render read-only on the canvas): only in the answer of
  /// [VersionsApi.get] (dify-sf's `doc` member), null elsewhere.
  final Document? document;
  final Map<String, Object?> json;

  bool get isDraft => version == 'draft';

  DateTime get createdTime => DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);

  Map<String, Object?> toJson() => json.isNotEmpty
      ? json
      : {
          'id': id,
          'graph': graph,
          'features': features,
          'hash': hash,
          'version': version,
          'version_number': versionNumber,
          'marked_name': markedName,
          'marked_comment': markedComment,
          'created_by': createdBy?.toJson(),
          'created_at': createdAt,
          'updated_by': updatedBy?.toJson(),
          'updated_at': updatedAt,
          'tool_published': false,
          'environment_variables': environmentVariables,
          'conversation_variables': conversationVariables,
          'rag_pipeline_variables': const <Object?>[],
        };
}

/// Dify's `WorkflowPaginationResponse` (`{items, page, limit, has_more}`).
final class WorkflowVersionPage {
  const WorkflowVersionPage({required this.items, required this.page, required this.limit, required this.hasMore});

  factory WorkflowVersionPage.fromJson(Map<String, Object?> m) => WorkflowVersionPage(
    items: [
      if (m['items'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) WorkflowVersion.fromJson(x),
    ],
    page: m['page'] is num ? (m['page']! as num).toInt() : 1,
    limit: m['limit'] is num ? (m['limit']! as num).toInt() : 10,
    hasMore: m['has_more'] == true,
  );

  final List<WorkflowVersion> items;
  final int page;
  final int limit;
  final bool hasMore;
}

/// Dify's `WorkflowPublishResponse` (`{result: "success", created_at}`).
final class PublishResult {
  const PublishResult({required this.result, required this.createdAt});

  factory PublishResult.fromJson(Map<String, Object?> m) => PublishResult(
    result: m['result'] is String ? m['result']! as String : '',
    createdAt: m['created_at'] is num ? (m['created_at']! as num).toInt() : 0,
  );

  final String result;

  /// Epoch seconds of the new version.
  final int createdAt;
}

/// Limits of [VersionsApi.publish] and [VersionsApi.update] (Dify's `PublishWorkflowPayload`).
abstract final class VersionLimits {
  static const nameMaxLength = 20;
  static const commentMaxLength = 100;
}

/// See the library documentation above. [appId] arguments are app ids (= document ids).
abstract interface class VersionsApi {
  /// `GET /v1/apps/{appId}/workflows/publish`: the published version, or null (Dify answers `null`) if never published.
  Future<WorkflowVersion?> published(String appId);

  /// `POST /v1/apps/{appId}/workflows/publish` `{marked_name, marked_comment}`: a new version of the document at head.
  Future<PublishResult> publish(String appId, {String? markedName, String? markedComment});

  /// `GET /v1/apps/{appId}/workflows?page&limit&user_id&named_only`.
  Future<WorkflowVersionPage> list(
    String appId, {
    int page = 1,
    int limit = 10,
    String? userId,
    bool namedOnly = false,
  });

  /// `GET /v1/apps/{appId}/workflows/{versionId}` (dify-sf only; Dify has no such read): one version, or the draft with
  /// [appId] as [versionId], with [WorkflowVersion.document] filled, to preview it without reading a Dify file.
  Future<WorkflowVersion> get(String appId, String versionId);

  /// `GET /v1/apps/{appId}/export?workflow_id={versionId}&include_secret=` (Dify's export of one version): the version as
  /// a Dify file (YAML) under the app's current name and icon. Secret values are `""` unless [includeSecret] (owner,
  /// admin). [appId] as [versionId] exports the draft (the app's export).
  Future<String> exportDsl(String appId, String versionId, {bool includeSecret = false});

  /// `PATCH /v1/apps/{appId}/workflows/{versionId}` `{marked_name?, marked_comment?}` -> the version.
  Future<WorkflowVersion> update(String appId, String versionId, {String? markedName, String? markedComment});

  /// `DELETE /v1/apps/{appId}/workflows/{versionId}` -> `204`.
  Future<void> delete(String appId, String versionId);

  /// `POST /v1/apps/{appId}/workflows/{versionId}/restore` `{client, cseq, confirm?}`: replaces the draft with the
  /// version as ops of [clientId] (cseqs from [cseq]), like `DocsApi.replaceDocument`. Use it through
  /// `CollabSession.replaceDocument` (see the library documentation).
  Future<ReplaceResult> restore(String appId, String versionId, String clientId, {required int cseq});
}
