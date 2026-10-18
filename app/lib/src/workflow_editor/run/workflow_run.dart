/// Running a draft (Dify 1.17.1 workflow-app/hooks/use-workflow-run.ts, use-workflow-run-callbacks.ts,
/// use-workflow-run-utils.ts, use-workflow-start-run.tsx, workflow/hooks/use-workflow-panel-interactions.ts'
/// handleCancelDebugAndPreviewPanel) over a [WorkflowRunService].
///
/// Not ported: the draft sync before a run (the collaborative document is the draft, always saved), the backup /
/// restore of the draft around viewing a run or a version (the run UI shows a historical graph as a view, never by
/// replacing the document), text-to-speech playback (no audio player) and Amplitude tracking.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../design/widgets/toast.dart';
import '../header/test_run_menu.dart' show TriggerOption, TriggerType;
import '../store/workflow_store.dart';
import 'run_graph.dart';
import 'run_service.dart';
import 'run_stream.dart';
import 'run_types.dart';
import 'workflow_run_events.dart';

/// `HandleRunOptions`.
@immutable
class HandleRunOptions {
  const HandleRunOptions({
    this.mode = TriggerType.userInput,
    this.scheduleNodeId,
    this.webhookNodeId,
    this.pluginNodeId,
    this.allNodeIds,
  });
  final TriggerType mode;
  final String? scheduleNodeId;
  final String? webhookNodeId;
  final String? pluginNodeId;
  final List<String>? allNodeIds;
}

// ----- use-workflow-run-utils.ts -----

/// `buildWorkflowRunRequestBody`.
DifyJson buildWorkflowRunRequestBody(TriggerType runMode, DifyJson resolvedParams, [HandleRunOptions? options]) =>
    switch (runMode) {
      TriggerType.schedule => {'node_id': options?.scheduleNodeId},
      TriggerType.webhook => {'node_id': options?.webhookNodeId},
      TriggerType.plugin => {'node_id': options?.pluginNodeId},
      TriggerType.all => {'node_ids': options?.allNodeIds},
      TriggerType.userInput => resolvedParams,
    };

/// `validateWorkflowRunRequest`: '' when the request is valid. (Dify's `all` check can never fire:
/// `!allNodeIds && allNodeIds?.length === 0`; kept.)
String validateWorkflowRunRequest(TriggerType runMode, [HandleRunOptions? options]) {
  if (runMode == TriggerType.schedule && options?.scheduleNodeId == null) {
    return 'handleRun: schedule trigger run requires node id';
  }
  if (runMode == TriggerType.webhook && options?.webhookNodeId == null) {
    return 'handleRun: webhook trigger run requires node id';
  }
  if (runMode == TriggerType.plugin && options?.pluginNodeId == null) {
    return 'handleRun: plugin trigger run requires node id';
  }
  return '';
}

/// `isDebuggableTriggerType`.
bool isDebuggableTriggerType(TriggerType runMode) => runMode != TriggerType.userInput;

/// `buildListeningTriggerNodeIds`.
List<String> buildListeningTriggerNodeIds(TriggerType runMode, [HandleRunOptions? options]) {
  if (runMode == TriggerType.all) return options?.allNodeIds ?? const [];
  if (runMode == TriggerType.webhook && options?.webhookNodeId != null) return [options!.webhookNodeId!];
  if (runMode == TriggerType.schedule && options?.scheduleNodeId != null) return [options!.scheduleNodeId!];
  if (runMode == TriggerType.plugin && options?.pluginNodeId != null) return [options!.pluginNodeId!];
  return const [];
}

