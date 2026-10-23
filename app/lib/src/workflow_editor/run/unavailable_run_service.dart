import '../store/workflow_store.dart' show DifyJson;
import 'run_service.dart';

/// Unsupported remote operations must never manufacture successful local runs.
/// Empty read collections mean that no local execution records exist.
class UnavailableWorkflowRunService extends WorkflowRunService {
  const UnavailableWorkflowRunService();

  RunServiceException _unsupported(String operation) =>
      RunServiceException('$operation is not available on this server yet.', code: 'runtime_not_supported');

  @override
  Future<DifyJson> singleNodeRun(String nodeId, DifyJson body) async => throw _unsupported('Running this node');
  @override
  Stream<RunEvent> runWorkflowDraft(WorkflowDraftRunRequest request) =>
      Stream.error(_unsupported('Running this workflow'));
  @override
  Stream<RunEvent> sendChatMessage(ChatMessageRequest request) => Stream.error(_unsupported('Chatflow execution'));
  @override
  Stream<RunEvent> workflowEvents(
    String workflowRunId, {
    bool includeStateSnapshot = true,
    bool continueOnPause = true,
  }) => Stream.error(_unsupported('Resuming this workflow'));
  @override
  Stream<RunEvent> iterationSingleNodeRun(String nodeId, DifyJson body) =>
      Stream.error(_unsupported('Running this iteration'));
  @override
  Stream<RunEvent> loopSingleNodeRun(String nodeId, DifyJson body) => Stream.error(_unsupported('Running this loop'));
  @override
  Future<void> stopWorkflowRun(String taskId) async => throw _unsupported('Stopping this workflow');
  @override
  Future<void> stopChatMessageResponding(String taskId) async => throw _unsupported('Stopping this chat');
  @override
  Future<void> submitHumanInputForm(String formToken, DifyJson data) async =>
      throw _unsupported('Submitting this form');
  @override
  Future<DifyJson?> fetchNodeLastRun(String nodeId) async => null;
  @override
  Future<List<DifyJson>> fetchWorkflowRunHistory() async => const [];
  @override
  Future<DifyJson> fetchRunDetail(String runId) async => throw _unsupported('Reading this run');
  @override
  Future<List<DifyJson>> fetchTracingList(String runId) async => const [];
  @override
  Future<List<String>> fetchSuggestedQuestions(String messageId) async => const [];
  @override
  Future<List<DifyJson>> fetchConversationVariables(String conversationId) async => const [];
  @override
  Future<List<DifyJson>> fetchChatMessages(String conversationId) async => const [];
}
