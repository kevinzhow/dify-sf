import 'package:flutter/foundation.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../editor/undo_manager.dart';
import '../../i18n/dify_i18n.dart';
import '../store/store.dart';

/// more-actions.tsx export types.
enum ExportImageFormat { png, jpeg, svg }

/// What the app gives the operator; Dify gets these from hooks and system features.
class OperatorOptions {
  const OperatorOptions({
    this.collaborationEnabled = false,
    this.onAddNote,
    this.onOrganize,
    this.onExportImage,
    this.onSyncDraft,
  });

  /// systemFeatures.enable_collaboration_mode: adds the comment mode button and shortcut, and the comments and
  /// collaborator cursors items of the zoom menu.
  final bool collaborationEnabled;

  /// operator/hooks.ts handleAddNote (creates a candidate note).
  final VoidCallback? onAddNote;

  /// useWorkflowOrganize handleLayout, from the Organize button and Mod+O.
  final VoidCallback? onOrganize;

  /// more-actions.tsx handleExportImage, called after the menu has closed. [wholeWorkflow] is the "Current
  /// Workflow" group, otherwise "Current View".
  final void Function(ExportImageFormat format, {required bool wholeWorkflow})? onExportImage;

  /// useNodesSyncDraft handleSyncWorkflowDraft, called after a zoom from the zoom menu or a shortcut.
  final VoidCallback? onSyncDraft;
}

String tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// use-workflow.ts read-only states, read from the store.
extension OperatorReadOnly on WorkflowStore {
  String? get _runStatus => switch (workflowRunningData.value?['result']) {
    final Map<String, Object?> r => r['status'] as String?,
    _ => null,
  };

  bool get _runningOrPaused => _runStatus == 'running' || _runStatus == 'paused';

  /// useNodesReadOnly. Dify's `accessControl.canEdit` is not ported; use [WorkflowStore.canvasReadOnly] for it.
  bool get nodesReadOnly =>
      canvasReadOnly.value || _runningOrPaused || historyWorkflowData.value != null || isRestoring.value;

  /// useWorkflowReadOnly.
  bool get workflowReadOnly => canvasReadOnly.value || _runStatus == 'running';

  /// useWorkflowMoveMode isCommentModeOperationBlocked.
  bool get commentModeBlocked => _runningOrPaused || historyWorkflowData.value != null || isRestoring.value;

  /// The fields the states above depend on.
  Listenable get readOnlyChanges =>
      Listenable.merge([canvasReadOnly, workflowRunningData, historyWorkflowData, isRestoring]);
}

/// The handlers the operator and its shortcuts share: useWorkflowMoveMode, handleHistoryBack/Forward
/// (use-nodes-interactions.ts), and the constrained zoom of use-workflow-hotkeys.ts.
class OperatorActions {
  OperatorActions(this.canvas, this.store, {this.history, this.options = const OperatorOptions()});

  final CanvasController canvas;
  final WorkflowStore store;
  final UndoManager? history;
  final OperatorOptions options;

  bool get canUseCommentMode => options.collaborationEnabled && !store.commentModeBlocked;

  void modePointer() {
    if (store.nodesReadOnly) return;
    store.setControlMode(ControlMode.pointer);
  }

  void modeHand() {
    if (store.nodesReadOnly) return;
    store.setControlMode(ControlMode.hand);
    _cancelSelection();
  }

  void modeComment() {
    if (!canUseCommentMode) return;
    store.setControlMode(ControlMode.comment);
    _cancelSelection();
  }

  /// handleSelectionCancel: drops the box selection (Dify's bundled nodes). A single selected node stays selected.
  void _cancelSelection() {
    store.setSelection(null);
    if (canvas.selection.nodes.length > 1) canvas.selection.selectNodes(const []);
  }

  void organize() {
    if (store.nodesReadOnly) return;
    options.onOrganize?.call();
  }

  void historyBack() => _history(() => history?.undo());
  void historyForward() => _history(() => history?.redo());

  void _history(VoidCallback step) {
    if (store.nodesReadOnly || store.workflowReadOnly) return;
    step();
    store.setContextMenuTarget(null);
  }

  /// A zoom from a shortcut or the zoom menu, followed by a draft sync.
  void zoom(void Function(CanvasController canvas) apply) {
    apply(canvas);
    options.onSyncDraft?.call();
  }

  /// constrainedZoomIn / constrainedZoomOut: the zoom plus [delta], within 0.25 and 2.
  void zoomBy(double delta) => zoom((c) => c.zoomTo((c.view.scale + delta).clamp(0.25, 2.0)));
}