/// `applyRunningStateForMode`.
void applyRunningStateForMode(WorkflowStore s, TriggerType runMode, [HandleRunOptions? options]) {
  if (isDebuggableTriggerType(runMode)) {
    s
      ..setIsListening(true)
      ..setShowVariableInspectPanel(true)
      ..setListeningTriggerIsAll(runMode == TriggerType.all)
      ..setListeningTriggerNodeIds(buildListeningTriggerNodeIds(runMode, options))
      ..setWorkflowRunningData(createRunningWorkflowState());
    return;
  }
  s
    ..setIsListening(false)
    ..setListeningTriggerType(null)
    ..setListeningTriggerNodeId(null)
    ..setListeningTriggerNodeIds(const [])
    ..setListeningTriggerIsAll(false)
    ..setWorkflowRunningData(createRunningWorkflowState());
}

/// `clearListeningState`.
void clearListeningState(WorkflowStore s) => s
  ..setIsListening(false)
  ..setListeningTriggerType(null)
  ..setListeningTriggerNodeId(null)
  ..setListeningTriggerNodeIds(const [])
  ..setListeningTriggerIsAll(false);

/// `applyStoppedState`.
void applyStoppedState(WorkflowStore s) => s
  ..setWorkflowRunningData(createStoppedWorkflowState())
  ..setIsListening(false)
  ..setListeningTriggerType(null)
  ..setListeningTriggerNodeId(null)
  ..setShowVariableInspectPanel(true);

// ----- use-workflow-run-callbacks.ts -----

/// `CallbackContext` of the callback factories.
class WorkflowRunCallbackContext {
  WorkflowRunCallbackContext({
    required this.container,
    required this.isInWorkflowDebug,
    required this.fetchInspectVars,
    required this.invalidAllLastRun,
    required this.invalidateRunHistory,
    required this.clearAbortController,
    required this.clearListeningState,
    required this.handlers,
    required this.resume,
    this.callbacks = const RunCallbacks(),
    this.restCallback = const RunCallbacks(),
  });

  final RunContainerSize Function() container;
  final bool isInWorkflowDebug;
  final VoidCallback fetchInspectVars;
  final VoidCallback invalidAllLastRun;
  final VoidCallback invalidateRunHistory;
  final VoidCallback clearAbortController;
  final VoidCallback clearListeningState;
  final WorkflowRunEvents handlers;

  /// `sseGet('/workflow/{run_id}/events?...', {}, callbacks)`: continues a paused run.
  final void Function(String workflowRunId, RunCallbacks callbacks) resume;

  /// The caller's callbacks wrapped by the factories ([RunCallbacks.onWorkflowStarted] ... [RunCallbacks.onCompleted]).
  final RunCallbacks callbacks;

  /// The caller's other callbacks (onData, onMessageEnd, ...), passed through.
  final RunCallbacks restCallback;
}

/// The node, iteration, loop, retry, agent log, text and human input callbacks both factories define: the handler,
/// then the caller's callback.
RunCallbacks _eventCallbacks(WorkflowRunCallbackContext c) {
  final h = c.handlers, u = c.callbacks;
  return RunCallbacks(
    onNodeStarted: (p) {
      h.handleWorkflowNodeStarted(p, c.container());
      u.onNodeStarted?.call(p);
    },
    onNodeFinished: (p) {
      h.handleWorkflowNodeFinished(p);
      u.onNodeFinished?.call(p);
    },
    onIterationStart: (p) {
      h.handleWorkflowNodeIterationStarted(p, c.container());
      u.onIterationStart?.call(p);
    },
    onIterationNext: (p) {
      h.handleWorkflowNodeIterationNext(p);
      u.onIterationNext?.call(p);
    },
    onIterationFinish: (p) {
      h.handleWorkflowNodeIterationFinished(p);
      u.onIterationFinish?.call(p);
    },
    onLoopStart: (p) {
      h.handleWorkflowNodeLoopStarted(p, c.container());
      u.onLoopStart?.call(p);
    },
    onLoopNext: (p) {
      h.handleWorkflowNodeLoopNext(p);
      u.onLoopNext?.call(p);
    },
    onLoopFinish: (p) {
      h.handleWorkflowNodeLoopFinished(p);
      u.onLoopFinish?.call(p);
    },
    onNodeRetry: (p) {
      h.handleWorkflowNodeRetry(p);
      u.onNodeRetry?.call(p);
    },
    onAgentLog: (p) {
      h.handleWorkflowAgentLog(p);
      u.onAgentLog?.call(p);
    },
    onTextChunk: (p) => h.handleWorkflowTextChunk(p),
    onTextReplace: (p) => h.handleWorkflowTextReplace(p),
    onReasoning: (p) => h.handleWorkflowReasoning(p),
    onHumanInputRequired: (p) {
      h.handleWorkflowNodeHumanInputRequired(p);
      u.onHumanInputRequired?.call(p);
    },
    onHumanInputFormFilled: (p) {
      h.handleWorkflowNodeHumanInputFormFilled(p);
      u.onHumanInputFormFilled?.call(p);
    },
    onHumanInputFormTimeout: (p) {
      h.handleWorkflowNodeHumanInputFormTimeout(p);
      u.onHumanInputFormTimeout?.call(p);
    },
  );
}

