/// The editor's run/debug backend: the operations Dify 1.17.1's web app calls to run and debug a draft
/// (service/workflow.ts, service/base.ts `ssePost`/`sseGet`, service/use-workflow.ts, service/log.ts,
/// service/debug.ts), as one injectable [WorkflowRunService]. With a server runtime (protocols 1.13, 1.14) it is
/// `ServerRunService` (server_run_service.dart: whole draft runs, single runs, history and records of what the server
/// runs); everything else, and servers without a runtime, use [MockWorkflowRunService] (mock_run_service.dart), which
/// replays plausible event streams built from the current graph, so every run UI works the same either way.
///
/// ## API (for the run UI)
///
/// Everything is mounted by `WorkflowRunHost` (run_scope.dart) inside the WorkflowEditor's store scope; read it with
/// `WorkflowRunScope.of(context)`:
///
/// - `scope.run` — [WorkflowRunController] (workflow_run.dart): Dify's `useWorkflowRun` + `useWorkflowStartRun`.
///   `handleRun(params, callbacks)`, `handleStopRun(taskId)`, `handleWorkflowStartRunInWorkflow()`,
///   `handleWorkflowStartRunInChatflow()`, `handleStartRunFromOption(TriggerOption)` (the header's onRun),
///   `handleWorkflowTrigger{Schedule,Webhook,Plugin}RunInWorkflow(nodeId)`, `handleWorkflowRunAllTriggersInWorkflow`,
///   `handleCancelDebugAndPreviewPanel()`, `fetchRunHistory()`, `fetchRunDetail(runId)`, `fetchTracingList(runId)`.
///   Its run state is the store's: `store.workflowRunningData` (Dify's WorkflowRunningData JSON: `task_id`,
///   `result` {status, outputs, error, elapsed_time, total_tokens, total_steps, created_at, created_by, finished_at,
///   files, ...}, `tracing` [NodeTracing...], `resultText`, `resultTextSelectorKey`, `resultTabActive`,
///   `reasoningContent`, `reasoningFinished`, `humanInputFormDataList`, `humanInputFilledFormDataList`),
///   `store.isListening`, `store.listeningTrigger*`, `store.showDebugAndPreviewPanel`, `store.showInputsPanel`,
///   `store.historyWorkflowData`, `store.iterTimes`, `store.loopTimes`, `store.iterParallelLogMap`.
/// - Node and edge run fields (Dify's React Flow `data._runningStatus`, `_waitingRun`, `_runningBranchId`,
///   `_retryIndex`, `_iterationIndex`, `_iterationLength`, `_loopIndex`, `_loopLength`, `_singleRunningStatus`,
///   `_isSingleRun`; edges' `_sourceRunningStatus`, `_targetRunningStatus`, `_waitingRun`) are LOCAL view state,
///   never document ops: `store.nodeRunData` / `store.edgeRunData` (id → fields), helpers
///   `store.nodeRunDataOf(id)`, `store.setNodeRunData(id, patch)`. The canvas cards show `_runningStatus`.
/// - `scope.createChat(config:, formSettings:)` → `DebugChatController` (debug_chat.dart): the chatflow preview's
///   `useChat` (`chatList`, `isResponding`, `suggestedQuestions`, `conversationId`, `handleSend(params,
///   onGetSuggestedQuestions:)`, `handleStop`, `handleRestart`, `handleResume`, `handleSwitchSibling`,
///   `handleSubmitHumanInputForm`, `getHumanInputNodeData`, `setTargetMessageId`; `config` / `formSettings` are
///   settable). As Dify's ChatWrapper, the caller sends `conversation_id` and passes
///   `onGetSuggestedQuestions: chat.defaultSuggestedQuestions` (without it no suggestions are fetched).
/// - `scope.singleRunOf(nodeId)` → `SingleRunController` (single_run.dart): `useOneStepRun`'s data side
///   (`handleRun(submitData)`, `handleStop`, `runningStatus`, `isCompleted`, `runResult`, `iterationRunResult`,
///   `loopRunResult`, `showSingleRun`, `hideSingleRun`, `isShowSingleRun`, `setNodeRunning`, `validate`,
///   `isRunAfterSingleRun` (set it as use-last-run does before a run), the form inputs `toVarInputs`,
///   `getFormInputVars(texts)`, `varSelectorsToVarInputs`) and the Last Run tab's data (`fetchLastRun()`, `lastRun`,
///   `isLastRunLoading`; refetched when runs invalidate it).
/// - `scope.service` — the [WorkflowRunService] (run history, run detail, tracing list, conversation variables,
///   chat messages). The variable inspect panel's values come from the server's draft variables (1.14,
///   `ServerInspectServices`) or the mock's `inspectServices`.
/// - Stopping from the variable inspect panel (EVENT_WORKFLOW_STOP) is `WorkflowRunHostState.emitWorkflowStop`.
/// - Events: [RunEvent] and subclasses (run_events.dart), one per SSE `event` Dify handles; streams are fed to
///   Dify-style callbacks with `listenRunEvents(stream, RunCallbacks(...))` (run_stream.dart).
library;

