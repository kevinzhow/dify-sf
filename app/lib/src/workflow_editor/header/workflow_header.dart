import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'header_buttons.dart';
import 'header_data.dart';
import 'header_widgets.dart';
import 'online_users.dart';
import 'run_and_history.dart';
import 'titles.dart';
import 'view_history.dart';

export 'header_data.dart';

String _tr(String key) => DifyI18n.tr('workflow', key);

/// Dify's workflow header (header/index.tsx with workflow-app's WorkflowHeader): the row over the top of the canvas,
/// in one of three modes (useWorkflowMode): editing ([HeaderInNormal]), viewing a past run ([HeaderInHistory],
/// while the store's `historyWorkflowData` is set) and browsing versions ([HeaderInRestoring], `isRestoring`).
///
/// Fills WorkflowEditor's `header` slot; [data] connects it to the app, [canvas] gives it the selection and the
/// view (scroll to the selected node, jump to a collaborator).
class WorkflowHeader extends StatelessWidget {
  const WorkflowHeader({super.key, this.data = const WorkflowHeaderData(), this.canvas});

  final WorkflowHeaderData data;
  final CanvasController? canvas;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return WorkflowHeaderScope(
      data: data,
      canvas: canvas,
      child: ListenableBuilder(
        listenable: Listenable.merge([store.historyWorkflowData, store.isRestoring]),
        builder: (context, _) {
          final (:normal, :restoring, :viewHistory) = workflowModeOf(store);
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (normal) const Expanded(child: HeaderInNormal()),
              if (viewHistory) ...const [RunningTitle(), HeaderInHistory()],
              if (restoring) ...const [RestoringTitle(), HeaderInRestoring()],
            ],
          );
        },
      ),
    );
  }
}

/// header/header-in-normal.tsx: the save status, "Scroll to selected node", and on the right the online users,
/// `left`, the run pill, the variable buttons, `middle` (Features, Publish) and the version history button.
class HeaderInNormal extends StatelessWidget {
  const HeaderInNormal({super.key});

  /// onStartRestoring: enter the version browser, keeping the draft and closing the right-hand panels.
  static void startRestoring(WorkflowStore store, WorkflowHeaderData data, CanvasController? canvas) {
    store.isRestoring.value = true;
    data.handleBackupDraft?.call();
    final selected = canvas == null ? null : selectedNodeIdOf(canvas);
    if (selected != null) data.handleNodeSelect?.call(selected, cancelSelection: true);
    store
      ..setShowWorkflowVersionHistoryPanel(true)
      ..setShowEnvPanel(false)
      ..setShowDebugAndPreviewPanel(false)
      ..setShowVariableInspectPanel(false)
      ..setShowChatVariablePanel(false)
      ..setShowGlobalVariablePanel(false);
    data.closeAllInputFieldPanels?.call();
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    final canvas = WorkflowHeaderScope.canvasOf(context);
    final showContextButtons = data.isChatMode || data.showEnvButton || data.showGlobalVariableButton;
    final compact = DifyAdaptive.toolbarCompactOf(context);
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        // The `left` slot and its gap go when it shows nothing.
        if (data.left case final left?)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const OnlineUsers(),
              GapBefore(gap: 8, child: left),
            ],
          )
        else
          const OnlineUsers(),
        const HeaderDivider(),
        RunAndHistory(
          showRunButton: !data.isChatMode,
          showPreviewButton: data.isChatMode,
          runButtonText: data.runButtonText,
        ),
        if (showContextButtons)
          ListenableBuilder(
            listenable: nodesReadOnlyListenable(store),
            builder: (context, _) {
              final readOnly = nodesReadOnlyOf(store, canEdit: data.canEdit);
              final r = BorderRadius.circular(DifyRadius.lg);
              return DifyBlurredBox(
                blur: 10,
                borderRadius: r,
                decoration: headerPillDecoration(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (data.isChatMode) ChatVariableButton(disabled: readOnly),
                    if (data.showEnvButton) EnvButton(disabled: readOnly),
                    if (data.showGlobalVariableButton) GlobalVariableButton(disabled: readOnly),
                  ],
                ),
              );
            },
          ),
        if (!compact) ?data.middle,
        if (data.canReleaseAndVersion) VersionHistoryButton(onClick: () => startRestoring(store, data, canvas)),
      ],
    );
    if (compact) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(child: data.title ?? const EditingTitle()),
              ?data.middle,
            ],
          ),
          DifyToolbarStrip(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                const ScrollToSelectedNodeButton(),
                actions,
              ],
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(child: data.title ?? const EditingTitle()),
        const ScrollToSelectedNodeButton(),
        actions,
      ],
    );
  }
}

/// header/header-in-view-history.tsx: "Show Run History" and "Go back to editor" (brings the draft back).
class HeaderInHistory extends StatelessWidget {
  const HeaderInHistory({super.key});

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        const ViewHistory(withText: true),
        const HeaderDivider(),
        DifyButton(
          variant: DifyButtonVariant.primary,
          onPressed: () {
            data.handleLoadBackupDraft?.call();
            store.historyWorkflowData.value = null;
          },
          leading: const DifyIcon('vender/line/arrows/arrow-narrow-left', size: 16),
          child: Text(_tr('common.goBackToEdit')),
        ),
      ],
    );
  }
}

/// header/header-in-restoring.tsx: "Restore" (the viewed version over the draft) and "Exit Versions".
class HeaderInRestoring extends StatefulWidget {
  const HeaderInRestoring({super.key});

  @override
  State<HeaderInRestoring> createState() => _HeaderInRestoringState();
}

class _HeaderInRestoringState extends State<HeaderInRestoring> {
  Future<void> _restore(WorkflowStore store, WorkflowHeaderData data) async {
    final v = store.currentVersion.value;
    final restore = data.restoreWorkflow;
    if (v == null || restore == null) return;
    store.setShowWorkflowVersionHistoryPanel(false);
    try {
      await restore('${v['id']}');
      store
        ..isRestoring.value = false
        ..backupDraft.value = null;
      data.handleRefreshWorkflowDraft?.call();
      data.toast?.call(HeaderToastType.success, _tr('versionHistory.action.restoreSuccess'));
      store.deleteAllInspectVars();
      data.invalidAllLastRun?.call();
    } catch (_) {
      data.toast?.call(HeaderToastType.error, _tr('versionHistory.action.restoreFailure'));
    } finally {
      data.resetWorkflowVersionHistory?.call();
      data.onRestoreSettled?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.currentVersion,
      builder: (context, v, _) {
        final id = v?['id'];
        final canRestore =
            id is String && id.isNotEmpty && data.restoreWorkflow != null && v?['version'] != workflowVersionDraft;
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            DifyButton(
              variant: DifyButtonVariant.primary,
              disabled: !canRestore,
              restyle: difyDarkGlass(),
              onPressed: () => _restore(store, data),
              child: Text(_tr('common.restore')),
            ),
            DifyButton(
              onPressed: () {
                data.handleLoadBackupDraft?.call();
                store
                  ..isRestoring.value = false
                  ..setShowWorkflowVersionHistoryPanel(false);
              },
              restyle: difyDarkGlass(),
              semanticLabel: _tr('common.exitVersions'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  RemixIcon('history-line', size: 16, color: DifyColors.componentsButtonSecondaryAccentText),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      _tr('common.exitVersions'),
                      style: TextStyle(color: DifyColors.componentsButtonSecondaryAccentText),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
