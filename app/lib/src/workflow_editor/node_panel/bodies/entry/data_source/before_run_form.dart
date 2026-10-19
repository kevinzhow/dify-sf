/// The data source's single-run form (nodes/data-source/before-run-form.tsx, hooks/use-before-run-form.ts): the
/// preparation step of its type (local file, online documents, website crawl, online drive; built by the host), then
/// Cancel and "Start Run", which syncs the draft and runs the data source.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/node_config.dart' show Json;

/// `DatasourceType` (models/pipeline.ts).
abstract final class DatasourceType {
  static const localFile = 'local_file';
  static const onlineDocument = 'online_document';
  static const websiteCrawl = 'website_crawl';
  static const onlineDrive = 'online_drive';
}

/// `NodeRunningStatus` values the form writes.
abstract final class NodeRunningStatus {
  static const notStart = 'not-start';
  static const running = 'running';
  static const succeeded = 'succeeded';
  static const failed = 'failed';
}

/// The data source store of the preparation step (datasets/documents/create-from-pipeline/data-source/store): what
/// the preparation widgets select, and the credential in use.
class DataSourceRunStore extends ChangeNotifier {
  String currentCredentialId = '';

  /// `[{file: {id, name, type, size, extension, mime_type}}]`.
  List<Json> localFileList = [];
  List<Json> onlineDocuments = [];
  List<Json> websitePages = [];
  List<String> selectedFileIds = [];

  /// `[{id, type, …}]`.
  List<Json> onlineDriveFileList = [];
  String bucket = '';

  void update(void Function(DataSourceRunStore s) change) {
    change(this);
    notifyListeners();
  }

  void setCurrentCredentialId(String id) => update((s) => s.currentCredentialId = id);

  /// useOnlineDocument's `clearOnlineDocumentData`.
  void clearOnlineDocumentData() => update((s) => s.onlineDocuments = []);

  /// useWebsiteCrawl's `clearWebsiteCrawlData`.
  void clearWebsiteCrawlData() => update((s) => s.websitePages = []);

  /// useOnlineDrive's `clearOnlineDriveData`.
  void clearOnlineDriveData() => update((s) {
    s.onlineDriveFileList = [];
    s.bucket = '';
    s.selectedFileIds = [];
  });
}

/// The editor and backend calls of a single run (Dify's hooks and services).
class DataSourceRunServices {
  const DataSourceRunServices({
    required this.handleNodeDataUpdate,
    required this.syncDraft,
    required this.runDatasource,
    required this.invalidLastRun,
    required this.fetchNodeInspectVars,
    required this.getNodes,
  });

  /// `handleNodeDataUpdate({id, data})`.
  final void Function(String id, Json data) handleNodeDataUpdate;

  /// `handleSyncWorkflowDraft(true, true, {onSuccess})`.
  final void Function(VoidCallback onSuccess) syncDraft;

  /// `useDatasourceSingleRun().mutateAsync(payload, {onError, onSettled})`.
  final void Function(Json payload, {required VoidCallback onError, required void Function(Json? data) onSettled})
  runDatasource;

  /// `useInvalidLastRun`.
  final VoidCallback invalidLastRun;

  /// `fetchNodeInspectVars(flowType, flowId, nodeId)`.
  final Future<List<Object?>> Function(String flowType, String flowId, String nodeId) fetchNodeInspectVars;

  /// The canvas nodes (`getNodes()`).
  final List<Object?> Function() getNodes;
}

/// useBeforeRunForm: the Start Run state and action for the data source [payload] (`CustomRunFormProps`).
class DataSourceBeforeRun {
  DataSourceBeforeRun({
    required this.nodeId,
    required this.flowId,
    required this.payload,
    required this.store,
    required this.services,
    required this.setRunResult,
    required this.setIsRunAfterSingleRun,
    required this.onSuccess,
    required this.appendNodeInspectVars,
    this.isPaused = _notPaused,
    this.isRunAfterSingleRun = false,
  });

