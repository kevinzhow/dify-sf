/// The workflow runtime (docs/protocol.md section 2 "Runtime", protocol 1.13): running one node of an app's draft on
/// the server, with **Dify 1.17.1's console API paths and shapes** under `/v1` (`api/controllers/console/app/workflow.py`:
/// `workflows/draft/nodes/{node_id}/run`, `.../last-run`).
///
/// ## Discovery
///
/// A server with a runtime says so in `GET /v1/system-features` ([SystemFeatures.workflowRuntime]): the node types it
/// runs ([WorkflowRuntimeFeatures.singleNodeRun], `["llm"]` in 1.13). A server without it (older, or without a plugin
/// daemon) has none; clients keep their local stand-in for every node then, and for the node types not listed.
///
/// ## What to use it for
///
/// * **Run this step** (a node's single run): [WorkflowRunApi.singleNodeRun] with Dify's body `{"inputs": {...}}` (keys
///   as Dify's single-run form sends them: `#node.var#`, `#context#`). The answer is Dify's
///   `WorkflowRunNodeExecutionResponse` JSON (NodeTracing: `status`, `inputs`, `process_data`, `outputs`, `error`,
///   `elapsed_time`, `execution_metadata`, `created_by_account`, ...), also when the node failed (`status: failed`,
///   `error`). The run reads the document at its current seq and writes no ops.
/// * **Last run** tab: [WorkflowRunApi.nodeLastRun], the node's newest execution in the same shape; null when it has
///   none (`404`).
///
/// ## Errors
///
/// `TransportException` with the server's code: `invalid_param` (400: a value the node reads is missing from `inputs`,
/// or the model cannot be prepared: Dify's message), `unsupported_node_type` (400), `model_runtime_not_configured`
/// (400), `not_found` (404: unknown node), `app_not_found` (404: an app of another mode), `forbidden` (403: running
/// needs `owner`, `admin` or `editor`; the last run any member), `unauthorized` (401).
///
/// Implementations: `HttpWorkflowRunApi` and `FakeWorkflowRunApi` (`package:collab_client/testing.dart`).
library;

/// ## Draft runs (1.14)
///
/// * **Test run**: [WorkflowRunApi.draftRun] streams Dify's SSE events of `POST .../workflows/draft/run` (`{"inputs":
///   {...}, "files": []}`) as decoded JSON payloads (`{"event", "workflow_run_id", "task_id", "data"}`: Dify's
///   `workflow_started`, `node_started`, `text_chunk`, `node_retry`, `node_finished`, `reasoning_chunk`,
///   `workflow_finished`); pings are dropped. Refusals before the stream starts are `TransportException`s
///   (`invalid_param`, `unsupported_node_type`, `model_runtime_not_configured`, `runtime_service_not_configured`).
///   [WorkflowRunApi.stopRun] stops it (`task_id`). Cancelling the subscription does not stop the run on the server.
/// * **Run history**: [WorkflowRunApi.runHistory], [WorkflowRunApi.runDetail], [WorkflowRunApi.runNodeExecutions]
///   (Dify's `WorkflowRunPaginationResponse`, `WorkflowRunDetailResponse`, NodeTracing list).
/// * **Variable inspect**: the draft variable endpoints ([WorkflowRunApi.draftVariables] and the rest), Dify's JSON.
///
/// The run operations of the workflow runtime (protocol 1.13, 1.14).
abstract class WorkflowRunApi {
  /// `POST /v1/apps/{app}/workflows/draft/nodes/{node}/run` with Dify's body (`{"inputs": {...}}`): the execution
  /// (Dify's `WorkflowRunNodeExecutionResponse`).
  Future<Map<String, Object?>> singleNodeRun(String appId, String nodeId, Map<String, Object?> body);

  /// `GET /v1/apps/{app}/workflows/draft/nodes/{node}/last-run`: the node's newest execution, null without one.
  Future<Map<String, Object?>?> nodeLastRun(String appId, String nodeId);

  /// 1.14: `POST /v1/apps/{app}/workflows/draft/run` (Dify's body `{"inputs": {...}, "files": []}`): the SSE payloads.
  Stream<Map<String, Object?>> draftRun(String appId, Map<String, Object?> body);

  /// 1.14: `POST /v1/apps/{app}/workflow-runs/tasks/{task}/stop`.
  Future<void> stopRun(String appId, String taskId);

  /// 1.14: `GET /v1/apps/{app}/workflow-runs` (`{limit, has_more, data}`, newest first; `lastId` = the page after it).
  Future<Map<String, Object?>> runHistory(String appId, {String? lastId, int limit = 20});

  /// 1.14: `GET /v1/apps/{app}/workflow-runs/{run}` (Dify's `WorkflowRunDetailResponse`).
  Future<Map<String, Object?>> runDetail(String appId, String runId);

  /// 1.14: `GET /v1/apps/{app}/workflow-runs/{run}/node-executions` (`data`, oldest first).
  Future<List<Map<String, Object?>>> runNodeExecutions(String appId, String runId);

  /// 1.14: `GET .../workflows/draft/variables?page=&limit=` (`{items, total}`, values omitted).
  Future<Map<String, Object?>> draftVariables(String appId, {int page = 1, int limit = 20});

  /// 1.14: `GET .../workflows/draft/nodes/{node}/variables` (`items` with values).
  Future<List<Map<String, Object?>>> nodeVariables(String appId, String nodeId);

  /// 1.14: `GET .../workflows/draft/conversation-variables`, `.../system-variables`, `.../environment-variables`
  /// (`kind`: `conversation`, `system`, `environment`): `items`.
  Future<List<Map<String, Object?>>> draftVariablesOfKind(String appId, String kind);

  /// 1.14: `GET .../workflows/draft/variables/{id}`.
  Future<Map<String, Object?>> draftVariable(String appId, String variableId);

  /// 1.14: `PATCH .../workflows/draft/variables/{id}` with Dify's body (`name` and / or `value`; marks it `edited`).
  Future<Map<String, Object?>> updateDraftVariable(String appId, String variableId, Map<String, Object?> patch);

  /// 1.14: `PUT .../workflows/draft/variables/{id}/reset`: the variable as reset, null when it was removed.
  Future<Map<String, Object?>?> resetDraftVariable(String appId, String variableId);

  /// 1.14: `DELETE .../workflows/draft/variables/{id}`, `.../nodes/{node}/variables` (nodeId), or all (neither).
  Future<void> deleteDraftVariables(String appId, {String? variableId, String? nodeId});
}
