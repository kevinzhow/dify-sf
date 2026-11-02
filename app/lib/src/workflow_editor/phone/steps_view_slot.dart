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
import '../steps/workflow_steps_view.dart';

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
    this.registerAddAtEnd,
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

  /// The view hands the chrome its "add at the end of the flow" (null when it goes away): the toolbar's Add with no
  /// step selected uses it while the Steps view shows.
  final void Function(Future<bool> Function()? addAtEnd)? registerAddAtEnd;
}

/// Builds the Steps view for the phone editor.
typedef StepsViewBuilder = Widget Function(BuildContext context, StepsViewHost host);

/// The Steps view the phone editor shows.
const StepsViewBuilder workflowStepsView = _stepsView;

Widget _stepsView(BuildContext context, StepsViewHost host) => _HostedStepsView(host: host);

/// [WorkflowStepsView] in the phone chrome: the editor's read-only state and store from its actions, settings
/// through the chrome, and its "add at the end" registered with the chrome while it shows.
class _HostedStepsView extends StatefulWidget {
  const _HostedStepsView({required this.host});
  final StepsViewHost host;
  @override
  State<_HostedStepsView> createState() => _HostedStepsViewState();
}

class _HostedStepsViewState extends State<_HostedStepsView> {
  final _view = GlobalKey<WorkflowStepsViewState>();

  @override
  void initState() {
    super.initState();
    widget.host.registerAddAtEnd?.call(() async => _view.currentState?.addAtEnd() ?? Future.value(false));
  }

  @override
  void dispose() {
    widget.host.registerAddAtEnd?.call(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actions = widget.host.actions();
    return WorkflowStepsView(
      key: _view,
      controller: widget.host.controller,
      canvas: widget.host.canvas,
      options: actions.options,
      store: actions.store,
      onOpenNode: widget.host.openSettings,
    );
  }
}

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
          DifyI18n.tr('phone-editor', 'stepsComing'),
          DifyType.systemSmRegular,
          color: DifyColors.textTertiary,
          align: TextAlign.center,
          maxLines: 3,
        ),
      ],
    ),
  ),
);
