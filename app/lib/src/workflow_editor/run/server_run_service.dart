/// The server's workflow runtime in the editor (protocols 1.13–1.15): [ServerRunService] runs on the server what it
/// runs and leaves the rest to the editor's local stand-in, [MockWorkflowRunService]:
///
/// * **single runs and last runs** of the node types in `system-features`' `workflow_runtime.single_node_run`;
/// * **whole draft runs** (1.14, `workflow_runtime.draft_run`): a workflow whose node types the server all runs is run
///   there (Dify's SSE stream, stop, run history, run detail, tracing list); a graph with another node type (tool, knowledge, ... before their phases) stays on the stand-in, as do chatflow messages (P6), human input forms;
/// * **iteration / loop single runs** (1.15): containers listed in single_node_run use their dedicated SSE endpoints;
/// * the **variable inspect panel** (1.14): [ServerInspectServices], the server's draft variables (what the runs and
///   single runs saved).
///
/// Without a runtime on the server the editor keeps the stand-in alone, as before.
library;

import 'package:collab_client/collab_client.dart' show TransportException, WorkflowRunApi;

import '../store/workflow_store.dart' show DifyJson;
import '../variable_inspect/inspect_vars.dart' show VariableInspectServices;
import 'run_service.dart';

/// What the server's runtime offers a session: its run API and the node types it runs ([WorkflowRunApi],
/// [WorkflowRuntimeFeatures.singleNodeRun], [WorkflowRuntimeFeatures.draftRun]). An app detail service
/// (`AppDetailContext.service<ServerWorkflowRuntime>()`), present only when the server announces a runtime.
class ServerWorkflowRuntime {
  const ServerWorkflowRuntime({
    required this.api,
    required this.singleNodeRun,
    this.draftRun = const {},
    this.humanInput = false,
  });

  final WorkflowRunApi api;

  /// The node types (`data.type`) the server runs on their own.
  final Set<String> singleNodeRun;

  /// 1.14: the node types a whole draft run on the server supports (empty: a 1.13 server, no draft runs, history or
  /// draft variables there).
  final Set<String> draftRun;

  /// Whole runs, their records and the draft variables are the server's (protocol 1.14).
  bool get runsDrafts => draftRun.isNotEmpty;

  /// 1.16: the server runs human input (a draft run pauses at a `human-input` node, its form is submitted there, and a
  /// reconnect rebuilds the run's state). Without it forms belong to the editor's stand-in.
  final bool humanInput;
}

/// [WorkflowRunService] over the server's runtime for app [appId], [fallback] for the rest. [nodeTypeOf] answers a
/// node's `data.type` (null: unknown, which stays local); [graphNodeTypes] the types of every node of the draft (notes
/// left out), which decide where a whole run goes.
class ServerRunService extends WorkflowRunService {
  ServerRunService({
    required this.runtime,
    required this.appId,
    required this.fallback,
    required this.nodeTypeOf,
    this.graphNodeTypes = _noTypes,
  });

  final ServerWorkflowRuntime runtime;
  final String appId;
  final WorkflowRunService fallback;
  final String? Function(String nodeId) nodeTypeOf;
  final Iterable<String> Function() graphNodeTypes;

  static Iterable<String> _noTypes() => const [];

  bool _onServer(String nodeId) => runtime.singleNodeRun.contains(nodeTypeOf(nodeId));

  /// A whole run goes to the server when it runs every node type of the draft.
  bool get draftRunsOnServer {
    if (!runtime.runsDrafts) return false;
    final types = graphNodeTypes().toList();
    return types.isNotEmpty && types.every(runtime.draftRun.contains);
  }

  /// Runs of this session that went to the server (stop and records follow them).
  final _serverRuns = <String>{};

  /// The server's refusal as the run UI's error (its message is shown as Dify shows the API's message).
  static RunServiceException _refusal(TransportException e) => RunServiceException(e.message, code: e.code);