/// `onWorkflowFinished` / `onError` / `onWorkflowPaused` as both factories define them; [self] is the callbacks
/// object a paused run continues with.
RunCallbacks _endCallbacks(WorkflowRunCallbackContext c, RunCallbacks Function() self, {required bool clearListening}) {
  final h = c.handlers, u = c.callbacks;
  var hasStartedResumeStream = false;
  return RunCallbacks(
    onWorkflowFinished: (p) {
      if (clearListening) c.clearListeningState();
      h.handleWorkflowFinished(p);
      c.invalidateRunHistory();
      u.onWorkflowFinished?.call(p);
      if (c.isInWorkflowDebug) {
        c.fetchInspectVars();
        c.invalidAllLastRun();
      }
    },
    onError: (message, [code]) {
      c.clearAbortController();
      h.handleWorkflowFailed(message);
      c.invalidateRunHistory();
      c.clearListeningState();
      u.onError?.call(message, code);
    },
    onWorkflowPaused: (p) {
      h.handleWorkflowPaused();
      c.invalidateRunHistory();
      u.onWorkflowPaused?.call(p);
      if (!hasStartedResumeStream) {
        hasStartedResumeStream = true;
        c.resume(p.workflowRunId ?? '', self());
      }
    },
  );
}

/// `createBaseWorkflowRunCallbacks`: the caller's rest callbacks, overridden by the handlers' wrappers.
RunCallbacks createBaseWorkflowRunCallbacks(WorkflowRunCallbackContext c) {
  final h = c.handlers, u = c.callbacks;
  late final RunCallbacks base;
  base = c.restCallback
      .merge(
        RunCallbacks(
          onWorkflowStarted: (p) {
            h.handleWorkflowStarted(p);
            c.invalidateRunHistory();
            u.onWorkflowStarted?.call(p);
          },
          onCompleted: ([hasError = false, errorMessage]) {
            c.clearAbortController();
            c.clearListeningState();
            u.onCompleted?.call(hasError, errorMessage);
          },
        ),
      )
      .merge(_eventCallbacks(c))
      .merge(_endCallbacks(c, () => base, clearListening: true));
  return base;
}

/// `createFinalWorkflowRunCallbacks`: the base callbacks redefined with this context (the abort controller wired,
/// `onWorkflowFinished` without clearing the listening state), the caller's rest callbacks winning over everything.
RunCallbacks createFinalWorkflowRunCallbacks(
  WorkflowRunCallbackContext c, {
  required RunCallbacks baseSseOptions,
  required void Function(RunStreamHandle handle) setAbortController,
}) {
  late final RunCallbacks finalCallbacks;
  finalCallbacks = baseSseOptions
      .merge(RunCallbacks(getAbortController: setAbortController))
      .merge(_eventCallbacks(c))
      .merge(_endCallbacks(c, () => finalCallbacks, clearListening: false))
      .merge(c.restCallback);
  return finalCallbacks;
}

// ----- the controller -----

