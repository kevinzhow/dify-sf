/// Dify's stream plumbing (service/base.ts `IOtherOptions`, `ssePost` / `sseGet` and `handleStream`) over a
/// [WorkflowRunService] stream: [RunCallbacks] are the callbacks Dify's hooks pass, [listenRunEvents] feeds a
/// stream's events to them with Dify's semantics (errors become `onError` + a toast + `onCompleted(true, message)`,
/// the end of the stream `onCompleted()`), and the returned [RunStreamHandle] is the request's `AbortController`.
library;

import 'dart:async';

import '../../design/widgets/toast.dart';
import '../store/workflow_store.dart' show DifyJson;
import 'run_events.dart';

/// `IOnDataMoreInfo`.
typedef RunDataInfo = ({
  String? event,
  String? conversationId,
  String? taskId,
  String? messageId,
  String? errorMessage,
  String? errorCode,
});

typedef RunEventCallback<E extends RunEvent> = void Function(E event);

/// The request's AbortController: [abort] cancels the stream (no callback runs after it).
class RunStreamHandle {
  RunStreamHandle();
  StreamSubscription<RunEvent>? _sub;
  bool _aborted = false;
  bool get aborted => _aborted;

  void abort() {
    if (_aborted) return;
    _aborted = true;
    _sub?.cancel();
  }
}

/// `IOtherOptions`: what to do with each event of a run stream. [merge] is JavaScript's `{...a, ...b}`.
class RunCallbacks {
  const RunCallbacks({
    this.silent = false,
    this.getAbortController,
    this.onData,
    this.onCompleted,
    this.onError,
    this.onNotifyError,
    this.onThought,
    this.onFile,
    this.onMessageEnd,
    this.onMessageReplace,
    this.onWorkflowStarted,
    this.onWorkflowFinished,
    this.onWorkflowPaused,
    this.onNodeStarted,
    this.onNodeFinished,
    this.onNodeRetry,
    this.onIterationStart,
    this.onIterationNext,
    this.onIterationFinish,
    this.onLoopStart,
    this.onLoopNext,
    this.onLoopFinish,
    this.onParallelBranchStarted,
    this.onParallelBranchFinished,
    this.onTextChunk,
    this.onReasoning,
    this.onTextReplace,
    this.onAgentLog,
    this.onTTSChunk,
    this.onTTSEnd,
    this.onHumanInputRequired,
    this.onHumanInputFormFilled,
    this.onHumanInputFormTimeout,
    this.onDataSourceNodeProcessing,
    this.onDataSourceNodeCompleted,
    this.onDataSourceNodeError,
    this.onUnhandledEvent,
  });

  /// No toast for errors.
  final bool silent;
  final void Function(RunStreamHandle handle)? getAbortController;
  final void Function(String message, bool isFirstMessage, RunDataInfo info)? onData;
  final void Function([bool hasError, String? errorMessage])? onCompleted;
  final void Function(String message, [String? code])? onError;

  /// Shows a stream error instead of the default toast.
  final void Function(String message, [String? code])? onNotifyError;
  final RunEventCallback<AgentThoughtEvent>? onThought;
  final RunEventCallback<MessageFileEvent>? onFile;
  final RunEventCallback<MessageEndEvent>? onMessageEnd;
  final RunEventCallback<MessageReplaceEvent>? onMessageReplace;
  final RunEventCallback<WorkflowStartedEvent>? onWorkflowStarted;
  final RunEventCallback<WorkflowFinishedEvent>? onWorkflowFinished;
  final RunEventCallback<WorkflowPausedEvent>? onWorkflowPaused;
  final RunEventCallback<NodeStartedEvent>? onNodeStarted;
  final RunEventCallback<NodeFinishedEvent>? onNodeFinished;
  final RunEventCallback<NodeRetryEvent>? onNodeRetry;
  final RunEventCallback<IterationStartedEvent>? onIterationStart;
  final RunEventCallback<IterationNextEvent>? onIterationNext;
  final RunEventCallback<IterationCompletedEvent>? onIterationFinish;
  final RunEventCallback<LoopStartedEvent>? onLoopStart;
  final RunEventCallback<LoopNextEvent>? onLoopNext;
  final RunEventCallback<LoopCompletedEvent>? onLoopFinish;
  final RunEventCallback<ParallelBranchStartedEvent>? onParallelBranchStarted;
  final RunEventCallback<ParallelBranchFinishedEvent>? onParallelBranchFinished;
  final RunEventCallback<TextChunkEvent>? onTextChunk;
  final RunEventCallback<ReasoningChunkEvent>? onReasoning;
  final RunEventCallback<TextReplaceEvent>? onTextReplace;
  final RunEventCallback<AgentLogEvent>? onAgentLog;
  final void Function(String messageId, String audio, String? audioType)? onTTSChunk;
  final void Function(String messageId, String audio)? onTTSEnd;
  final RunEventCallback<HumanInputRequiredEvent>? onHumanInputRequired;
  final RunEventCallback<HumanInputFormFilledEvent>? onHumanInputFormFilled;
  final RunEventCallback<HumanInputFormTimeoutEvent>? onHumanInputFormTimeout;
  final RunEventCallback<DataSourceProcessingEvent>? onDataSourceNodeProcessing;
  final RunEventCallback<DataSourceCompletedEvent>? onDataSourceNodeCompleted;
  final RunEventCallback<DataSourceErrorEvent>? onDataSourceNodeError;

