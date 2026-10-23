/// Studio apps (docs/protocol.md section 2 "Apps", protocol 1.10): the workspace's app list (Dify 1.17.1's Studio
/// page) and the app-level calls around it, with **Dify's console API paths and shapes** under `/v1`.
///
/// ## Apps and documents
///
/// An app **is** a document: the app id is the document id (`/v1/apps/{id}` and `/v1/docs/{id}/...` name the same
/// thing), and the editor opens it like any document. Every document has exactly one app row (documents created
/// before 1.10 got one at the server's first 1.10 start: name from the imported file, else the document id). Name,
/// description, icon and "use icon as answer icon" live in the app row, not in the document: they change with
/// [AppsApi.update] (plain REST, last write wins, like Dify), not with ops; `GET /v1/docs/{id}/meta` and the export
/// read them from there.
///
/// ## What to use it for (the Studio page)
///
/// * **List**: [AppsApi.list] with an [AppListQuery] (Dify's `GET /apps`: `page`, `limit` 1-100, `mode`, `name`,
///   `sort_by`, `creator_ids`, `is_created_by_me`, `tag_ids`) -> [AppPage] (Dify's `AppPagination`). Infinite scroll:
///   request `page + 1` while [AppPage.hasMore]. **Starred row**: [AppsApi.starred] (same filters, Dify's
///   `GET /apps/starred`), [AppsApi.star] / [AppsApi.unstar] (per account, idempotent).
/// * **Create from blank**: [AppsApi.create] with mode [AppModes.workflow] or [AppModes.advancedChat] (other modes:
///   `400 unsupported_app_mode`). The new app is seeded like Dify's: a workflow gets a start node, a chatflow Dify's
///   chatflow template (start -> LLM -> answer, `retriever_resource` on). Then open the editor on [AppInfo.id].
/// * **Import DSL**: [AppsApi.importDsl] (Dify's `POST /apps/imports`, `yaml-content` only) -> [AppImport]: status
///   `completed` / `completed-with-warnings` (open [AppImport.appId]), `pending` (the file's DSL version needs
///   confirmation: show Dify's DSL confirm dialog with [AppImport.importedDslVersion] / [AppImport.currentDslVersion],
///   then [AppsApi.confirmImport] with [AppImport.id]; a pending import expires after 10 minutes, as Dify's), or
///   `failed` (not a usable file, or a mode dify-sf cannot run: [AppImport.error] is the message). Failed and pending
///   imports are answers, not exceptions.
/// * **Card menu**: Edit info = [AppsApi.update]; Duplicate = [AppsApi.copy] (the whole app at head, secrets included,
///   re-encrypted for the copy); Export = [AppsApi.exportDsl] (Dify's `{data: yaml}`; before exporting a workflow or
///   chatflow, read `DocsApi.meta(id).environmentVariables` and, if one has `value_type: secret`, ask as Dify's
///   `DSLExportConfirmModal` does, then pass `includeSecret`); Delete = [AppsApi.delete].
/// * **Detail**: [AppsApi.get] (Dify's `GET /apps/{id}`).
///
/// ## Shapes
///
/// [AppInfo] holds Dify's `AppPartial` / `AppDetailWithSite` members; [AppInfo.json] is the whole answer for anything
/// else. Times are Dify's epoch **seconds**. dify-sf differences: `tags` is always `[]` (no tags yet), `icon_url` is
/// always null (no file storage: image icons are not supported), `access_mode`, `maintainer`, `bound_agent_id` are
/// null, `has_draft_trigger` false, `model_config` null, `workflow` is the app's one draft (`id` = the app id,
/// `created_by`, `created_at`, `updated_by`, `updated_at`), `max_active_requests` is stored but unused. Since protocol
/// 1.11 `enable_site`, `enable_api`, `api_base_url` and `site` are real: read them with `AppInfoAccess`
/// (`access_api.dart`); servers older than 1.11 send `false` / `null`.
///
/// **Last modified** (`updated_at`, sort `last_modified`) is a documented deviation: Dify bumps it on app-row changes
/// only (draft saves touch the workflow row); dify-sf also bumps it on every committed graph edit (op), so "Edited
/// <time>" moves while people work. Ties sort by id.
///
/// ## Roles (Dify community edition, RBAC off)
///
/// Every member sees every app ([list], [starred], [get]) and stars for themselves. Writes ([create], [importDsl],
/// [confirmImport], [update], [copy], [delete], [exportDsl]) need `owner`, `admin` or `editor` (Dify's
/// `edit_permission_required`): others get `403 forbidden`; `includeSecret` additionally needs `owner` or `admin`
/// (protocol 1.8). [AppInfo.permissionKeys] are Dify's legacy per-app keys of the caller's role
/// ([AppPermissionKeys.forRole]): Dify's `getAppACLCapabilities` runs on them unchanged; `normal` and
/// `dataset_operator` get no `app.acl.view_layout`, so (as Dify's `getRedirectionPath`) a `normal` member lands on the
/// app's Overview and a `dataset_operator` on its Access Point (the app detail pages, protocol 1.11). The workspace key `app.create_and_management` (Create button, More menu) follows the role:
/// [AppPermissionKeys.canCreate].
///
/// ## Delete
///
/// [AppsApi.delete] is a soft delete: the app leaves every list, [get] and every `/v1/docs/{id}/...` call answer
/// `404 app_deleted` ([TransportExceptionApps.appDeleted]), the document's sequencer stops and open event streams end
/// (the next reconnect gets the 404). An open `CollabSession` on it then stops syncing for good and reports
/// `CollabSession.appDeleted` (its `changes` fire): the editor should tell the user, go back to the Studio and drop the
/// document's journal (its ops can never be committed).
///
/// ## Errors
///
/// Failures throw a `TransportException` with the server's code: `not_found` (404: unknown app), `app_deleted` (404),
/// `bad_request` (400: malformed body or query, empty name, description over 400 characters, unknown icon type),
/// `unsupported_app_mode` (400, [create]), `forbidden` (403), `unauthorized` (401), `secrets_key_missing` (503: copying
/// or importing an app with secrets on a server without a secrets key).
///
/// Implementations: `HttpAppsApi` (a real server) and `FakeAppsApi` (`package:collab_client/testing.dart`: in memory,
/// the same rules, one `FakeServer` per app for the editor).
library;