/// `useWorkflowRun` + `useWorkflowStartRun` for one editor: starts, follows and stops draft runs; the run state is
/// the store's (see run_service.dart's API notes).
class WorkflowRunController {
  WorkflowRunController({
    required this.store,
    required this.service,
    required this.graph,
    this.viewport,
    bool Function()? isChatMode,
    VoidCallback? fetchInspectVars,
    this.onCancelSelection,
    void Function(DifyToastType type, String message)? toast,
  }) : isChatMode = isChatMode ?? _never,
       fetchInspectVars = fetchInspectVars ?? _noop,
       toast = toast ?? difyToast,
       events = WorkflowRunEvents(store: store, graph: graph, viewport: viewport);

  static bool _never() => false;
  static void _noop() {}

  final WorkflowStore store;
  final WorkflowRunService service;
  final RunGraph graph;
  final RunViewport? viewport;

  /// `useIsChatMode` (advanced-chat).
  final bool Function() isChatMode;

  /// `useSetWorkflowVarsWithValue().fetchInspectVars`: reload the variable inspect panel after a run.
  final VoidCallback fetchInspectVars;

  /// handleRun's `node.data.selected = false` for every node.
  final VoidCallback? onCancelSelection;
  final void Function(DifyToastType type, String message) toast;

  /// The event handlers (`useWorkflowRunEvent`).
  final WorkflowRunEvents events;

  /// Bumped by `useInvalidAllLastRun` (Last Run tabs refetch) and `useInvalidateWorkflowRunHistory`.
  final lastRunVersion = ValueNotifier(0);
  final runHistoryVersion = ValueNotifier(0);

  /// `abortControllerRef`.
  RunStreamHandle? _abort;

  /// `window.__{webhook,plugin,schedule,allTriggers}DebugAbortController`.
  final _debugControllers = <TriggerType, RunStreamHandle>{};
  final _streams = <RunStreamHandle>{};

  void invalidAllLastRun() => lastRunVersion.value++;
  void invalidateRunHistory() => runHistoryVersion.value++;

  RunContainerSize get _container =>
      (clientWidth: store.workflowCanvasWidth.value ?? 0, clientHeight: store.workflowCanvasHeight.value ?? 0);

  RunStreamHandle _listen(Stream<RunEvent> stream, RunCallbacks cb) {
    final h = listenRunEvents(stream, cb);
    _streams
      ..removeWhere((s) => s.aborted)
      ..add(h);
    return h;
  }

  void _clearAbortController() {
    _abort = null;
    _debugControllers.clear();
  }

