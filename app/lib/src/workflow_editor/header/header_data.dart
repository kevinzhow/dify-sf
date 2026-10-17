import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../store/plugin_dependency_store.dart';
import '../store/workflow_store.dart';
import 'checklist/checklist_item.dart';
import 'format.dart';
import 'test_run_menu.dart';

/// dify-ui's toast types.
enum HeaderToastType { success, error, warning, info }

typedef HeaderToast = void Function(HeaderToastType type, String message);

/// A node as the header sees it (the parts of Dify's `useNodes()` the header reads).
@immutable
class HeaderNode {
  const HeaderNode({required this.id, required this.type, this.title = '', this.data = const {}});

  final String id;

  /// The node type (`BlockEnum` value: `start`, `end`, `trigger-webhook`, ...).
  final String type;
  final String title;

  /// Dify's node `data` (only what the header needs: `provider_id`, `plugin_name`, `variables`, `outputs`).
  final DifyJson data;
}

/// What the header knows about the graph, recomputed by the host when the document changes.
@immutable
class WorkflowGraphFacts {
  const WorkflowGraphFacts({this.nodes = const [], this.hasUserInputNode = false, this.checklist = const []});

  static const empty = WorkflowGraphFacts();

  final List<HeaderNode> nodes;

  /// A Start node has an outgoing edge (features-trigger.tsx `hasUserInputNode`).
  final bool hasUserInputNode;

  /// useChecklist's items (the warning nodes).
  final List<ChecklistItem> checklist;
}

/// Someone editing this workflow (collaboration/types `OnlineUser`).
@immutable
class OnlineUser {
  const OnlineUser({required this.sid, required this.userId, this.username = '', this.avatar});

  /// One per connection.
  final String sid;
  final String userId;
  final String username;

  /// An avatar image URL.
  final String? avatar;
}

/// Everything the header needs from the app around it: Dify's hooks store (access control, configs), the workflow
/// hooks it calls (backup/restore the draft, select nodes, run, stop), the services it queries (run history,
/// restore), the graph and the collaborators. All optional: a missing callback leaves its action without effect
/// (or the control disabled where Dify disables it, noted per field), so the header has no backend dependencies.
@immutable
class WorkflowHeaderData {
  const WorkflowHeaderData({
    this.graph,
    this.isChatMode = false,
    this.canEdit = true,
    this.canRun = true,
    this.canReleaseAndVersion = true,
    this.currentUserId,
    this.onlineUsers,
    this.cursorOf,
    this.formatters = const HeaderFormatters(),
    this.toast,
    this.title,
    this.left,
    this.middle,
    this.showEnvButton = true,
    this.showGlobalVariableButton = true,
    this.runButtonText,
    this.handleBackupDraft,
    this.handleLoadBackupDraft,
    this.handleRefreshWorkflowDraft,
    this.handleNodeSelect,
    this.handleNodesCancelSelected,
    this.closeAllInputFieldPanels,
    this.onRun,
    this.onRunInChatflow,
    this.onStopRun,
    this.fetchRunHistory,
    this.onClearLogAndMessageModal,
    this.restoreWorkflow,
    this.invalidAllLastRun,
    this.resetWorkflowVersionHistory,
    this.onRestoreSettled,
    this.pluginDependencies,
    this.scrollToNode,
  });

  /// The nodes, the start node's connection and the checklist; null: an empty graph.
  final ValueListenable<WorkflowGraphFacts>? graph;

  /// Chatflow (advanced-chat): Preview instead of Test Run, the conversation variables button, Features.
  final bool isChatMode;

  /// `accessControl` of Dify's hooks store.
  final bool canEdit;
  final bool canRun;
  final bool canReleaseAndVersion;

  /// The signed-in user (marked "(You)" among the online users).
  final String? currentUserId;

  /// The other people editing (and this user); null or empty hides the pill.
  final ValueListenable<List<OnlineUser>>? onlineUsers;

  /// Where a collaborator's cursor is on the canvas (canvas coordinates); clicking their avatar centres on it.
  final Offset? Function(String userId)? cursorOf;

  final HeaderFormatters formatters;

  /// Shows a toast (Dify's `toast.success` / `toast.error`).
  final HeaderToast? toast;

  /// HeaderInNormal `components.title` (default: the auto-saved / published line), `components.left` (before the
  /// divider) and `components.middle` (after the variable buttons: Features and Publish, see FeaturesTrigger).
  final Widget? title;
  final Widget? left;
  final Widget? middle;

  /// HeaderInNormal `controls`.
  final bool showEnvButton;
  final bool showGlobalVariableButton;

  /// RunAndHistory `runButtonText` (default: "Test Run").
  final String? runButtonText;