import 'client/transport.dart';

/// Dify's app modes (`AppModeEnum`) and the list filter's `all`.
abstract final class AppModes {
  static const workflow = 'workflow';

  /// Chatflow.
  static const advancedChat = 'advanced-chat';
  static const chat = 'chat';
  static const agentChat = 'agent-chat';
  static const completion = 'completion';

  /// List filter only: every mode (Dify: every mode but `agent`).
  static const all = 'all';

  /// What dify-sf can create, import and run (Dify's first two create cards, in Dify's order).
  static const creatable = [workflow, advancedChat];

  /// Every value the list's `mode` accepts (Dify's `AppListMode`). Modes dify-sf cannot create filter to an empty list.
  static const filters = [all, workflow, advancedChat, chat, agentChat, completion, 'agent', 'channel'];
}

/// Dify's `AppListSortBy`.
abstract final class AppSortBy {
  /// `updated_at` descending (default). See the library documentation for dify-sf's `updated_at`.
  static const lastModified = 'last_modified';

  /// `created_at` descending.
  static const recentlyCreated = 'recently_created';

  /// `created_at` ascending.
  static const earliestCreated = 'earliest_created';

  static const all = [lastModified, recentlyCreated, earliestCreated];
}

/// Dify's `IconType` values (`icon_type`).
abstract final class AppIconTypes {
  static const emoji = 'emoji';
  static const image = 'image';
  static const link = 'link';

  static const all = [emoji, image, link];
}

/// Dify's permission keys for apps (`rbac_service.py`, the legacy role lists used when RBAC is off).
abstract final class AppPermissionKeys {
  static const preview = 'app.acl.preview';
  static const viewLayout = 'app.acl.view_layout';
  static const testAndRun = 'app.acl.test_and_run';
  static const edit = 'app.acl.edit';
  static const importExportDsl = 'app.acl.import_export_dsl';
  static const delete = 'app.acl.delete';
  static const releaseAndVersion = 'app.acl.release_and_version';
  static const monitor = 'app.acl.monitor';
  static const accessConfig = 'app.acl.access_config';
  static const tracingConfig = 'app.acl.tracing_config';
  static const logAndAnnotation = 'app.acl.log_and_annotation';
  static const accessPointManage = 'app.acl.access_point_manage';
  static const accessPointView = 'app.acl.access_point_view';