  static bool _notPaused() => false;

  final String nodeId, flowId;
  final Json payload;
  final DataSourceRunStore store;
  final DataSourceRunServices services;
  final ValueChanged<Json?> setRunResult;
  final ValueChanged<bool> setIsRunAfterSingleRun;
  final VoidCallback onSuccess;
  final void Function(String nodeId, List<Object?> vars, List<Object?> nodes) appendNodeInspectVars;

  /// `isPausedRef.current`.
  final bool Function() isPaused;
  final bool isRunAfterSingleRun;

  String get datasourceType => '${payload['provider_type'] ?? ''}';

  /// `startRunBtnDisabled`: nothing (or a local file still uploading) is selected.
  bool get startRunBtnDisabled => switch (datasourceType) {
    DatasourceType.localFile =>
      store.localFileList.isEmpty || store.localFileList.any((f) => !jsTruthy(jsGet(f['file'], 'id'))),
    DatasourceType.onlineDocument => store.onlineDocuments.isEmpty,
    DatasourceType.websiteCrawl => store.websitePages.isEmpty,
    DatasourceType.onlineDrive => store.selectedFileIds.isEmpty,
    _ => false,
  };

  String get _runningStatus => jsStr(payload['_singleRunningStatus']) ?? NodeRunningStatus.notStart;

  /// `datasource_info` of the run, per type.
  Json datasourceInfo() {
    final credentialId = store.currentCredentialId;
    switch (datasourceType) {
      case DatasourceType.localFile:
        final file = (store.localFileList.first['file'] as Map).cast<String, Object?>();
        return {
          'related_id': file['id'],
          'name': file['name'],
          'type': file['type'],
          'size': file['size'],
          'extension': file['extension'],
          'mime_type': file['mime_type'],
          'url': '',
          'transfer_method': 'local_file',
        };
      case DatasourceType.onlineDocument:
        final doc = {...store.onlineDocuments.first};
        final workspaceId = doc.remove('workspace_id');
        return {'workspace_id': workspaceId, 'page': doc, 'credential_id': credentialId};
      case DatasourceType.websiteCrawl:
        return {...store.websitePages.first, 'credential_id': credentialId};
      case DatasourceType.onlineDrive:
        final id = store.selectedFileIds.firstOrNull;
        final file = store.onlineDriveFileList.where((f) => f['id'] == id).firstOrNull;
        return {'bucket': store.bucket, 'id': file?['id'], 'type': file?['type'], 'credential_id': credentialId};
    }
    return {};
  }

  Future<void> _updateRunResult(Json? data) async {
    // The backend can't pause a single run; the form drops the result while paused.
    if (isPaused()) return;
    final canRunLastRun = !isRunAfterSingleRun || _runningStatus == NodeRunningStatus.succeeded;
    if (!canRunLastRun) {
      setRunResult(data);
      return;
    }
    // A failed run may update the inspect vars too (error default outputs).
    final vars = await services.fetchNodeInspectVars('ragPipeline', flowId, nodeId);
    appendNodeInspectVars(nodeId, vars, services.getNodes());
    if (data?['status'] == NodeRunningStatus.succeeded) onSuccess();
  }

  void _handleRun() {
    var hasError = false;
    services.runDatasource(
      {
        'pipeline_id': flowId,
        'start_node_id': nodeId,
        'start_node_title': payload['title'],
        'datasource_type': datasourceType,
        'datasource_info': datasourceInfo(),
      },
      onError: () {
        hasError = true;
        services.invalidLastRun();
        if (isPaused()) return;
        services.handleNodeDataUpdate(nodeId, {
          ...payload,
          '_isSingleRun': false,
          '_singleRunningStatus': NodeRunningStatus.failed,
        });
      },
      onSettled: (data) {
        _updateRunResult(data);
        if (!hasError && !isPaused()) {
          services.handleNodeDataUpdate(nodeId, {
            ...payload,
            '_isSingleRun': false,
            '_singleRunningStatus': NodeRunningStatus.succeeded,
          });
        }
      },
    );
  }

