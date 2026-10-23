import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';

/// Dify's `createData`.
Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Datasource',
  'desc': '',
  'type': 'datasource',
  'plugin_id': 'plugin-id',
  'provider_type': DatasourceType.localFile,
  'provider_name': 'provider',
  'datasource_name': 'local-file',
  'datasource_label': 'Local File',
  'datasource_parameters': <String, Object?>{},
  'datasource_configurations': <String, Object?>{},
  'fileExtensions': ['pdf'],
  ...overrides,
};

const localFile = {
  'file': {
    'id': 'file-1',
    'name': 'doc.pdf',
    'type': 'document',
    'size': 12,
    'extension': 'pdf',
    'mime_type': 'application/pdf',
  },
};

/// The mocked hooks and services of the spec, recording their calls.
class FakeRun {
  final nodeDataUpdates = <Map<String, Object?>>[];
  final syncs = <int>[];
  final runs = <Map<String, Object?>>[];
  final inspectFetches = <List<String>>[];
  final appended = <List<Object?>>[];
  final runResults = <Map<String, Object?>?>[];
  final runAfterSingleRun = <bool>[];
  var invalidated = 0;
  var successes = 0;

  /// What the mocked `mutateAsync` does with the options: call `onSettled` with a result, or `onError`.
  Map<String, Object?>? settleWith;
  bool fail = false;

  final store = DataSourceRunStore()
    ..currentCredentialId = 'credential-1'
    ..bucket = 'drive-bucket';

  late final services = DataSourceRunServices(
    handleNodeDataUpdate: (id, data) => nodeDataUpdates.add({'id': id, 'data': data}),
    syncDraft: (onSuccess) {
      syncs.add(1);
      onSuccess();
    },
    runDatasource: (payload, {required onError, required onSettled}) {
      runs.add(payload);
      if (fail) {
        onError();
      } else if (settleWith != null) {
        onSettled(settleWith);
      }
    },
    invalidLastRun: () => invalidated++,
    fetchNodeInspectVars: (flowType, flowId, nodeId) async {
      inspectFetches.add([flowType, flowId, nodeId]);
      return [
        {'name': 'metadata'},
      ];
    },
    getNodes: () => [
      {
        'id': 'data-source-node',
        'data': {'title': 'Datasource'},
      },
    ],
  );

  DataSourceBeforeRun hook({
    Map<String, Object?>? payload,
    bool isPaused = false,
    bool isRunAfterSingleRun = false,
  }) => DataSourceBeforeRun(
    nodeId: 'data-source-node',
    flowId: 'flow-id',
    payload: payload ?? createData(),
    store: store,
    services: services,
    setRunResult: runResults.add,
    setIsRunAfterSingleRun: runAfterSingleRun.add,
    onSuccess: () => successes++,
    appendNodeInspectVars: (id, vars, nodes) => appended.add([id, vars, nodes]),
    isPaused: () => isPaused,
    isRunAfterSingleRun: isRunAfterSingleRun,
  );

  /// Lets the async result handling finish.
  Future<void> flush() => Future<void>.delayed(Duration.zero);
}