  /// `handleRun(params, callback, options)`.
  Future<void> handleRun(DifyJson? params, {RunCallbacks? callback, HandleRunOptions? options}) async {
    final runMode = options?.mode ?? TriggerType.userInput;
    final resolvedParams = params ?? const <String, Object?>{};
    onCancelSelection?.call();
    events.clearNodesRunningStatus();
    final cb = callback ?? const RunCallbacks();
    // The callbacks the factories wrap; the rest pass through.
    final userCallbacks = RunCallbacks(
      onWorkflowStarted: cb.onWorkflowStarted,
      onWorkflowFinished: cb.onWorkflowFinished,
      onNodeStarted: cb.onNodeStarted,
      onNodeFinished: cb.onNodeFinished,
      onIterationStart: cb.onIterationStart,
      onIterationNext: cb.onIterationNext,
      onIterationFinish: cb.onIterationFinish,
      onLoopStart: cb.onLoopStart,
      onLoopNext: cb.onLoopNext,
      onLoopFinish: cb.onLoopFinish,
      onNodeRetry: cb.onNodeRetry,
      onAgentLog: cb.onAgentLog,
      onError: cb.onError,
      onWorkflowPaused: cb.onWorkflowPaused,
      onHumanInputRequired: cb.onHumanInputRequired,
      onHumanInputFormFilled: cb.onHumanInputFormFilled,
      onHumanInputFormTimeout: cb.onHumanInputFormTimeout,
      onCompleted: cb.onCompleted,
    );
    final restCallback = RunCallbacks(
      silent: cb.silent,
      getAbortController: cb.getAbortController,
      onData: cb.onData,
      onNotifyError: cb.onNotifyError,
      onThought: cb.onThought,
      onFile: cb.onFile,
      onMessageEnd: cb.onMessageEnd,
      onMessageReplace: cb.onMessageReplace,
      onParallelBranchStarted: cb.onParallelBranchStarted,
      onParallelBranchFinished: cb.onParallelBranchFinished,
      onTextChunk: cb.onTextChunk,
      onReasoning: cb.onReasoning,
      onTextReplace: cb.onTextReplace,
      onTTSChunk: cb.onTTSChunk,
      onTTSEnd: cb.onTTSEnd,
      onDataSourceNodeProcessing: cb.onDataSourceNodeProcessing,
      onDataSourceNodeCompleted: cb.onDataSourceNodeCompleted,
      onDataSourceNodeError: cb.onDataSourceNodeError,
      onUnhandledEvent: cb.onUnhandledEvent,
    );
    store.setHistoryWorkflowData(null);
    final chat = isChatMode();
    final isInWorkflowDebug = !chat;
    final requestBody = buildWorkflowRunRequestBody(runMode, resolvedParams, options);
    final validation = validateWorkflowRunRequest(runMode, options);
    if (validation.isNotEmpty) {
      debugPrint(validation);
      return;
    }
    _abort?.abort();
    _abort = null;
    applyRunningStateForMode(store, runMode, options);

    final context = WorkflowRunCallbackContext(
      container: () => _container,
      isInWorkflowDebug: isInWorkflowDebug,
      fetchInspectVars: fetchInspectVars,
      invalidAllLastRun: invalidAllLastRun,
      invalidateRunHistory: invalidateRunHistory,
      clearAbortController: _clearAbortController,
      clearListeningState: () => clearListeningState(store),
      handlers: events,
      resume: (runId, callbacks) => _listen(service.workflowEvents(runId), callbacks),
      callbacks: userCallbacks,
      restCallback: restCallback,
    );
    final baseSseOptions = createBaseWorkflowRunCallbacks(context);

    if (isDebuggableTriggerType(runMode)) {
      _runTriggerDebug(runMode, requestBody, baseSseOptions);
      return;
    }
    final finalCallbacks = createFinalWorkflowRunCallbacks(
      context,
      baseSseOptions: baseSseOptions,
      setAbortController: (h) => _abort = h,
    );
    final stream = chat
        ? service.sendChatMessage(ChatMessageRequest(requestBody))
        : service.runWorkflowDraft(WorkflowDraftRunRequest(body: requestBody));
    _listen(stream, finalCallbacks);
  }

  /// `runTriggerDebug`: the trigger debug request waits for the trigger to fire (the service's stream stays silent
  /// meanwhile); the listening state ends when the run's events begin; a failure is a toast and a failed run.
  void _runTriggerDebug(TriggerType debugType, DifyJson requestBody, RunCallbacks baseSseOptions) {
    final label = switch (debugType) {
      TriggerType.webhook => 'Webhook',
      TriggerType.plugin => 'Plugin',
      TriggerType.all => 'All',
      _ => 'Schedule',
    };
    var started = false;
    final stream = service.runWorkflowDraft(WorkflowDraftRunRequest(mode: debugType, body: requestBody)).map((e) {
      if (!started) {
        started = true;
        clearListeningState(store);
      }
      return e;
    });
    final handle = _listen(
      stream,
      baseSseOptions.merge(
        RunCallbacks(
          silent: true,
          getAbortController: (h) => _abort = h,
          onError: (message, [code]) {
            if (started) {
              baseSseOptions.onError?.call(message, code);
              return;
            }
            final m = message.isEmpty ? '$label debug failed' : message;
            toast(DifyToastType.error, m);
            _clearAbortController();
            store.setWorkflowRunningData(createFailedWorkflowState(m));
            clearListeningState(store);
          },
        ),
      ),
    );
    _debugControllers[debugType] = handle;
  }

