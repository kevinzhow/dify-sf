import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_input.dart';
import 'trigger_status.dart';
import 'workflow_history.dart';

/// Dify-shaped data kept as the plain JSON Dify's code works on (React Flow nodes and edges, environment and
/// conversation variables, run data, version history, inspect variables, ...), with Dify's field names.
typedef DifyJson = Map<String, Object?>;

typedef MousePosition = ({double pageX, double pageY, double elementX, double elementY});

/// The box being dragged out, from (x1, y1) where it started to (x2, y2).
typedef SelectionBox = ({double x1, double y1, double x2, double y2});

/// help-line/types.ts.
typedef HelpLineHorizontalPosition = ({double top, double left, double width});
typedef HelpLineVerticalPosition = ({double top, double left, double height});

typedef ShowConfirm = ({String title, String? desc, VoidCallback onConfirm});

/// React Flow's Viewport.
typedef WorkflowViewport = ({double x, double y, double zoom});

typedef BackupDraft = ({
  List<DifyJson> nodes,
  List<DifyJson> edges,
  WorkflowViewport viewport,
  DifyJson? features,
  List<DifyJson> environmentVariables,
});

typedef ConnectingNodePayload = ({String nodeId, String nodeType, String handleType, String? handleId});
typedef EnteringNodePayload = ({String nodeId, DifyJson nodeData});

typedef AssignVariablePopup = ({
  String nodeId,
  DifyJson nodeData,
  String variableAssignerNodeId,
  DifyJson variableAssignerNodeData,
  String variableAssignerNodeHandleId,
  DifyJson? parentNode,
  double x,
  double y,
});

enum SingleRunAction { run, stop }

typedef PendingSingleRun = ({String nodeId, SingleRunAction action});

/// What the canvas context menu was opened on (panel-slice.ts).
sealed class WorkflowContextMenuTarget {
  const WorkflowContextMenuTarget();
  static const panel = PanelContextMenuTarget();
  static const selection = SelectionContextMenuTarget();
}

final class PanelContextMenuTarget extends WorkflowContextMenuTarget {
  const PanelContextMenuTarget();
}

final class SelectionContextMenuTarget extends WorkflowContextMenuTarget {
  const SelectionContextMenuTarget();
}

final class NodeContextMenuTarget extends WorkflowContextMenuTarget {
  const NodeContextMenuTarget(this.nodeId);
  final String nodeId;
  @override
  bool operator ==(Object other) => other is NodeContextMenuTarget && other.nodeId == nodeId;
  @override
  int get hashCode => nodeId.hashCode;
}

final class EdgeContextMenuTarget extends WorkflowContextMenuTarget {
  const EdgeContextMenuTarget(this.edgeId);
  final String edgeId;
  @override
  bool operator ==(Object other) => other is EdgeContextMenuTarget && other.edgeId == edgeId;
  @override
  int get hashCode => edgeId.hashCode;
}

/// es-toolkit's `debounce(fn, wait)` as the draft slice uses it: calling it (re)starts the wait and keeps the
/// latest callback; [flush] runs a pending callback now, [cancel] drops it.
class Debounced {
  Debounced(this.wait);
  final Duration wait;
  Timer? _timer;
  VoidCallback? _pending;

