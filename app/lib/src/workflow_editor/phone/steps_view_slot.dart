/// The phone editor's Steps view slot (dify-sf): the phone chrome shows the widget [workflowStepsView] builds while
/// the user picks "Steps" in the editor's Steps | Canvas switch. The Steps view itself lives in `../steps/`.
library;

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';

/// What the phone chrome hands the Steps view. The view is built inside the editor, so it also finds the editor's
/// scopes: `WorkflowStoreScope.of` (the store: run data, read-only state), `WorkflowHeaderScope.of(context).graph`
/// (the checklist's items), `BlockSelectorScope.of` and `WorkflowRunScope.maybeOf`. It sits between the view switch
/// and the bottom toolbar, with the top and bottom insets already taken (`MediaQuery.paddingOf` is zero there).
@immutable
class StepsViewHost {
  const StepsViewHost({
    required this.controller,
    required this.canvas,
    required this.actions,
    required this.openSettings,
    required this.insert,
    required this.showNodeActions,
  });

  /// The collaborative document, its selection ([EditorController.selectNode]) and its undo history.
  final EditorController controller;

  /// The canvas's view state: the run shown on the nodes ([CanvasController.nodeRun]) and the selection.
  final CanvasController canvas;

  /// The editor's operations on the document (delete, duplicate, run a step, `addNodeAt`, read-only state), as the
  /// canvas and its menus use them; made fresh for each call.
  final WorkflowActions Function() actions;

  /// Selects [nodeId] and opens its settings (the node panel), as the canvas's selection bar does.
  final void Function(String nodeId) openSettings;

  /// Opens the block picker (a bottom sheet on a phone) and inserts the chosen block at [at] (`InsertAfter`,
  /// `InsertBefore`, `InsertOnEdge`) as one undo step; the new node is selected. Completes when the picker closes.
  final Future<void> Function(InsertPoint at) insert;

  /// The node's action sheet (settings, run step, add next, connect, duplicate, delete...), as a long press on the
  /// canvas opens it.
  final void Function(String nodeId) showNodeActions;
}

/// Builds the Steps view for the phone editor.
typedef StepsViewBuilder = Widget Function(BuildContext context, StepsViewHost host);

/// The Steps view the phone editor shows: plug the real one in here (`(context, host) => WorkflowStepsView(...)`).
const StepsViewBuilder workflowStepsView = placeholderStepsView;

/// Until the Steps view exists: a short note pointing to the canvas.
Widget placeholderStepsView(BuildContext context, StepsViewHost host) => Center(
  key: const ValueKey('steps-view-placeholder'),
  child: Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        RemixIcon('list-unordered', size: 32, color: DifyColors.textQuaternary),
        DifyText(
          DifyI18n.tr('workflow', 'mobile.stepsComing'),
          DifyType.systemSmRegular,
          color: DifyColors.textTertiary,
          align: TextAlign.center,
          maxLines: 3,
        ),
      ],
    ),
  ),
);