  /// An event without a handler; a returned error ends the stream with it (`UnhandledEventError`).
  final RunDataInfo? Function(DifyJson event)? onUnhandledEvent;

  /// `{...this, ...over}`: [over]'s callbacks win where it has them.
  RunCallbacks merge(RunCallbacks over) => RunCallbacks(
    silent: over.silent || silent,
    getAbortController: over.getAbortController ?? getAbortController,
    onData: over.onData ?? onData,
    onCompleted: over.onCompleted ?? onCompleted,
    onError: over.onError ?? onError,
    onNotifyError: over.onNotifyError ?? onNotifyError,
    onThought: over.onThought ?? onThought,
    onFile: over.onFile ?? onFile,
    onMessageEnd: over.onMessageEnd ?? onMessageEnd,
    onMessageReplace: over.onMessageReplace ?? onMessageReplace,
    onWorkflowStarted: over.onWorkflowStarted ?? onWorkflowStarted,
    onWorkflowFinished: over.onWorkflowFinished ?? onWorkflowFinished,
    onWorkflowPaused: over.onWorkflowPaused ?? onWorkflowPaused,
    onNodeStarted: over.onNodeStarted ?? onNodeStarted,
    onNodeFinished: over.onNodeFinished ?? onNodeFinished,
    onNodeRetry: over.onNodeRetry ?? onNodeRetry,
    onIterationStart: over.onIterationStart ?? onIterationStart,
    onIterationNext: over.onIterationNext ?? onIterationNext,
    onIterationFinish: over.onIterationFinish ?? onIterationFinish,
    onLoopStart: over.onLoopStart ?? onLoopStart,
    onLoopNext: over.onLoopNext ?? onLoopNext,
    onLoopFinish: over.onLoopFinish ?? onLoopFinish,
    onParallelBranchStarted: over.onParallelBranchStarted ?? onParallelBranchStarted,
    onParallelBranchFinished: over.onParallelBranchFinished ?? onParallelBranchFinished,
    onTextChunk: over.onTextChunk ?? onTextChunk,
    onReasoning: over.onReasoning ?? onReasoning,
    onTextReplace: over.onTextReplace ?? onTextReplace,
    onAgentLog: over.onAgentLog ?? onAgentLog,
    onTTSChunk: over.onTTSChunk ?? onTTSChunk,
    onTTSEnd: over.onTTSEnd ?? onTTSEnd,
    onHumanInputRequired: over.onHumanInputRequired ?? onHumanInputRequired,
    onHumanInputFormFilled: over.onHumanInputFormFilled ?? onHumanInputFormFilled,
    onHumanInputFormTimeout: over.onHumanInputFormTimeout ?? onHumanInputFormTimeout,
    onDataSourceNodeProcessing: over.onDataSourceNodeProcessing ?? onDataSourceNodeProcessing,
    onDataSourceNodeCompleted: over.onDataSourceNodeCompleted ?? onDataSourceNodeCompleted,
    onDataSourceNodeError: over.onDataSourceNodeError ?? onDataSourceNodeError,
    onUnhandledEvent: over.onUnhandledEvent ?? onUnhandledEvent,
  );
}

/// The toast a stream error shows (dify-ui's `toast.error` by default; tests replace it).
void Function(String message) runStreamToast = (m) => toast.error(m);