  /// Workspace key: may create apps and use the card's More menu (owner, admin, editor).
  static const createAndManagement = 'app.create_and_management';

  /// Workspace key: may manage tags (owner, admin, editor; dify-sf has no tags yet).
  static const tagManage = 'app.tag.manage';

  static const _owner = [
    preview,
    viewLayout,
    testAndRun,
    edit,
    importExportDsl,
    delete,
    releaseAndVersion,
    monitor,
    accessConfig,
    tracingConfig,
    logAndAnnotation,
    accessPointManage,
    accessPointView,
  ];
  static const _editor = [
    preview,
    viewLayout,
    testAndRun,
    edit,
    importExportDsl,
    delete,
    releaseAndVersion,
    monitor,
    logAndAnnotation,
    accessConfig,
    accessPointManage,
    accessPointView,
  ];

  /// The per-app keys of [role] (Dify's `_LEGACY_APP_*_KEYS`, in Dify's order, duplicates removed): owner and admin
  /// everything, editor everything but `tracing_config`, normal `monitor` + `access_point_view`, dataset_operator
  /// `access_point_view`, anything else none. What the server puts in [AppInfo.permissionKeys].
  static List<String> forRole(String? role) => switch (role) {
    'owner' || 'admin' => _owner,
    'editor' => _editor,
    'normal' => const [monitor, accessPointView],
    'dataset_operator' => const [accessPointView],
    _ => const [],
  };

  /// The workspace's app keys of [role]: [createAndManagement] and [tagManage] for owner, admin and editor.
  static List<String> workspaceKeysForRole(String? role) =>
      canCreate(role) ? const [createAndManagement, tagManage] : const [];

  /// May create apps, import, edit info, duplicate, export and delete (Dify's `app.create_and_management`).
  static bool canCreate(String? role) => role == 'owner' || role == 'admin' || role == 'editor';
}

/// Dify's `Tag` (`{id, name, type}`). dify-sf has no tags yet: lists are always empty.
final class AppTag {
  const AppTag({required this.id, required this.name, required this.type});

  factory AppTag.fromJson(Map<String, Object?> m) =>
      AppTag(id: _str(m['id']), name: _str(m['name']), type: m['type'] is String ? m['type']! as String : 'app');

  final String id;
  final String name;
  final String type;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'type': type};
}

/// One app: Dify's `AppPartial` (list items) or `AppDetailWithSite` (detail, create, update, copy). See the library
/// documentation for the members dify-sf fills.
final class AppInfo {
  const AppInfo({
    required this.id,
    required this.name,
    this.description = '',
    required this.mode,
    this.iconType,
    this.icon,
    this.iconBackground,
    this.iconUrl,
    this.useIconAsAnswerIcon = false,
    this.maxActiveRequests,
    this.createdBy,
    this.createdAt = 0,
    this.updatedBy,
    this.updatedAt = 0,
    this.authorName,
    this.createUserName,
    this.tags = const [],
    this.permissionKeys = const [],
    this.isStarred = false,
    this.accessMode,
    this.json = const {},
  });