import '../store/workflow_store.dart' show DifyJson;
import '../header/test_run_menu.dart' show TriggerType;
import 'run_events.dart';

export '../header/test_run_menu.dart' show TriggerType;
export 'run_events.dart';

/// A workflow draft run (`POST apps/{id}/workflows/draft/run`, or the trigger debug endpoints
/// `workflows/draft/trigger/run` / `run-all`).
class WorkflowDraftRunRequest {
  const WorkflowDraftRunRequest({this.mode = TriggerType.userInput, this.body = const {}});

  /// Dify's `TriggerType` (header/test-run-menu.tsx).
  final TriggerType mode;

  /// Dify's request body: `{inputs, files}` for a user-input run, `{node_id}` / `{node_ids}` for trigger runs.
  final DifyJson body;

  DifyJson get inputs => (body['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
}

/// A chatflow draft message (`POST apps/{id}/advanced-chat/workflows/draft/run`): `{query, inputs, files,
/// conversation_id, parent_message_id}` as Dify's useChat sends it.
class ChatMessageRequest {
  const ChatMessageRequest(this.body);
  final DifyJson body;

  String get query => body['query'] as String? ?? '';
  String? get conversationId => body['conversation_id'] as String?;
}

/// The run/debug operations of Dify's web app. Streams are Dify's SSE streams: cancelling the subscription is the
/// request's abort; a request that fails ends the stream with a [RunServiceException]. Lists and records are Dify's
/// JSON (WorkflowRunHistory, WorkflowRunDetailResponse, NodeTracing, ConversationVariable, ChatItem log messages).
abstract class WorkflowRunService {
  const WorkflowRunService();

  /// `handleRun` of a workflow (user input or trigger debug).
  Stream<RunEvent> runWorkflowDraft(WorkflowDraftRunRequest request);

  /// `handleRun` in a chatflow: the message stream (message, message_end, workflow/node events, ...).
  Stream<RunEvent> sendChatMessage(ChatMessageRequest request);

  /// `sseGet('/workflow/{run_id}/events?include_state_snapshot=true&continue_on_pause=true')`: the events of a
  /// paused run after it resumes (human input).
  Stream<RunEvent> workflowEvents(String workflowRunId);

  /// `stopWorkflowRun('/apps/{id}/workflow-runs/tasks/{task_id}/stop')`.
  Future<void> stopWorkflowRun(String taskId);

  /// `stopChatMessageResponding(appId, taskId)` (`apps/{id}/chat-messages/{task_id}/stop`).
  Future<void> stopChatMessageResponding(String taskId);

  /// `fetchSuggestedQuestions` (`apps/{id}/chat-messages/{message_id}/suggested-questions`): `data`.
  Future<List<String>> fetchSuggestedQuestions(String messageId);

  /// `submitHumanInputForm(token, {inputs, action})`.
  Future<void> submitHumanInputForm(String formToken, DifyJson data);

  /// `singleNodeRun` (`apps/{id}/workflows/draft/nodes/{node_id}/run`, body `{inputs}` or, for Start, `{inputs,
  /// query, files, conversation_id}`): the node's run result (NodeTracing JSON; `error` when it failed).
  Future<DifyJson> singleNodeRun(String nodeId, DifyJson body);

  /// The iteration / loop single run streams (`.../workflows/draft/iteration|loop/nodes/{node_id}/run`).
  Stream<RunEvent> iterationSingleNodeRun(String nodeId, DifyJson body);
  Stream<RunEvent> loopSingleNodeRun(String nodeId, DifyJson body);

  /// `useLastRun` (`.../workflows/draft/nodes/{node_id}/last-run`): the node's last run (NodeTracing), null if none.
  Future<DifyJson?> fetchNodeLastRun(String nodeId);

  /// `useWorkflowRunHistory` (`apps/{id}/workflow-runs` or `advanced-chat/workflow-runs`): newest first.
  Future<List<DifyJson>> fetchWorkflowRunHistory();

  /// `fetchRunDetail` (`apps/{id}/workflow-runs/{run_id}`).
  Future<DifyJson> fetchRunDetail(String runId);

  /// `fetchTracingList` (`apps/{id}/workflow-runs/{run_id}/node-executions`): `data`.
  Future<List<DifyJson>> fetchTracingList(String runId);

  /// `fetchCurrentValueOfConversationVariable` (`apps/{id}/advanced-chat/workflows/draft/conversation-variables`).
  Future<List<DifyJson>> fetchConversationVariables(String conversationId);

  /// `fetchChatMessages` (`apps/{id}/chat-messages?conversation_id=`): the conversation's messages (oldest first).
  Future<List<DifyJson>> fetchChatMessages(String conversationId);
}