/// `ssePost` / `sseGet` + `handleStream`: listens to [stream] and calls [cb] per event; returns the handle that
/// aborts it ([RunCallbacks.getAbortController] gets it first).
RunStreamHandle listenRunEvents(Stream<RunEvent> stream, RunCallbacks cb) {
  final handle = RunStreamHandle();
  cb.getAbortController?.call(handle);
  var isFirstMessage = true;

  void notify(String message, [String? code]) {
    if (cb.silent) return;
    if (cb.onNotifyError != null) {
      cb.onNotifyError!(message, code);
    } else {
      runStreamToast(message);
    }
  }

  // ssePost's onData wrapper: an error message is onError (and a toast), not data.
  void data(String message, bool first, RunDataInfo info) {
    if (info.errorMessage != null) {
      cb.onError?.call(info.errorMessage!, info.errorCode);
      notify(info.errorMessage!, info.errorCode);
      return;
    }
    cb.onData?.call(message, first, info);
  }

  void finish([bool hasError = false, String? message]) {
    if (handle.aborted) return;
    handle._aborted = true;
    handle._sub?.cancel();
    cb.onCompleted?.call(hasError, message);
  }

  handle._sub = stream.listen(
    (e) {
      if (handle.aborted) return;
      switch (e) {
        case ErrorEvent():
          data('', false, (
            event: null,
            conversationId: null,
            taskId: null,
            messageId: '',
            errorMessage: e.message ?? '',
            errorCode: e.code,
          ));
          finish(true, e.message);
        case MessageEvent():
          data(e.answer, isFirstMessage, (
            event: e.event,
            conversationId: e.conversationId,
            taskId: e.taskId,
            messageId: e.messageId,
            errorMessage: null,
            errorCode: null,
          ));
          isFirstMessage = false;
        case AgentThoughtEvent():
          cb.onThought?.call(e);
        case MessageFileEvent():
          cb.onFile?.call(e);
        case MessageEndEvent():
          cb.onMessageEnd?.call(e);
        case MessageReplaceEvent():
          cb.onMessageReplace?.call(e);
        case WorkflowStartedEvent():
          cb.onWorkflowStarted?.call(e);
        case WorkflowFinishedEvent():
          cb.onWorkflowFinished?.call(e);
        case NodeStartedEvent():
          cb.onNodeStarted?.call(e);
        case NodeFinishedEvent():
          cb.onNodeFinished?.call(e);
        case IterationStartedEvent():
          cb.onIterationStart?.call(e);
        case IterationNextEvent():
          cb.onIterationNext?.call(e);
        case IterationCompletedEvent():
          cb.onIterationFinish?.call(e);
        case LoopStartedEvent():
          cb.onLoopStart?.call(e);
        case LoopNextEvent():
          cb.onLoopNext?.call(e);
        case LoopCompletedEvent():
          cb.onLoopFinish?.call(e);
        case NodeRetryEvent():
          cb.onNodeRetry?.call(e);
        case ParallelBranchStartedEvent():
          cb.onParallelBranchStarted?.call(e);
        case ParallelBranchFinishedEvent():
          cb.onParallelBranchFinished?.call(e);
        case TextChunkEvent():
          cb.onTextChunk?.call(e);
        case ReasoningChunkEvent():
          cb.onReasoning?.call(e);
        case TextReplaceEvent():
          cb.onTextReplace?.call(e);
        case AgentLogEvent():
          cb.onAgentLog?.call(e);
        case TtsMessageEvent():
          cb.onTTSChunk?.call(
            e.json['message_id'] as String? ?? '',
            e.json['audio'] as String? ?? '',
            e.json['audio_type'] as String?,
          );
        case TtsMessageEndEvent():
          cb.onTTSEnd?.call(e.json['message_id'] as String? ?? '', e.json['audio'] as String? ?? '');
        case HumanInputRequiredEvent():
          cb.onHumanInputRequired?.call(e);
        case HumanInputFormFilledEvent():
          cb.onHumanInputFormFilled?.call(e);
        case HumanInputFormTimeoutEvent():
          cb.onHumanInputFormTimeout?.call(e);
        case WorkflowPausedEvent():
          cb.onWorkflowPaused?.call(e);
        case DataSourceProcessingEvent():
          cb.onDataSourceNodeProcessing?.call(e);
        case DataSourceCompletedEvent():
          cb.onDataSourceNodeCompleted?.call(e);
        case DataSourceErrorEvent():
          cb.onDataSourceNodeError?.call(e);
        case UnknownRunEvent():
          final err = cb.onUnhandledEvent?.call(e.json);
          if (err != null) {
            data('', false, err);
            finish(true, err.errorMessage);
          }
      }
    },
    onError: (Object error, StackTrace _) {
      if (handle.aborted) return;
      // A failed request (fetch rejected / an error response): onError, no onCompleted (ssePost's catch).
      final message = error is RunServiceException ? error.message : '$error';
      final code = error is RunServiceException ? error.code : null;
      notify(message, code);
      handle._aborted = true;
      handle._sub?.cancel();
      cb.onError?.call(message, code);
    },
    onDone: () => finish(),
  );
  return handle;
}