  /// `handleRunWithSyncDraft`: marks the node running, then syncs the draft and runs.
  void handleRunWithSyncDraft() {
    services.handleNodeDataUpdate(nodeId, {...payload, '_singleRunningStatus': NodeRunningStatus.running});
    setIsRunAfterSingleRun(true);
    services.syncDraft(_handleRun);
  }
}

/// What a preparation widget gets (LocalFile, OnlineDocuments, WebsiteCrawl, OnlineDrive).
class DataSourcePreparationArgs {
  const DataSourcePreparationArgs({
    required this.nodeId,
    required this.nodeData,
    required this.store,
    required this.onCredentialChange,
  });
  final String nodeId;
  final Json nodeData;
  final DataSourceRunStore store;
  final ValueChanged<String> onCredentialChange;

  /// LocalFile's `allowedExtensions`.
  List<String> get allowedExtensions => [for (final e in jsList(nodeData['fileExtensions'])) '$e'];
}

/// The host's preparation step for a data source type; batch upload is always off here.
typedef DataSourcePreparationBuilder = Widget Function(
  BuildContext context,
  String datasourceType,
  DataSourcePreparationArgs args,
);

/// BeforeRunForm in its PanelWrap ("Test Run" and the node title and a close button over the panel).
class DataSourceBeforeRunForm extends StatelessWidget {
  const DataSourceBeforeRunForm({
    super.key,
    required this.beforeRun,
    required this.onCancel,
    this.preparation,
    this.isPending = false,
  });

  /// The form's state and run action (useBeforeRunForm).
  final DataSourceBeforeRun beforeRun;
  final VoidCallback onCancel;
  final DataSourcePreparationBuilder? preparation;
  final bool isPending;

  Json get payload => beforeRun.payload;
  DataSourceRunStore get store => beforeRun.store;

  String get _type => '${payload['provider_type'] ?? ''}';

  /// `handleCredentialChange`: clears the type's selection, then switches the credential.
  void _credentialChange(String id) {
    switch (_type) {
      case DatasourceType.onlineDocument:
        store.clearOnlineDocumentData();
      case DatasourceType.websiteCrawl:
        store.clearWebsiteCrawlData();
      case DatasourceType.onlineDrive:
        store.clearOnlineDriveData();
    }
    store.setCurrentCredentialId(id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final disabled = beforeRun.startRunBtnDisabled;
      final args = DataSourcePreparationArgs(
        nodeId: beforeRun.nodeId,
        nodeData: payload,
        store: store,
        onCredentialChange: _credentialChange,
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
              child: SizedBox(
                height: 20,
                child: Row(
                  children: [
                    Flexible(
                      child: Row(
                        children: [
                          DifyText(
                            '${DifyI18n.tr('workflow', 'singleRun.testRun')} ',
                            DifyType.systemMdSemibold,
                            color: DifyColors.textPrimary,
                          ),
                          Flexible(
                            child: DifyText(
                              '${payload['title'] ?? ''}',
                              DifyType.systemMdSemibold,
                              color: DifyColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    DifyIconButton(
                      label: DifyI18n.tr('common', 'operation.close'),
                      onPressed: onCancel,
                      icon: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  if (preparation != null &&
                      const {
                        DatasourceType.localFile,
                        DatasourceType.onlineDocument,
                        DatasourceType.websiteCrawl,
                        DatasourceType.onlineDrive,
                      }.contains(_type))
                    preparation!(context, _type, args),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    spacing: 8,
                    children: [
                      DifyButton(onPressed: onCancel, child: Text(DifyI18n.tr('common', 'operation.cancel'))),
                      DifyButton(
                        variant: DifyButtonVariant.primary,
                        onPressed: beforeRun.handleRunWithSyncDraft,
                        loading: isPending,
                        disabled: disabled,
                        child: Text(DifyI18n.tr('workflow', 'singleRun.startRun')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
