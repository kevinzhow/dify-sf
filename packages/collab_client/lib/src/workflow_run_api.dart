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

/// The run operations of the workflow runtime (protocol 1.13).
abstract class WorkflowRunApi {
  /// `POST /v1/apps/{app}/workflows/draft/nodes/{node}/run` with Dify's body (`{"inputs": {...}}`): the execution
  /// (Dify's `WorkflowRunNodeExecutionResponse`).
  Future<Map<String, Object?>> singleNodeRun(String appId, String nodeId, Map<String, Object?> body);

  /// `GET /v1/apps/{app}/workflows/draft/nodes/{node}/last-run`: the node's newest execution, null without one.
  Future<Map<String, Object?>?> nodeLastRun(String appId, String nodeId);
}