  void call(VoidCallback fn) {
    _pending = fn;
    _timer?.cancel();
    _timer = Timer(wait, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final fn = _pending;
    _pending = null;
    fn?.call();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}

/// Dify's workflow store (store/workflow/index.ts and its slices): the editor-wide UI state the chrome and the
/// panels share. Each field is its own [ValueNotifier] named as in Dify, so a widget listens to exactly the fields it
/// reads (`ValueListenableBuilder(valueListenable: store.showEnvPanel, ...)`, or `Listenable.merge` for several).
/// Dify's actions are the `setX` methods (some do more than set: the four exclusive panels, the version
/// timestamps); a port of Dify's `workflowStore.setState({x: v})` writes `store.x.value = v`.
///
/// [controlMode] is the canvas's own notifier ([CanvasController.controlMode]) when the editor passes it in, so the
/// canvas and the store never disagree. The document itself (nodes, edges) lives in the EditorController; the
/// node lists here are Dify's copies (clipboard, history snapshots, the draft slice's `nodes`).
///
/// Dify's injected slices (workflow-app, rag-pipeline) become subclasses or mixins on this class.
class WorkflowStore {
  WorkflowStore({ValueNotifier<ControlMode>? controlMode})
    : controlMode = controlMode ?? ValueNotifier(ControlMode.pointer),
      _ownsControlMode = controlMode == null;

  final _fields = <ChangeNotifier>[];
  final bool _ownsControlMode;

  ValueNotifier<T> _v<T>(T initial) {
    final n = ValueNotifier<T>(initial);
    _fields.add(n);
    return n;
  }

  // ----- workflow-slice.ts -----

  late final workflowRunningData = _v<DifyJson?>(null);
  void setWorkflowRunningData(DifyJson workflowData) => workflowRunningData.value = workflowData;
  late final isListening = _v(false);
  void setIsListening(bool listening) => isListening.value = listening;
  late final canvasReadOnly = _v(false);
  void setCanvasReadOnly(bool readOnly) => canvasReadOnly.value = readOnly;

  /// A trigger node type (`BlockEnum` value), or null.
  late final listeningTriggerType = _v<String?>(null);
  void setListeningTriggerType(String? triggerType) => listeningTriggerType.value = triggerType;
  late final listeningTriggerNodeId = _v<String?>(null);
  void setListeningTriggerNodeId(String? nodeId) => listeningTriggerNodeId.value = nodeId;
  late final listeningTriggerNodeIds = _v(const <String>[]);
  void setListeningTriggerNodeIds(List<String> nodeIds) => listeningTriggerNodeIds.value = nodeIds;
  late final listeningTriggerIsAll = _v(false);
  void setListeningTriggerIsAll(bool isAll) => listeningTriggerIsAll.value = isAll;
  late final clipboardElements = _v(const <DifyJson>[]);
  late final clipboardEdges = _v(const <DifyJson>[]);
  DifyJson clipboardAgentPackages = const {};
  DifyJson clipboardAgentSources = const {};
  void setClipboardElements(List<DifyJson> v) => clipboardElements.value = v;
  void setClipboardEdges(List<DifyJson> v) => clipboardEdges.value = v;
  void setClipboardData({required List<DifyJson> nodes, required List<DifyJson> edges}) {
    clipboardElements.value = nodes;
    clipboardEdges.value = edges;
    clipboardAgentPackages = const {};
    clipboardAgentSources = const {};
  }

  late final selection = _v<SelectionBox?>(null);
  void setSelection(SelectionBox? v) => selection.value = v;
  late final bundleNodeSize = _v<Size?>(null);
  void setBundleNodeSize(Size? v) => bundleNodeSize.value = v;

  /// Shared with the canvas (see the class comment).
  final ValueNotifier<ControlMode> controlMode;
  void setControlMode(ControlMode v) => controlMode.value = v;
  late final pendingComment = _v<MousePosition?>(null);
  void setPendingComment(MousePosition? v) => pendingComment.value = v;
  late final isCommentPlacing = _v(false);
  void setCommentPlacing(bool v) => isCommentPlacing.value = v;
  late final isCommentQuickAdd = _v(false);
  void setCommentQuickAdd(bool v) => isCommentQuickAdd.value = v;
  late final isCommentPreviewHovering = _v(false);
  void setCommentPreviewHovering(bool hovering) => isCommentPreviewHovering.value = hovering;
  late final mousePosition = _v<MousePosition>((pageX: 0, pageY: 0, elementX: 0, elementY: 0));
  void setMousePosition(MousePosition v) => mousePosition.value = v;
  late final showConfirm = _v<ShowConfirm?>(null);
  void setShowConfirm(ShowConfirm? v) => showConfirm.value = v;
  late final controlPromptEditorRerenderKey = _v(0);
  void setControlPromptEditorRerenderKey(int v) => controlPromptEditorRerenderKey.value = v;
  late final showImportDSLModal = _v(false);
  void setShowImportDSLModal(bool v) => showImportDSLModal.value = v;
  late final fileUploadConfig = _v<DifyJson?>(null);
  void setFileUploadConfig(DifyJson v) => fileUploadConfig.value = v;

  // ----- layout-slice.ts (sizes in logical pixels; the min/max math is in panel_width.dart) -----

  /// Measured by the editor (Dify's ResizeObserver on the workflow container); null until measured.
  late final workflowCanvasWidth = _v<double?>(null);
  late final workflowCanvasHeight = _v<double?>(null);
  void setWorkflowCanvasWidth(double width) => workflowCanvasWidth.value = width;
  void setWorkflowCanvasHeight(double height) => workflowCanvasHeight.value = height;

  /// rightPanelWidth - otherPanelWidth = nodePanelWidth (both measured by the right panel host).
  late final rightPanelWidth = _v<double?>(null);
  void setRightPanelWidth(double width) => rightPanelWidth.value = width;
  late final nodePanelWidth = _v(400.0);
  void setNodePanelWidth(double width) => nodePanelWidth.value = width;
  late final previewPanelWidth = _v(400.0);
  void setPreviewPanelWidth(double width) => previewPanelWidth.value = width;
  late final otherPanelWidth = _v(400.0);
  void setOtherPanelWidth(double width) => otherPanelWidth.value = width;

  /// Measured by the bottom operator bar; min 400, default auto (480).
  late final bottomPanelWidth = _v(480.0);
  void setBottomPanelWidth(double width) => bottomPanelWidth.value = width;
  late final bottomPanelHeight = _v(324.0);
  void setBottomPanelHeight(double height) => bottomPanelHeight.value = height;

  /// Min 120, default 320.
  late final variableInspectPanelHeight = _v(320.0);
  void setVariableInspectPanelHeight(double height) => variableInspectPanelHeight.value = height;

  // ----- panel-slice.ts -----

  late final panelWidth = _v(420.0);
  void setPanelWidth(double width) => panelWidth.value = width;
  late final showFeaturesPanel = _v(false);
  void setShowFeaturesPanel(bool v) => showFeaturesPanel.value = v;
  late final showWorkflowVersionHistoryPanel = _v(false);
  void setShowWorkflowVersionHistoryPanel(bool v) => showWorkflowVersionHistoryPanel.value = v;
  late final showInputsPanel = _v(false);
  void setShowInputsPanel(bool v) => showInputsPanel.value = v;

  /// One of the four exclusive panels, but (as in Dify) opening it does not close the other three.
  late final showDebugAndPreviewPanel = _v(false);
  void setShowDebugAndPreviewPanel(bool v) => showDebugAndPreviewPanel.value = v;
  late final showCommentsPanel = _v(false);
  void setShowCommentsPanel(bool v) => showCommentsPanel.value = v;
  late final showUserComments = _v(true);
  void setShowUserComments(bool v) => showUserComments.value = v;
  late final showUserCursors = _v(true);
  void setShowUserCursors(bool v) => showUserCursors.value = v;
  late final contextMenuTarget = _v<WorkflowContextMenuTarget?>(null);
  void setContextMenuTarget(WorkflowContextMenuTarget? v) => contextMenuTarget.value = v;
  late final showVariableInspectPanel = _v(false);
  void setShowVariableInspectPanel(bool v) => showVariableInspectPanel.value = v;
  late final initShowLastRunTab = _v(false);
  void setInitShowLastRunTab(bool v) => initShowLastRunTab.value = v;

  /// workflow-app's onboarding slice: a Start or trigger node just picked opens its next-block selector once
  /// (`shouldAutoOpenStartNodeSelector`), and whether a start node was picked (`hasSelectedStartNode`).
  late final shouldAutoOpenStartNodeSelector = _v(false);
  void setShouldAutoOpenStartNodeSelector(bool v) => shouldAutoOpenStartNodeSelector.value = v;
  late final hasSelectedStartNode = _v(false);
  void setHasSelectedStartNode(bool v) => hasSelectedStartNode.value = v;
  late final activeCommentId = _v<String?>(null);
  void setActiveCommentId(String? commentId) => activeCommentId.value = commentId;

  // ----- env-variable-slice.ts, chat-variable-slice.ts -----

  /// Env, conversation variables, global variables and debug/preview share the right side: opening one of the
  /// first three closes all four first; closing one closes only that one.
  void _showExclusive(ValueNotifier<bool> panel, bool show) {
    if (show) {
      for (final p in [showDebugAndPreviewPanel, showEnvPanel, showChatVariablePanel, showGlobalVariablePanel]) {
        if (p != panel) p.value = false;
      }
    }
    panel.value = show;
  }

  late final showEnvPanel = _v(false);
  void setShowEnvPanel(bool v) => _showExclusive(showEnvPanel, v);
  late final environmentVariables = _v(const <DifyJson>[]);
  void setEnvironmentVariables(List<DifyJson> v) => environmentVariables.value = v;
  late final envSecrets = _v(const <String, String>{});
  void setEnvSecrets(Map<String, String> v) => envSecrets.value = v;
  late final showChatVariablePanel = _v(false);
  void setShowChatVariablePanel(bool v) => _showExclusive(showChatVariablePanel, v);
  late final showGlobalVariablePanel = _v(false);
  void setShowGlobalVariablePanel(bool v) => _showExclusive(showGlobalVariablePanel, v);
  late final conversationVariables = _v(const <DifyJson>[]);
  void setConversationVariables(List<DifyJson> v) => conversationVariables.value = v;

  /// Dify's `workflow.features` (the server's shape: `opening_statement`, `file_upload`, ...) as the document holds
  /// it (protocol 1.7: `$app` config `features`), kept by AppRegistersSync. The features panel's store derives from it.
  late final features = _v(const <String, Object?>{});
  void setFeatures(DifyJson v) => features.value = v;

  // ----- form-slice.ts -----

  late final inputs = _v(const <String, Object>{});
  void setInputs(Map<String, Object> v) => inputs.value = v;
  late final files = _v(const <DifyJson>[]);
  void setFiles(List<DifyJson> v) => files.value = v;

  // ----- help-line-slice.ts -----

  late final helpLineHorizontal = _v<HelpLineHorizontalPosition?>(null);
  void setHelpLineHorizontal([HelpLineHorizontalPosition? v]) => helpLineHorizontal.value = v;
  late final helpLineVertical = _v<HelpLineVerticalPosition?>(null);
  void setHelpLineVertical([HelpLineVerticalPosition? v]) => helpLineVertical.value = v;

  // ----- history-slice.ts (+ zundo's temporal on `workflowHistory`) -----

  /// Writes are recorded in [temporal] (undo/redo) unless it is paused.
  late final workflowHistory = WorkflowHistoryValue(WorkflowHistoryState.empty);

  /// Undo/redo over [workflowHistory] (zundo's `temporal`).
  WorkflowHistoryTemporal get temporal => workflowHistory.temporal;
  late final initializedWorkflowHistory = _v<WorkflowHistoryState?>(null);
  void initializeWorkflowHistory(WorkflowHistoryState v) {
    initializedWorkflowHistory.value = v;
    workflowHistory.value = v;
  }

  void setWorkflowHistory(WorkflowHistoryState v) => workflowHistory.value = v;
  late final historyShortcutsEnabled = _v(true);
  void setHistoryShortcutsEnabled(bool enabled) => historyShortcutsEnabled.value = enabled;
  late final historyWorkflowData = _v<DifyJson?>(null);
  void setHistoryWorkflowData([DifyJson? v]) => historyWorkflowData.value = v;
  late final showRunHistory = _v(false);
  void setShowRunHistory(bool v) => showRunHistory.value = v;
  late final versionHistory = _v(const <DifyJson>[]);
  void setVersionHistory(List<DifyJson> v) => versionHistory.value = v;

  // ----- node-slice.ts -----

  late final checklistItems = _v(const <DifyJson>[]);
  late final showSingleRunPanel = _v(false);
  void setShowSingleRunPanel(bool v) => showSingleRunPanel.value = v;
  late final nodeAnimation = _v(false);
  void setNodeAnimation(bool v) => nodeAnimation.value = v;
  late final candidateNode = _v<DifyJson?>(null);
  void setCandidateNode([DifyJson? v]) => candidateNode.value = v;
  late final openInlineAgentPanelNodeId = _v<String?>(null);
  void setOpenInlineAgentPanelNodeId([String? nodeId]) => openInlineAgentPanelNodeId.value = nodeId;
  late final showAssignVariablePopup = _v<AssignVariablePopup?>(null);
  void setShowAssignVariablePopup(AssignVariablePopup? v) => showAssignVariablePopup.value = v;
  late final hoveringAssignVariableGroupId = _v<String?>(null);
  void setHoveringAssignVariableGroupId([String? v]) => hoveringAssignVariableGroupId.value = v;
  late final connectingNodePayload = _v<ConnectingNodePayload?>(null);
  void setConnectingNodePayload([ConnectingNodePayload? v]) => connectingNodePayload.value = v;
  late final enteringNodePayload = _v<EnteringNodePayload?>(null);
  void setEnteringNodePayload([EnteringNodePayload? v]) => enteringNodePayload.value = v;
  late final iterTimes = _v(1);
  void setIterTimes(int v) => iterTimes.value = v;
  late final loopTimes = _v(1);
  void setLoopTimes(int v) => loopTimes.value = v;

  /// Iteration/loop id → parallel run id → node tracings.
  late final iterParallelLogMap = _v(<String, Map<String, List<DifyJson>>>{});
  void setIterParallelLogMap(Map<String, Map<String, List<DifyJson>>> v) => iterParallelLogMap.value = v;
  late final pendingSingleRun = _v<PendingSingleRun?>(null);
  void setPendingSingleRun([PendingSingleRun? payload]) => pendingSingleRun.value = payload;

  // ----- tool-slice.ts -----

  late final toolPublished = _v(false);
  void setToolPublished(bool v) => toolPublished.value = v;
  late final lastPublishedHasUserInput = _v(false);
  void setLastPublishedHasUserInput(bool hasUserInput) => lastPublishedHasUserInput.value = hasUserInput;
  late final buildInTools = _v<List<DifyJson>?>(null);
  late final customTools = _v<List<DifyJson>?>(null);
  late final workflowTools = _v<List<DifyJson>?>(null);
  late final mcpTools = _v<List<DifyJson>?>(null);

  // ----- version-slice.ts (the API's seconds stored as milliseconds) -----

  late final draftUpdatedAt = _v(0);
  void setDraftUpdatedAt(int seconds) => draftUpdatedAt.value = seconds != 0 ? seconds * 1000 : 0;
  late final publishedAt = _v(0);
  void setPublishedAt(int seconds) => publishedAt.value = seconds != 0 ? seconds * 1000 : 0;
  late final currentVersion = _v<DifyJson?>(null);
  void setCurrentVersion(DifyJson v) => currentVersion.value = v;
  late final isRestoring = _v(false);
  void setIsRestoring(bool v) => isRestoring.value = v;

  // ----- workflow-draft-slice.ts -----

  late final backupDraft = _v<BackupDraft?>(null);
  void setBackupDraft([BackupDraft? v]) => backupDraft.value = v;

  /// Runs the given draft sync 5 s after the last call.
  final debouncedSyncWorkflowDraft = Debounced(const Duration(seconds: 5));
  late final syncWorkflowDraftHash = _v('');
  void setSyncWorkflowDraftHash(String hash) => syncWorkflowDraftHash.value = hash;
  late final isSyncingWorkflowDraft = _v(false);
  void setIsSyncingWorkflowDraft(bool v) => isSyncingWorkflowDraft.value = v;
  late final isWorkflowDataLoaded = _v(false);
  void setIsWorkflowDataLoaded(bool loaded) => isWorkflowDataLoaded.value = loaded;
  late final nodes = _v(const <DifyJson>[]);
  void setNodes(List<DifyJson> v) => nodes.value = v;
  void flushPendingSync() => debouncedSyncWorkflowDraft.flush();

  // ----- comment-slice.ts -----

  late final comments = _v(const <DifyJson>[]);
  void setComments(List<DifyJson> v) => comments.value = v;
  late final commentsLoading = _v(false);
  void setCommentsLoading(bool loading) => commentsLoading.value = loading;
  late final showResolvedComments = _v(false);
  void setShowResolvedComments(bool showResolved) => showResolvedComments.value = showResolved;
  late final activeCommentDetail = _v<DifyJson?>(null);
  void setActiveCommentDetail(DifyJson? comment) => activeCommentDetail.value = comment;
  late final activeCommentDetailLoading = _v(false);
  void setActiveCommentDetailLoading(bool loading) => activeCommentDetailLoading.value = loading;
  late final replySubmitting = _v(false);
  void setReplySubmitting(bool loading) => replySubmitting.value = loading;
  late final replyUpdating = _v(false);
  void setReplyUpdating(bool loading) => replyUpdating.value = loading;
  late final commentDetailCache = _v(const <String, DifyJson>{});
  void setCommentDetailCache(Map<String, DifyJson> cache) => commentDetailCache.value = cache;
  late final mentionableUsersCache = _v(const <String, List<DifyJson>>{});
  void setMentionableUsersCache(String appId, List<DifyJson> users) =>
      mentionableUsersCache.value = {...mentionableUsersCache.value, appId: users};
  late final mentionableUsersLoading = _v(const <String, bool>{});
  void setMentionableUsersLoading(String appId, bool loading) =>
      mentionableUsersLoading.value = {...mentionableUsersLoading.value, appId: loading};

  // ----- debug/inspect-vars-slice.ts (NodeWithVar and VarInInspect as Dify's JSON; updates copy on write) -----

  late final currentFocusNodeId = _v<String?>(null);
  void setCurrentFocusNodeId(String? nodeId) => currentFocusNodeId.value = nodeId;

  /// The nodes that have inspect variables: `{nodeId, nodePayload, nodeType, title, vars, isValueFetched}`.
  late final nodesWithInspectVars = _v(const <DifyJson>[]);
  late final conversationVars = _v(const <DifyJson>[]);
  void setNodesWithInspectVars(List<DifyJson> payload) => nodesWithInspectVars.value = payload;
  void deleteAllInspectVars() => nodesWithInspectVars.value = const [];

  void setNodeInspectVars(String nodeId, List<DifyJson> payload) =>
      _updateInspectNode(nodeId, (node) => {...node, 'vars': payload, 'isValueFetched': true});

  void deleteNodeInspectVars(String nodeId) =>
      nodesWithInspectVars.value = [...nodesWithInspectVars.value.where((n) => n['nodeId'] != nodeId)];

  void setInspectVarValue(String nodeId, String varId, Object? value) =>
      _updateInspectVar(nodeId, varId, (v) => {...v, 'value': value, 'edited': true});

  void resetToLastRunVar(String nodeId, String varId, Object? value) =>
      _updateInspectVar(nodeId, varId, (v) => {...v, 'value': value, 'edited': false});

  void renameInspectVarName(String nodeId, String varId, List<String> selector) =>
      _updateInspectVar(nodeId, varId, (v) => {...v, 'name': selector[1], 'selector': selector});

  void deleteInspectVar(String nodeId, String varId) => _updateInspectNode(nodeId, (node) {
    final vars = _varsOf(node);
    final i = vars.indexWhere((v) => v['id'] == varId);
    return i == -1
        ? null
        : {
            ...node,
            'vars': [...vars]..removeAt(i),
          };
  });

  static List<DifyJson> _varsOf(DifyJson node) => [...(node['vars'] as List? ?? const []).cast<DifyJson>()];

  /// Replaces the node [nodeId] with [update]'s result; nothing changes (same list) when the node is missing or
  /// [update] returns null.
  void _updateInspectNode(String nodeId, DifyJson? Function(DifyJson node) update) {
    final list = nodesWithInspectVars.value;
    final i = list.indexWhere((n) => n['nodeId'] == nodeId);
    if (i == -1) return;
    final next = update(list[i]);
    if (next == null) return;
    nodesWithInspectVars.value = [...list]..[i] = next;
  }

  void _updateInspectVar(String nodeId, String varId, DifyJson Function(DifyJson v) update) =>
      _updateInspectNode(nodeId, (node) {
        final vars = _varsOf(node);
        final i = vars.indexWhere((v) => v['id'] == varId);
        if (i == -1) return null;
        return {...node, 'vars': vars..[i] = update(vars[i])};
      });

  // ----- run view state (dify-sf): the run fields Dify keeps in React Flow's node and edge `data` -----

  /// Node id → Dify's run fields of that node (`_runningStatus`, `_waitingRun`, `_runningBranchId`, `_retryIndex`,
  /// `_iterationIndex`, `_iterationLength`, `_loopIndex`, `_loopLength`, `_singleRunningStatus`, `_isSingleRun`).
  /// Local view state: never written to the document (runs are not collaboration ops). Replaced on write.
  late final nodeRunData = _v(const <String, DifyJson>{});

  /// Edge id → `_sourceRunningStatus`, `_targetRunningStatus`, `_waitingRun`.
  late final edgeRunData = _v(const <String, DifyJson>{});

  DifyJson nodeRunDataOf(String nodeId) => nodeRunData.value[nodeId] ?? const {};
  DifyJson edgeRunDataOf(String edgeId) => edgeRunData.value[edgeId] ?? const {};

  /// Merges [patch] into the node's run fields (a null value removes the field).
  void setNodeRunData(String nodeId, DifyJson patch) => nodeRunData.value = {
    ...nodeRunData.value,
    nodeId: _merged(nodeRunDataOf(nodeId), patch),
  };

  void setEdgeRunData(String edgeId, DifyJson patch) => edgeRunData.value = {
    ...edgeRunData.value,
    edgeId: _merged(edgeRunDataOf(edgeId), patch),
  };

  static DifyJson _merged(DifyJson a, DifyJson patch) {
    final m = {...a, ...patch};
    m.removeWhere((_, v) => v == null);
    return m;
  }

  // ----- trigger-status.ts -----

  /// Entry (trigger) nodes' enabled state; a global store in Dify, one per editor here.
  final triggerStatus = TriggerStatusStore();

  void dispose() {
    debouncedSyncWorkflowDraft.cancel();
    for (final f in _fields) {
      f.dispose();
    }
    workflowHistory.dispose();
    triggerStatus.dispose();
    if (_ownsControlMode) controlMode.dispose();
  }
}