  /// `handleStopRun(taskId)`.
  void handleStopRun(String taskId) {
    if (taskId.isNotEmpty) {
      unawaited(service.stopWorkflowRun(taskId));
      applyStoppedState(store);
      return;
    }
    for (final c in _debugControllers.values) {
      c.abort();
    }
    _abort?.abort();
    _abort = null;
    _debugControllers.clear();
    applyStoppedState(store);
  }

  // ----- use-workflow-panel-interactions.ts -----

  /// `handleCancelDebugAndPreviewPanel`.
  void handleCancelDebugAndPreviewPanel() {
    store
      ..setShowDebugAndPreviewPanel(false)
      ..workflowRunningData.value = null;
    events
      ..handleNodeCancelRunningStatus()
      ..handleEdgeCancelRunningStatus();
  }

  // ----- use-workflow-start-run.tsx -----

  bool get _isRunning => runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.running;

  RunGraphNode? _nodeWhere(bool Function(RunGraphNode n) test) {
    for (final n in graph.nodes) {
      if (test(n)) return n;
    }
    return null;
  }

  /// `handleWorkflowStartRunInWorkflow`: runs at once when the Start node asks for nothing, else opens the inputs.
  Future<void> handleWorkflowStartRunInWorkflow() async {
    if (_isRunning) return;
    final startNode = _nodeWhere((n) => n.type == 'start');
    if (startNode == null) return;
    final startVariables = startNode.data['variables'];
    final file = store.features.value['file_upload'];
    final image = file is Map ? file['image'] : null;
    final imageEnabled = image is Map && image['enabled'] == true;
    store
      ..setShowEnvPanel(false)
      ..setShowGlobalVariablePanel(false);
    if (store.showDebugAndPreviewPanel.value) {
      handleCancelDebugAndPreviewPanel();
      return;
    }
    if ((startVariables is! List || startVariables.isEmpty) && !imageEnabled) {
      unawaited(handleRun({'inputs': <String, Object?>{}, 'files': <Object?>[]}));
      store
        ..setShowDebugAndPreviewPanel(true)
        ..setShowInputsPanel(false);
    } else {
      store
        ..setShowDebugAndPreviewPanel(true)
        ..setShowInputsPanel(true);
    }
  }

  Future<void> _triggerRun(
    String? nodeId,
    String type, {
    required TriggerType mode,
    required HandleRunOptions options,
    required DifyJson params,
    required bool cancelIfOpen,
  }) async {
    if (nodeId == null || nodeId.isEmpty) return;
    if (_isRunning) return;
    final node = _nodeWhere((n) => n.id == nodeId && n.type == type);
    if (node == null) {
      final kind = type.substring('trigger-'.length);
      final fn = 'handleWorkflowTrigger${kind[0].toUpperCase()}${kind.substring(1)}RunInWorkflow';
      debugPrint('$fn: $kind node not found $nodeId');
      return;
    }
    store
      ..setShowEnvPanel(false)
      ..setShowGlobalVariablePanel(false);
    if (cancelIfOpen) {
      if (store.showDebugAndPreviewPanel.value) {
        handleCancelDebugAndPreviewPanel();
        return;
      }
    } else {
      if (!store.showDebugAndPreviewPanel.value) store.setShowDebugAndPreviewPanel(true);
      store.setShowInputsPanel(false);
    }
    store
      ..setListeningTriggerType(type)
      ..setListeningTriggerNodeId(nodeId)
      ..setListeningTriggerNodeIds([nodeId])
      ..setListeningTriggerIsAll(false);
    unawaited(handleRun(params, options: options));
    if (cancelIfOpen) {
      store
        ..setShowDebugAndPreviewPanel(true)
        ..setShowInputsPanel(false);
    }
  }

