import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import '../design/widgets/toast.dart';
import '../i18n/dify_i18n.dart';
import '../studio/studio_scope.dart' show SaveDslFile, saveDslFile;
import '../workflow_editor/header/publisher/summary_section.dart' show PublishedWorkflowInfo;
import '../workflow_editor/store/workflow_store.dart' show DifyJson;
import '../workflow_editor/version_history/version_history_panel.dart' show VersionHistoryPage;
import 'editor_controller.dart';

/// The editor's publishing and version history on the server (protocol 1.11, [VersionsApi]): what Dify's workflow
/// app gets from `useAppWorkflow`, `usePublishWorkflow`, `useWorkflowVersionHistory`, the version update / delete /
/// restore requests and useWorkflowRun's draft backup while versions are browsed.
///
/// * [published] is the app's published version (null: never published), fetched when the editor opens and after
///   every publish or version edit; the header shows "Published <time>" and the publisher its summary from it.
/// * Browsing versions shows the clicked version read-only on the canvas ([showVersion], an [EditorController.preview]
///   of the version's graph and variables) and the live document again with [showDraft]; the session keeps syncing
///   underneath.
/// * [restore] replaces the draft with a version through the session's replacement path
///   (`CollabSession.replaceDocument` + `POST /v1/apps/{app}/workflows/{version}/restore`): ordinary ops of this
///   client, so collaborators see the restore like any import; the version's secrets stay on the server.
class EditorVersions extends ChangeNotifier {
  EditorVersions({
    required this.api,
    required this.controller,
    String? appId,
    this.appName = '',
    this.saveDsl = saveDslFile,
  }) : appId = appId ?? controller.docId;

  /// The app's name: an exported version is saved as `<name>.yml` (Dify's `handleExportDSL`).
  String appName;
  final SaveDslFile saveDsl;

  final VersionsApi api;
  final EditorController controller;

  /// The app (= the document).
  final String appId;

  WorkflowVersion? _published;
  bool _loaded = false;
  bool _disposed = false;

  /// The published version; null: never published (or not loaded yet, see [loaded]).
  WorkflowVersion? get published => _published;

  /// Whether [published] has been fetched at least once.
  bool get loaded => _loaded;

  /// The publisher's view of [published].
  PublishedWorkflowInfo? get publishedInfo => switch (_published) {
    final v? => PublishedWorkflowInfo.fromJson(v.toJson()),
    null => null,
  };

  /// `useAppWorkflow` (and `useInvalidateAppWorkflow`): (re)reads the published version. Failures keep what was known.
  Future<void> refreshPublished() async {
    try {
      final v = await api.published(appId);
      if (_disposed) return;
      _published = v;
      _loaded = true;
      notifyListeners();
    } on Object {
      // Dify logs the failed query and keeps its data.
    }
  }

  /// "Publish update" (`POST .../workflows/publish`): Dify's `{result, created_at}`; then [published] is refetched.
  Future<DifyJson> publish({String title = '', String releaseNotes = ''}) async {
    final r = await api.publish(appId, markedName: title, markedComment: releaseNotes);
    await refreshPublished();
    return {'result': r.result, 'created_at': r.createdAt};
  }

  /// A page of the version list (the draft first, then versions newest first; nothing before the first publish).
  Future<VersionHistoryPage> fetchVersions({
    required int page,
    required int limit,
    required String userId,
    required bool namedOnly,
  }) async {
    final r = await api.list(
      appId,
      page: page,
      limit: limit,
      userId: userId.isEmpty ? null : userId,
      namedOnly: namedOnly,
    );
    return (items: [for (final v in r.items) v.toJson()], hasMore: r.hasMore);
  }

  /// Names a version and sets its release notes (the publisher's and the panel's version info dialog).
  Future<void> updateVersion(String versionId, {required String title, required String releaseNotes}) async {
    await api.update(appId, versionId, markedName: title, markedComment: releaseNotes);
    if (versionId == _published?.id) await refreshPublished();
  }

  Future<void> deleteVersion(String versionId) => api.delete(appId, versionId);

  /// Replaces the draft with version [versionId] (the session's replacement: it waits for this client's unsent edits,
  /// then the server commits the version as this client's ops). The undo history does not reach across it (as after an
  /// import), and the live document shows again.
  Future<void> restore(String versionId) async {
    await controller.session.replaceDocument((clientId, cseq) => api.restore(appId, versionId, clientId, cseq: cseq));
    if (_disposed) return;
    controller.undo.clear();
    showDraft();
  }

  /// useWorkflowRun's handleRestoreFromPublishedWorkflow: the version (`GET .../workflows/{id}`, its document) on the
  /// canvas, read-only. A version that cannot be read keeps the current view; a later click wins over an earlier one.
  Future<void> showVersion(DifyJson version) async {
    final id = '${version['id'] ?? ''}';
    final shown = ++_shown;
    Document? doc;
    try {
      doc = (await api.get(appId, id)).document;
    } on Object {
      return;
    }
    if (_disposed || shown != _shown || doc == null) return;
    controller.preview(doc);
  }

  int _shown = 0;

  /// useWorkflowRun's handleLoadBackupDraft: the live document again.
  void showDraft() {
    _shown++;
    controller.preview(null);
  }

  bool _exporting = false;

  /// The version panel's Export (use-DSL.ts `handleExportDSL(false, versionId)`): the version as a Dify file without
  /// secret values, saved as `<app name>.yml`; Dify's "Export failed" toast when it fails.
  Future<void> exportVersion(String versionId) async {
    if (_exporting) return;
    _exporting = true;
    try {
      final yaml = await api.exportDsl(appId, versionId);
      await saveDsl('$appName.yml', yaml);
    } on Object {
      toast.error(DifyI18n.tr('app', 'exportFailed'));
    } finally {
      _exporting = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Dify's `hasConnectedUserInput` over a published graph (use-workflow-init.ts): a Start node with an outgoing edge.
bool publishedGraphHasUserInput(Map<String, Object?> graph) {
  final nodes = graph['nodes'], edges = graph['edges'];
  if (nodes is! List || edges is! List) return false;
  final starts = {
    for (final n in nodes)
      if (n is Map && n['data'] is Map && (n['data'] as Map)['type'] == 'start') n['id'],
  };
  return edges.any((e) => e is Map && starts.contains(e['source']));
}