  /// useWorkflowRun's handleBackupDraft / handleLoadBackupDraft (keep and bring back the draft around viewing a run
  /// or a version); useWorkflowRefreshDraft's handleRefreshWorkflowDraft (reload the draft after a restore).
  final VoidCallback? handleBackupDraft;
  final VoidCallback? handleLoadBackupDraft;
  final VoidCallback? handleRefreshWorkflowDraft;

  /// useNodesInteractions' handleNodeSelect(id, cancelSelection) and handleNodesCancelSelected. Without them the
  /// header uses the canvas selection it was given.
  final void Function(String nodeId, {bool cancelSelection})? handleNodeSelect;
  final VoidCallback? handleNodesCancelSelected;

  /// useInputFieldPanel's closeAllInputFieldPanels (RAG pipelines).
  final VoidCallback? closeAllInputFieldPanels;

  /// Starts a test run from [option] (useWorkflowStartRun's handlers per trigger type); runs only after the
  /// checklist allows it.
  final void Function(TriggerOption option)? onRun;

  /// Chatflow Preview (handleWorkflowStartRunInChatflow).
  final VoidCallback? onRunInChatflow;

  /// useWorkflowRun's handleStopRun(taskId).
  final void Function(String taskId)? onStopRun;

  /// The run history (Dify's WorkflowRunHistory JSON, newest first), fetched when the popup opens; null: no history.
  final Future<List<DifyJson>> Function()? fetchRunHistory;

  /// ViewHistory `onClearLogAndMessageModal`.
  final VoidCallback? onClearLogAndMessageModal;

  /// Restores the version with this id over the draft (Dify's restore request); null keeps Restore disabled (Dify:
  /// the flow is not ready).
  final Future<void> Function(String versionId)? restoreWorkflow;

  /// After a successful restore: useInvalidAllLastRun. After any restore: useResetWorkflowVersionHistory, then
  /// HeaderInRestoring's `onRestoreSettled`.
  final VoidCallback? invalidAllLastRun;
  final VoidCallback? resetWorkflowVersionHistory;
  final VoidCallback? onRestoreSettled;

  /// Where the checklist's "Install" puts the missing plugins (Dify's plugin dependency store).
  final PluginDependencyStore? pluginDependencies;

  /// Brings a node into view (Dify's `scrollToWorkflowNode`); null: the header animates the canvas view itself.
  final void Function(String nodeId)? scrollToNode;

  WorkflowGraphFacts get facts => graph?.value ?? WorkflowGraphFacts.empty;
}

/// Hands the header's data and the canvas to its parts.
class WorkflowHeaderScope extends InheritedWidget {
  const WorkflowHeaderScope({super.key, required this.data, this.canvas, required super.child});

  final WorkflowHeaderData data;
  final CanvasController? canvas;

  static WorkflowHeaderScope? _maybe(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkflowHeaderScope>();

  /// The header's data (defaults when there is no scope, as in a part tested on its own).
  static WorkflowHeaderData of(BuildContext context) => _maybe(context)?.data ?? const WorkflowHeaderData();

  static CanvasController? canvasOf(BuildContext context) => _maybe(context)?.canvas;

  @override
  bool updateShouldNotify(WorkflowHeaderScope oldWidget) => data != oldWidget.data || canvas != oldWidget.canvas;
}

/// `WorkflowRunningStatus` (workflow/types.ts).
abstract final class WorkflowRunningStatus {
  static const waiting = 'waiting';
  static const running = 'running';
  static const succeeded = 'succeeded';
  static const failed = 'failed';
  static const stopped = 'stopped';
  static const paused = 'paused';
}

/// The running data's status (`workflowRunningData?.result.status`).
String? runningStatusOf(DifyJson? workflowRunningData) => switch (workflowRunningData?['result']) {
  final Map<String, Object?> r => r['status'] as String?,
  _ => null,
};

/// useNodesReadOnly: the canvas is read-only, the user can't edit, a run is going on or paused, a run or a version
/// is being viewed.
bool nodesReadOnlyOf(WorkflowStore s, {required bool canEdit}) {
  final status = runningStatusOf(s.workflowRunningData.value);
  return s.canvasReadOnly.value ||
      !canEdit ||
      status == WorkflowRunningStatus.running ||
      status == WorkflowRunningStatus.paused ||
      s.historyWorkflowData.value != null ||
      s.isRestoring.value;
}

/// The store fields [nodesReadOnlyOf] reads.
Listenable nodesReadOnlyListenable(WorkflowStore s) =>
    Listenable.merge([s.canvasReadOnly, s.workflowRunningData, s.historyWorkflowData, s.isRestoring]);