  /// `handleWorkflowTriggerScheduleRunInWorkflow`.
  Future<void> handleWorkflowTriggerScheduleRunInWorkflow(String? nodeId) => _triggerRun(
    nodeId,
    'trigger-schedule',
    mode: TriggerType.schedule,
    options: HandleRunOptions(mode: TriggerType.schedule, scheduleNodeId: nodeId),
    params: const {},
    cancelIfOpen: true,
  );

  /// `handleWorkflowTriggerWebhookRunInWorkflow`.
  Future<void> handleWorkflowTriggerWebhookRunInWorkflow(String nodeId) => _triggerRun(
    nodeId,
    'trigger-webhook',
    mode: TriggerType.webhook,
    options: HandleRunOptions(mode: TriggerType.webhook, webhookNodeId: nodeId),
    params: {'node_id': nodeId},
    cancelIfOpen: false,
  );

  /// `handleWorkflowTriggerPluginRunInWorkflow`.
  Future<void> handleWorkflowTriggerPluginRunInWorkflow(String? nodeId) => _triggerRun(
    nodeId,
    'trigger-plugin',
    mode: TriggerType.plugin,
    options: HandleRunOptions(mode: TriggerType.plugin, pluginNodeId: nodeId),
    params: {'node_id': nodeId},
    cancelIfOpen: false,
  );

  /// `handleWorkflowRunAllTriggersInWorkflow`.
  Future<void> handleWorkflowRunAllTriggersInWorkflow(List<String> nodeIds) async {
    if (nodeIds.isEmpty) return;
    if (_isRunning) return;
    store
      ..setShowEnvPanel(false)
      ..setShowGlobalVariablePanel(false)
      ..setShowInputsPanel(false)
      ..setListeningTriggerIsAll(true)
      ..setListeningTriggerNodeIds(nodeIds)
      ..setListeningTriggerNodeId(null);
    if (!store.showDebugAndPreviewPanel.value) store.setShowDebugAndPreviewPanel(true);
    unawaited(
      handleRun({'node_ids': nodeIds}, options: HandleRunOptions(mode: TriggerType.all, allNodeIds: nodeIds)),
    );
  }

  /// `handleWorkflowStartRunInChatflow`: toggles the preview panel.
  Future<void> handleWorkflowStartRunInChatflow() async {
    store
      ..setShowEnvPanel(false)
      ..setShowChatVariablePanel(false)
      ..setShowGlobalVariablePanel(false);
    if (store.showDebugAndPreviewPanel.value) {
      handleCancelDebugAndPreviewPanel();
    } else {
      store.setShowDebugAndPreviewPanel(true);
    }
    store.setHistoryWorkflowData(null);
  }

  /// `handleStartWorkflowRun`.
  void handleStartWorkflowRun() =>
      isChatMode() ? handleWorkflowStartRunInChatflow() : handleWorkflowStartRunInWorkflow();

  /// The header's test-run menu choice (workflow-app's `useWorkflowStartRun` per trigger type).
  void handleStartRunFromOption(TriggerOption option) {
    switch (option.type) {
      case TriggerType.userInput:
        handleWorkflowStartRunInWorkflow();
      case TriggerType.schedule:
        handleWorkflowTriggerScheduleRunInWorkflow(option.nodeId);
      case TriggerType.webhook:
        if (option.nodeId != null) handleWorkflowTriggerWebhookRunInWorkflow(option.nodeId!);
      case TriggerType.plugin:
        handleWorkflowTriggerPluginRunInWorkflow(option.nodeId);
      case TriggerType.all:
        handleWorkflowRunAllTriggersInWorkflow(option.relatedNodeIds);
    }
  }

  // ----- run history (view-history, panel/record) -----

  Future<List<DifyJson>> fetchRunHistory() => service.fetchWorkflowRunHistory();
  Future<DifyJson> fetchRunDetail(String runId) => service.fetchRunDetail(runId);
  Future<List<DifyJson>> fetchTracingList(String runId) => service.fetchTracingList(runId);

  void dispose() {
    for (final s in _streams) {
      s.abort();
    }
    _streams.clear();
    lastRunVersion.dispose();
    runHistoryVersion.dispose();
  }
}
