/// The server's workflow runtime in the editor (protocol 1.13): [ServerRunService] runs a node's single run and reads
/// its last run on the server for the node types the server runs (`system-features`' `workflow_runtime.single_node_run`,
/// `llm` in 1.13) and leaves everything else (whole runs, chat, other node types, history, the variable inspect panel's
/// values) to the editor's local stand-in, [MockWorkflowRunService]. Without a runtime on the server the editor keeps
/// the stand-in alone, as before.
library;

import 'package:collab_client/collab_client.dart' show TransportException, WorkflowRunApi;

import '../store/workflow_store.dart' show DifyJson;
import 'run_service.dart';

/// What the server's runtime offers a session: its run API and the node types it runs ([WorkflowRunApi],
/// [WorkflowRuntimeFeatures.singleNodeRun]). An app detail service
/// (`AppDetailContext.service<ServerWorkflowRuntime>()`), present only when the server announces a runtime.
class ServerWorkflowRuntime {
  const ServerWorkflowRuntime({required this.api, required this.singleNodeRun});

  final WorkflowRunApi api;

  /// The node types (`data.type`) the server runs on their own.
  final Set<String> singleNodeRun;
}

/// [WorkflowRunService] over the server's runtime for [ServerWorkflowRuntime.singleNodeRun] node types of app [appId],
/// [fallback] for the rest. [nodeTypeOf] answers a node's `data.type` (null: unknown, which stays local).
class ServerRunService extends WorkflowRunService {
  ServerRunService({
    required this.runtime,
    required this.appId,
    required this.fallback,
    required this.nodeTypeOf,
  });

  final ServerWorkflowRuntime runtime;
  final String appId;
  final WorkflowRunService fallback;
  final String? Function(String nodeId) nodeTypeOf;

  bool _onServer(String nodeId) => runtime.singleNodeRun.contains(nodeTypeOf(nodeId));

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
    if (!_onServer(nodeId)) return fallback.fetchNodeLastRun(nodeId);
    try {
      return await runtime.api.nodeLastRun(appId, nodeId);
    } on TransportException catch (e) {
      throw _refusal(e);
    }
  }

  // Everything else is the stand-in's.

  @override
  Stream<RunEvent> runWorkflowDraft(WorkflowDraftRunRequest request) => fallback.runWorkflowDraft(request);

  @override
  Stream<RunEvent> sendChatMessage(ChatMessageRequest request) => fallback.sendChatMessage(request);

  @override
  Stream<RunEvent> workflowEvents(String workflowRunId) => fallback.workflowEvents(workflowRunId);

  @override
  Future<void> stopWorkflowRun(String taskId) => fallback.stopWorkflowRun(taskId);

  @override
  Future<void> stopChatMessageResponding(String taskId) => fallback.stopChatMessageResponding(taskId);

  @override
  Future<List<String>> fetchSuggestedQuestions(String messageId) => fallback.fetchSuggestedQuestions(messageId);

  @override
  Future<void> submitHumanInputForm(String formToken, DifyJson data) => fallback.submitHumanInputForm(formToken, data);

  @override
  Stream<RunEvent> iterationSingleNodeRun(String nodeId, DifyJson body) =>
      fallback.iterationSingleNodeRun(nodeId, body);

  @override
  Stream<RunEvent> loopSingleNodeRun(String nodeId, DifyJson body) => fallback.loopSingleNodeRun(nodeId, body);

  @override
  Future<List<DifyJson>> fetchWorkflowRunHistory() => fallback.fetchWorkflowRunHistory();

  @override
  Future<DifyJson> fetchRunDetail(String runId) => fallback.fetchRunDetail(runId);

  @override
  Future<List<DifyJson>> fetchTracingList(String runId) => fallback.fetchTracingList(runId);

  @override
  Future<List<DifyJson>> fetchConversationVariables(String conversationId) =>
      fallback.fetchConversationVariables(conversationId);

  @override
  Future<List<DifyJson>> fetchChatMessages(String conversationId) => fallback.fetchChatMessages(conversationId);
}