  @override
  Future<DifyJson> singleNodeRun(String nodeId, DifyJson body) async {
    if (!_onServer(nodeId)) return fallback.singleNodeRun(nodeId, body);
    try {
      return await runtime.api.singleNodeRun(appId, nodeId, body);
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Future<DifyJson?> fetchNodeLastRun(String nodeId) async {
    // 1.14: a node's last run may come from a whole run on the server too.
    if (!_onServer(nodeId) && !(runtime.runsDrafts && runtime.draftRun.contains(nodeTypeOf(nodeId)))) {
      return fallback.fetchNodeLastRun(nodeId);
    }
    try {
      return await runtime.api.nodeLastRun(appId, nodeId) ?? (await fallback.fetchNodeLastRun(nodeId));
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  // ---- whole draft runs (1.14) ----

  @override
  Stream<RunEvent> runWorkflowDraft(WorkflowDraftRunRequest request) async* {
    if (request.mode != TriggerType.userInput || !draftRunsOnServer) {
      yield* fallback.runWorkflowDraft(request);
      return;
    }
    try {
      await for (final payload in runtime.api.draftRun(appId, {
        'inputs': request.inputs,
        'files': request.body['files'] ?? const <Object?>[],
      })) {
        final event = RunEvent.fromJson(payload);
        if (event case WorkflowStartedEvent(:final taskId?)) _serverRuns.add(taskId);
        yield event;
      }
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Future<void> stopWorkflowRun(String taskId) async {
    if (!_serverRuns.contains(taskId)) return fallback.stopWorkflowRun(taskId);
    try {
      await runtime.api.stopRun(appId, taskId);
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Future<List<DifyJson>> fetchWorkflowRunHistory() async {
    if (!runtime.runsDrafts) return fallback.fetchWorkflowRunHistory();
    try {
      final page = await runtime.api.runHistory(appId, limit: 100);
      final server = [
        for (final r in page['data'] as List? ?? const [])
          if (r is Map<String, Object?>) r,
      ];
      // The stand-in's runs of this session (graphs the server does not run yet) still show.
      final local = await fallback.fetchWorkflowRunHistory();
      final all = [...server, ...local]..sort((a, b) => _num(b['created_at']).compareTo(_num(a['created_at'])));
      return all;
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  static num _num(Object? v) => v is num ? v : 0;

  bool _serverRun(String runId) => runtime.runsDrafts && !_localRun(runId);

  final _localRunIds = <String>{};
  bool _localRun(String runId) => _localRunIds.contains(runId);

  @override
  Future<DifyJson> fetchRunDetail(String runId) async {
    if (!_serverRun(runId)) return fallback.fetchRunDetail(runId);
    try {
      return await runtime.api.runDetail(appId, runId);
    } on TransportException catch (e) {
      if (e.statusCode == 404) {
        _localRunIds.add(runId);
        return fallback.fetchRunDetail(runId);
      }
      throw _refusal(e);
    }
  }

  @override
  Future<List<DifyJson>> fetchTracingList(String runId) async {
    if (!_serverRun(runId)) return fallback.fetchTracingList(runId);
    try {
      final list = await runtime.api.runNodeExecutions(appId, runId);
      // An unknown run answers an empty list (Dify): perhaps one of the stand-in's.
      return list.isEmpty ? await fallback.fetchTracingList(runId) : list;
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  // ---- the stand-in's ----

  @override
  Stream<RunEvent> sendChatMessage(ChatMessageRequest request) => fallback.sendChatMessage(request);

  /// 1.16: Dify's `handleResume`: re-subscribed when the run pauses, so the form's answer continues the run.
  @override
  Stream<RunEvent> workflowEvents(
    String workflowRunId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  }) async* {
    if (!runtime.humanInput) {
      yield* fallback.workflowEvents(
        workflowRunId,
        includeStateSnapshot: includeStateSnapshot,
        continueOnPause: continueOnPause,
      );
      return;
    }
    try {
      await for (final payload in runtime.api.workflowEvents(
        workflowRunId,
        includeStateSnapshot: includeStateSnapshot,
        continueOnPause: continueOnPause,
      )) {
        yield RunEvent.fromJson(payload);
      }
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Future<void> stopChatMessageResponding(String taskId) => fallback.stopChatMessageResponding(taskId);

  @override
  Future<List<String>> fetchSuggestedQuestions(String messageId) => fallback.fetchSuggestedQuestions(messageId);

  /// 1.16: the form's token names the run's pause on the server; without the capability the stand-in holds the form.
  @override
  Future<void> submitHumanInputForm(String formToken, DifyJson data) async {
    if (!runtime.humanInput) return fallback.submitHumanInputForm(formToken, data);
    try {
      await runtime.api.submitHumanInputForm(formToken, data);
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Stream<RunEvent> iterationSingleNodeRun(String nodeId, DifyJson body) => _containerRun('iteration', nodeId, body);

  @override
  Stream<RunEvent> loopSingleNodeRun(String nodeId, DifyJson body) => _containerRun('loop', nodeId, body);

  Stream<RunEvent> _containerRun(String kind, String nodeId, DifyJson body) async* {
    if (!_onServer(nodeId) || nodeTypeOf(nodeId) != kind) {
      yield* kind == 'iteration'
          ? fallback.iterationSingleNodeRun(nodeId, body)
          : fallback.loopSingleNodeRun(nodeId, body);
      return;
    }
    try {
      final payloads = kind == 'iteration'
          ? runtime.api.iterationSingleRun(appId, nodeId, body)
          : runtime.api.loopSingleRun(appId, nodeId, body);
      await for (final payload in payloads) {
        final event = RunEvent.fromJson(payload);
        if (event case WorkflowStartedEvent(:final taskId?)) _serverRuns.add(taskId);
        yield event;
      }
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Future<List<DifyJson>> fetchConversationVariables(String conversationId) =>
      fallback.fetchConversationVariables(conversationId);

  @override
  Future<List<DifyJson>> fetchChatMessages(String conversationId) => fallback.fetchChatMessages(conversationId);
}

/// The variable inspect panel over the server's draft variables (protocol 1.14, Dify's `/workflows/draft/variables`
/// API): what the server's runs and single runs saved for the signed-in account.
class ServerInspectServices extends VariableInspectServices {
  const ServerInspectServices({required this.api, required this.appId});

  final WorkflowRunApi api;
  final String appId;

  static RunServiceException _refusal(TransportException e) => RunServiceException(e.message, code: e.code);

  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  @override
  Future<List<DifyJson>> fetchAllInspectVars() => _call(() async {
    // Dify's list is paged (limit 100) without values; values come per node.
    final out = <DifyJson>[];
    for (var page = 1; page <= 50; page++) {
      final answer = await api.draftVariables(appId, page: page, limit: 100);
      final items = [
        for (final v in answer['items'] as List? ?? const [])
          if (v is Map<String, Object?>) v,
      ];
      out.addAll(items);
      if (items.length < 100) break;
    }
    // The panel groups node variables by their node; conversation and system variables have their own sections.
    return [
      for (final v in out)
        if (v['type'] == 'node') v,
    ];
  });

  @override
  Future<List<DifyJson>?> fetchNodeInspectVars(String nodeId) => _call(() => api.nodeVariables(appId, nodeId));

  @override
  Future<List<DifyJson>> fetchSystemVars() => _call(() => api.draftVariablesOfKind(appId, 'system'));

  @override
  Future<void> editInspectVar(String varId, Object? value) =>
      _call(() => api.updateDraftVariable(appId, varId, {'value': value}));

  @override
  Future<DifyJson?> resetToLastRunValue(String varId) => _call(() => api.resetDraftVariable(appId, varId));

  @override
  Future<void> deleteNodeInspectVars(String nodeId) => _call(() => api.deleteDraftVariables(appId, nodeId: nodeId));

  @override
  Future<void> deleteAllInspectVars() => _call(() => api.deleteDraftVariables(appId));
}