  factory AppInfo.fromJson(Map<String, Object?> m) => AppInfo(
    id: _str(m['id']),
    name: _str(m['name']),
    description: m['description'] is String ? m['description']! as String : '',
    mode: m['mode'] is String ? m['mode']! as String : AppModes.workflow,
    iconType: _optStr(m['icon_type']),
    icon: _optStr(m['icon']),
    iconBackground: _optStr(m['icon_background']),
    iconUrl: _optStr(m['icon_url']),
    useIconAsAnswerIcon: m['use_icon_as_answer_icon'] == true,
    maxActiveRequests: m['max_active_requests'] is num ? (m['max_active_requests']! as num).toInt() : null,
    createdBy: _optStr(m['created_by']),
    createdAt: m['created_at'] is num ? (m['created_at']! as num).toInt() : 0,
    updatedBy: _optStr(m['updated_by']),
    updatedAt: m['updated_at'] is num ? (m['updated_at']! as num).toInt() : 0,
    authorName: _optStr(m['author_name']),
    createUserName: _optStr(m['create_user_name']),
    tags: [
      if (m['tags'] case final List<Object?> ts)
        for (final t in ts)
          if (t is Map<String, Object?>) AppTag.fromJson(t),
    ],
    permissionKeys: [
      if (m['permission_keys'] case final List<Object?> ks)
        for (final k in ks)
          if (k is String) k,
    ],
    isStarred: m['is_starred'] == true,
    accessMode: _optStr(m['access_mode']),
    json: m,
  );

  /// The app id = the document id.
  final String id;
  final String name;

  /// `""` when there is none.
  final String description;

  /// [AppModes.workflow] or [AppModes.advancedChat].
  final String mode;

  /// [AppIconTypes]; null = Dify's default rendering.
  final String? iconType;

  /// The emoji id (`robot_face`) or character for `emoji`, else the image id / URL.
  final String? icon;

  /// `#FFEAD5` style, for `emoji`.
  final String? iconBackground;

  /// Always null on dify-sf (no file storage).
  final String? iconUrl;
  final bool useIconAsAnswerIcon;

  /// Stored, unused (no runtime).
  final int? maxActiveRequests;

  /// Account id of the creator.
  final String? createdBy;

  /// Epoch seconds.
  final int createdAt;

  /// Account id of the last one who changed the app row (create, edit info).
  final String? updatedBy;

  /// Epoch seconds; also bumped by every committed edit (see the library documentation).
  final int updatedAt;

  /// The creator's account name (Dify's `author_name`, the card's `<author> · Edited <time>`).
  final String? authorName;

  /// Same as [authorName] (Dify fills both).
  final String? createUserName;

  /// Always empty on dify-sf.
  final List<AppTag> tags;

  /// The caller's per-app keys ([AppPermissionKeys.forRole]).
  final List<String> permissionKeys;

  /// Starred by the signed-in account.
  final bool isStarred;

  /// Always null on dify-sf (no web-app auth).
  final String? accessMode;

  /// The whole answer object as the server sent it (Dify's member names).
  final Map<String, Object?> json;

  DateTime get createdTime => DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);
  DateTime get updatedTime => DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000, isUtc: true);

  /// The caller holds per-app permission [key] ([AppPermissionKeys]).
  bool can(String key) => permissionKeys.contains(key);

  /// May open the editor with edit rights (`app.acl.edit`); false = read-only (normal, dataset_operator).
  bool get canEdit => can(AppPermissionKeys.edit);

  bool get isChatflow => mode == AppModes.advancedChat;

  Map<String, Object?> toJson() => json.isNotEmpty
      ? json
      : {
          'id': id,
          'name': name,
          'description': description,
          'mode': mode,
          'icon_type': iconType,
          'icon': icon,
          'icon_background': iconBackground,
          'icon_url': iconUrl,
          'use_icon_as_answer_icon': useIconAsAnswerIcon,
          'max_active_requests': maxActiveRequests,
          'created_by': createdBy,
          'created_at': createdAt,
          'updated_by': updatedBy,
          'updated_at': updatedAt,
          'author_name': authorName,
          'create_user_name': createUserName,
          'tags': [for (final t in tags) t.toJson()],
          'permission_keys': permissionKeys,
          'is_starred': isStarred,
          'access_mode': accessMode,
        };

  @override
  String toString() => 'AppInfo($id, $name, $mode)';
}

/// Dify's `AppPagination`: one page of a list.
final class AppPage {
  const AppPage({
    required this.page,
    required this.limit,
    required this.total,
    required this.hasMore,
    required this.data,
  });

  factory AppPage.fromJson(Map<String, Object?> m) => AppPage(
    page: m['page'] is num ? (m['page']! as num).toInt() : 1,
    limit: m['limit'] is num ? (m['limit']! as num).toInt() : 20,
    total: m['total'] is num ? (m['total']! as num).toInt() : 0,
    hasMore: m['has_more'] == true,
    data: [
      if (m['data'] case final List<Object?> xs)
        for (final x in xs)
          if (x is Map<String, Object?>) AppInfo.fromJson(x),
    ],
  );

