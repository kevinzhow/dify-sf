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
/// ## Human input (1.16)
///
/// * **A paused run**: a draft run with a `human-input` node streams `human_input_required` (`data` is the form) and
///   `workflow_paused`, then keeps the connection open. The form is answered with
///   [WorkflowRunApi.submitHumanInputForm] (Dify's `service/workflow.ts` `submitHumanInputForm`), and the run's events
///   continue; a client that lost the connection follows them with [WorkflowRunApi.workflowEvents] (Dify's
///   `sseGet('/workflow/{run_id}/events?include_state_snapshot=true&continue_on_pause=true')`, its `handleResume`).
///   [WorkflowRunApi.humanInputForm] reads a form by the token a delivery hands out (the console's form API: a form of
///   another surface, or of another workspace, is `404`).
/// * **A human-input node's own form** (the panel's single run): [WorkflowRunApi.humanInputFormPreview] renders it from
///   the node's config and the values it asks for, [WorkflowRunApi.humanInputFormRun] submits it (no run: the answers
///   become the node's draft variables). The panel's test email is not served yet (it needs a form a delivery test can
///   own, which this server's forms require a run for).
///
/// The run operations of the workflow runtime (protocols 1.13–1.16).
abstract class WorkflowRunApi {
  /// Durable Chatflow debugger. Older servers do not advertise `chatflow`.
  Stream<Map<String, Object?>> chatDraftRun(
    String appId,
    Map<String, Object?> body,
  );
  Future<void> stopChatRun(String appId, String taskId);
  Future<List<Map<String, Object?>>> chatMessages(
    String appId,
    String conversationId,
  );
  Future<List<Map<String, Object?>>> conversationVariables(
    String appId,
    String conversationId,
  );

  /// `POST /v1/apps/{app}/workflows/draft/nodes/{node}/run` with Dify's body (`{"inputs": {...}}`): the execution
  /// (Dify's `WorkflowRunNodeExecutionResponse`).
  Future<Map<String, Object?>> singleNodeRun(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  );

  /// `GET /v1/apps/{app}/workflows/draft/nodes/{node}/last-run`: the node's newest execution, null without one.
  Future<Map<String, Object?>?> nodeLastRun(String appId, String nodeId);

  /// 1.14: `POST /v1/apps/{app}/workflows/draft/run` (Dify's body `{"inputs": {...}, "files": []}`): the SSE payloads.
  Stream<Map<String, Object?>> draftRun(
    String appId,
    Map<String, Object?> body,
  );

  /// 1.15: `POST .../workflows/draft/iteration/nodes/{node}/run`, the same SSE payloads as a draft run.
  Stream<Map<String, Object?>> iterationSingleRun(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  );

  /// 1.15: `POST .../workflows/draft/loop/nodes/{node}/run`. Discovery lists `iteration` / `loop` in single_node_run;
  /// these containers use their dedicated endpoints rather than the generic JSON single-node endpoint.
  Stream<Map<String, Object?>> loopSingleRun(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  );

  /// 1.14: `POST /v1/apps/{app}/workflow-runs/tasks/{task}/stop`.
  Future<void> stopRun(String appId, String taskId);

  /// 1.14: `GET /v1/apps/{app}/workflow-runs` (`{limit, has_more, data}`, newest first; `lastId` = the page after it).
  Future<Map<String, Object?>> runHistory(
    String appId, {
    String? lastId,
    int limit = 20,
  });

  /// 1.14: `GET /v1/apps/{app}/workflow-runs/{run}` (Dify's `WorkflowRunDetailResponse`).
  Future<Map<String, Object?>> runDetail(String appId, String runId);

  /// 1.14: `GET /v1/apps/{app}/workflow-runs/{run}/node-executions` (`data`, oldest first).
  Future<List<Map<String, Object?>>> runNodeExecutions(
    String appId,
    String runId,
  );

  /// 1.14: `GET .../workflows/draft/variables?page=&limit=` (`{items, total}`, values omitted).
  Future<Map<String, Object?>> draftVariables(
    String appId, {
    int page = 1,
    int limit = 20,
  });

  /// 1.14: `GET .../workflows/draft/nodes/{node}/variables` (`items` with values).
  Future<List<Map<String, Object?>>> nodeVariables(String appId, String nodeId);