  final int page;
  final int limit;

  /// Apps matching the filters (all pages).
  final int total;

  /// There is a page after this one.
  final bool hasMore;
  final List<AppInfo> data;

  Map<String, Object?> toJson() => {
    'page': page,
    'limit': limit,
    'total': total,
    'has_more': hasMore,
    'data': [for (final a in data) a.toJson()],
  };
}

/// The query of [AppsApi.list] and [AppsApi.starred] (Dify's `AppListQuery`).
final class AppListQuery {
  const AppListQuery({
    this.page = 1,
    this.limit = 20,
    this.mode = AppModes.all,
    this.name,
    this.sortBy = AppSortBy.lastModified,
    this.creatorIds = const [],
    this.isCreatedByMe,
    this.tagIds = const [],
  });

  /// 1-99999.
  final int page;

  /// 1-100 (Dify's Studio asks for 30, its starred row for 100).
  final int limit;

  /// [AppModes.filters].
  final String mode;

  /// Case-insensitive substring of the app name; only the first 30 characters count (Dify's).
  final String? name;

  /// [AppSortBy].
  final String sortBy;

  /// Account ids: apps created by any of them.
  final List<String> creatorIds;

  /// true: only apps the caller created.
  final bool? isCreatedByMe;

  /// Accepted and ignored (no tags yet).
  final List<String> tagIds;

  AppListQuery copyWith({
    int? page,
    int? limit,
    String? mode,
    String? name,
    String? sortBy,
    List<String>? creatorIds,
    bool? isCreatedByMe,
    List<String>? tagIds,
  }) => AppListQuery(
    page: page ?? this.page,
    limit: limit ?? this.limit,
    mode: mode ?? this.mode,
    name: name ?? this.name,
    sortBy: sortBy ?? this.sortBy,
    creatorIds: creatorIds ?? this.creatorIds,
    isCreatedByMe: isCreatedByMe ?? this.isCreatedByMe,
    tagIds: tagIds ?? this.tagIds,
  );

  /// The query parameters (lists repeat the key: `creator_ids=a&creator_ids=b`, as Dify's web sends them).
  Map<String, List<String>> toQuery() => {
    'page': ['$page'],
    'limit': ['$limit'],
    'mode': [mode],
    if (name != null && name!.isNotEmpty) 'name': [name!],
    'sort_by': [sortBy],
    if (creatorIds.isNotEmpty) 'creator_ids': creatorIds,
    if (isCreatedByMe != null) 'is_created_by_me': ['$isCreatedByMe'],
    if (tagIds.isNotEmpty) 'tag_ids': tagIds,
  };
}

/// Dify's `ImportStatus`.
abstract final class AppImportStatus {
  static const completed = 'completed';
  static const completedWithWarnings = 'completed-with-warnings';
  static const pending = 'pending';
  static const failed = 'failed';
}

/// Dify's `AppImportResponse` / `Import`: the outcome of [AppsApi.importDsl] and [AppsApi.confirmImport].
final class AppImport {
  const AppImport({
    required this.id,
    required this.status,
    this.appId,
    this.appMode,
    required this.currentDslVersion,
    this.importedDslVersion = '',
    this.error = '',
    this.warnings = const [],
  });

  factory AppImport.fromJson(Map<String, Object?> m) => AppImport(
    id: _str(m['id']),
    status: m['status'] is String ? m['status']! as String : AppImportStatus.failed,
    appId: _optStr(m['app_id']),
    appMode: _optStr(m['app_mode']),
    currentDslVersion: _str(m['current_dsl_version']),
    importedDslVersion: _str(m['imported_dsl_version']),
    error: _str(m['error']),
    warnings: [
      if (m['warnings'] case final List<Object?> ws)
        for (final w in ws)
          if (w is Map<String, Object?>) w,
    ],
  );

  /// The import's id (for [AppsApi.confirmImport] when [pending]).
  final String id;

  /// [AppImportStatus].
  final String status;

  /// The new app (completed only).
  final String? appId;
  final String? appMode;

  /// The server's DSL version (Dify 1.17.1's `0.7.0`).
  final String currentDslVersion;

  /// The file's `version`.
  final String importedDslVersion;

  /// The reason when [failed] (Dify's message); `""` otherwise.
  final String error;

  /// Dify's `DslImportWarning` objects (dify-sf: always empty).
  final List<Map<String, Object?>> warnings;

  bool get completed => status == AppImportStatus.completed || status == AppImportStatus.completedWithWarnings;
  bool get pending => status == AppImportStatus.pending;
  bool get failed => status == AppImportStatus.failed;

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    'app_id': appId,
    'app_mode': appMode,
    'current_dsl_version': currentDslVersion,
    'imported_dsl_version': importedDslVersion,
    'error': error,
    'warnings': warnings,
  };
}

/// `TransportException` helpers for app answers.
extension TransportExceptionApps on TransportException {
  /// The app was deleted (`404 app_deleted`): also what every `/v1/docs/{id}/...` call of a deleted app answers.
  bool get appDeleted => statusCode == 404 && code == 'app_deleted';
}

/// See the library documentation above. [id] arguments are app ids (= document ids).
abstract interface class AppsApi {
  // ----- reads (any member) -----

  /// `GET /v1/apps`: one page of the workspace's apps.
  Future<AppPage> list([AppListQuery query = const AppListQuery()]);

  /// `GET /v1/apps/starred`: one page of the apps the signed-in account starred (same filters; Dify's starred row asks
  /// for `limit: 100`).
  Future<AppPage> starred([AppListQuery query = const AppListQuery(limit: 100)]);

  /// `GET /v1/apps/{id}`: Dify's `AppDetailWithSite`.
  Future<AppInfo> get(String id);

  /// `POST /v1/apps/{id}/star` (any member; idempotent).
  Future<void> star(String id);

  /// `DELETE /v1/apps/{id}/star` (any member; idempotent).
  Future<void> unstar(String id);

  // ----- writes (owner, admin, editor) -----

  /// `POST /v1/apps` `{name, description, mode, icon_type, icon, icon_background}` -> `201` detail. [name]: 1+
  /// characters (trimmed); [description]: at most 400 characters; [mode]: [AppModes.creatable]. Icon defaults: Dify's
  /// (`emoji`, `🤖`, `#FFEAD5`).
  Future<AppInfo> create({
    required String name,
    required String mode,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  });

  /// `POST /v1/apps/imports` `{mode: "yaml-content", yaml_content, name?, description?, icon_type?, icon?,
  /// icon_background?}`: a new app from a Dify DSL file; the overrides replace the file's `app` values.
  Future<AppImport> importDsl(
    String yamlContent, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  });

  /// `POST /v1/apps/imports/{importId}/confirm`: completes a `pending` import (same caller only; `404 not_found` once
  /// it expired or was used).
  Future<AppImport> confirmImport(String importId);

  /// `PUT /v1/apps/{id}` `{name, description, icon_type, icon, icon_background, use_icon_as_answer_icon,
  /// max_active_requests}` -> detail. Members left null keep their value.
  Future<AppInfo> update(
    String id, {
    required String name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
    bool? useIconAsAnswerIcon,
    int? maxActiveRequests,
  });

  /// `POST /v1/apps/{id}/copy` `{name?, description?, icon_type?, icon?, icon_background?}` -> `201` detail of the new
  /// app: the document at head, its variables, features and secrets (re-encrypted for the new id); the overrides
  /// replace the original's values (null = the original's). Created by the caller, not starred.
  Future<AppInfo> copy(
    String id, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  });

  /// `DELETE /v1/apps/{id}` -> `204`: soft delete (see the library documentation).
  Future<void> delete(String id);

  /// `GET /v1/apps/{id}/export?include_secret=` (`data`): the app as a Dify DSL file (YAML). Secret environment
  /// variables are `""` unless [includeSecret] (owner, admin).
  Future<String> exportDsl(String id, {bool includeSecret = false});
}

String _str(Object? v) => v is String ? v : '';
String? _optStr(Object? v) => v is String ? v : null;