  /// 1.14: `GET .../workflows/draft/conversation-variables`, `.../system-variables`, `.../environment-variables`
  /// (`kind`: `conversation`, `system`, `environment`): `items`.
  Future<List<Map<String, Object?>>> draftVariablesOfKind(
    String appId,
    String kind,
  );

  /// 1.14: `GET .../workflows/draft/variables/{id}`.
  Future<Map<String, Object?>> draftVariable(String appId, String variableId);

  /// 1.14: `PATCH .../workflows/draft/variables/{id}` with Dify's body (`name` and / or `value`; marks it `edited`).
  Future<Map<String, Object?>> updateDraftVariable(
    String appId,
    String variableId,
    Map<String, Object?> patch,
  );

  /// 1.14: `PUT .../workflows/draft/variables/{id}/reset`: the variable as reset, null when it was removed.
  Future<Map<String, Object?>?> resetDraftVariable(
    String appId,
    String variableId,
  );

  /// 1.14: `DELETE .../workflows/draft/variables/{id}`, `.../nodes/{node}/variables` (nodeId), or all (neither).
  Future<void> deleteDraftVariables(
    String appId, {
    String? variableId,
    String? nodeId,
  });

  // ---- human input (1.16) ----

  /// 1.16: `GET /v1/form/human_input/{token}`: the form a paused run waits on (Dify's FormDefinition: `form_content`,
  /// `inputs`, `user_actions`, `rendered_content`, `default_values`, `node_title`, `display_in_ui`,
  /// `expiration_time`). `404` an unknown token, `412` a form that was already answered or expired
  /// (`human_input_form_submitted` / `human_input_form_expired`), `401` without an account.
  Future<Map<String, Object?>> humanInputForm(String token);

  /// 1.16: `POST /v1/form/human_input/{token}` with Dify's body `{inputs: {...}, action: "..."}`; the answer is `{}`.
  /// The run continues on its own: the stream of [workflowEvents] (or the live draft-run stream) carries
  /// `human_input_form_filled` and the rest. Refusals: `400 invalid_form_data` (a field the form requires, a value
  /// outside a select's options, an unknown action), `404`, `412`.
  Future<void> submitHumanInputForm(String token, Map<String, Object?> body);

  /// 1.16: `GET /v1/workflow/{run}/events` (`sseGet`): Dify's reconnect endpoint. With [includeStateSnapshot] the
  /// stream opens with the state rebuilt from the run's records (`workflow_started` of the run, the node executions so
  /// far, the waiting forms, `workflow_paused` when it is paused); [continueOnPause] keeps it open across a pause
  /// rather than ending it at one (`close_on_pause`). A run that already ended answers one `workflow_finished` and
  /// closes; a run of another account is `404`.
  Stream<Map<String, Object?>> workflowEvents(
    String runId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  });

  /// 1.16: `POST {url}/preview` (the human-input node's own form: `/apps/{app}/workflows/draft/human-input/nodes/
  /// {node}/form`): the form as the node would show it, its `form_content` rendered with `inputs` (Dify's
  /// `HumanInputRequired`: `form_id`, `form_content`, `inputs`, `actions`, `node_id`, `node_title`,
  /// `resolved_default_values`).
  Future<Map<String, Object?>> humanInputFormPreview(
    String url,
    Map<String, Object?> body,
  );

  /// 1.16: `POST .../workflows/draft/human-input/nodes/{node}/delivery-test` `{"delivery_method_id": "...",
  /// "inputs": {...}}`: one test message of that delivery method, about a **delivery-test form** (no run: answering it
  /// proves the form and resumes nothing). `{}` on success; `400` when the method cannot send or has no recipients.
  Future<void> humanInputDeliveryTest(
    String appId,
    String nodeId,
    Map<String, Object?> body,
  );

  /// 1.16: `POST {url}/run` with `{inputs, form_inputs, action}`: the node's preview form is validated and its outputs
  /// (the filled fields, `__action_id`, `__action_value`, `__rendered_content`) are saved as the node's draft variables.
  Future<Map<String, Object?>> humanInputFormRun(
    String url,
    Map<String, Object?> body,
  );
}
