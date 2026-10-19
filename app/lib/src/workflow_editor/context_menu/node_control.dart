import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/workflow_canvas.dart' show CanvasDefaults;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'menus.dart';
import 'node_meta.dart';
import 'workflow_actions.dart';

/// node-actions-menu/index.tsx NodeActionsDropdown: the `…` button (`size-6`, here [size]) opening the node
/// actions at `bottom-end`, 240 px wide.
class NodeActionsDropdown extends StatefulWidget {
  const NodeActionsDropdown({
    super.key,
    required this.actions,
    required this.node,
    this.onOpenChange,
    this.showHelpLink = true,
    this.size = 24,
  });

  final WorkflowActions actions;
  final Node node;
  final ValueChanged<bool>? onOpenChange;
  final bool showHelpLink;
  final double size;

  @override
  State<NodeActionsDropdown> createState() => _NodeActionsDropdownState();
}

class _NodeActionsDropdownState extends State<NodeActionsDropdown> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    width: nodeMenuWidth,
    onOpenChange: (open) {
      setState(() => _open = open);
      widget.onOpenChange?.call(open);
    },
    builder: (context, controller) => DifyPressable(
      semanticLabel: DifyI18n.tr('common', 'operation.more'),
      onPressed: controller.toggle,
      builder: (context, hovered, focused) => Container(
        width: widget.size,
        height: widget.size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered || _open ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: focused ? Border.all(color: DifyColors.componentsInputBorderHover) : null,
        ),
        child: RemixIcon('more-fill', size: 16, color: DifyColors.textTertiary),
      ),
    ),
    children: nodeActionsMenuItems(widget.actions, widget.node, showHelpLink: widget.showHelpLink),
  );
}

/// nodes/_base/components/node-control.tsx, the bar itself: "Run this step" (or "Stop run" while the node is
/// single-running) and the node actions `…`, in `h-6 rounded-lg border-[0.5px] border-components-actionbar-border
/// bg-components-actionbar-bg px-0.5 text-text-tertiary shadow-md backdrop-blur-[5px]`. Placing it (`absolute -top-7
/// right-0 h-7 pb-1` on the card, shown on hover and while selected) is [WorkflowContextMenus]'s.
class NodeControl extends StatelessWidget {
  const NodeControl({super.key, required this.actions, required this.node, this.onMenuOpenChange});

  final WorkflowActions actions;
  final Node node;

  /// The `…` menu opened or closed (the bar stays while it is open, `has-data-popup-open:visible`).
  final ValueChanged<bool>? onMenuOpenChange;

  @override
  Widget build(BuildContext context) {
    final id = node.id;
    final running = actions.isSingleRunning(id);
    final canRun =
        actions.options.canRun &&
        !actions.nodesReadOnly &&
        canRunBySingle(node.type, isChildNode: parentIdOf(node) != null);
    final runLabel = DifyI18n.tr('workflow', running ? 'debug.variableInspect.trigger.stop' : 'panel.runThisStep');
    // Visual tests: where the bar is (`NODE_CONTROL left,top,width,height` on screen) while it shows the run button.
    // Dify 1.17.1 never shows that button (its `!nodesReadOnly` tests the object useNodesReadOnly() returns, never
    // false); we keep it on purpose, and tool/visual/compare.py leaves the part of the bar Dify lacks out of the
    // measure.
    if (CanvasDefaults.reportRect && canRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final box = context.mounted ? context.findRenderObject() as RenderBox? : null;
        if (box == null || !box.hasSize) return;
        final r = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
        debugPrint('NODE_CONTROL ${r.left},${r.top},${r.width},${r.height}');
      });
    }
    return DifyBlurredBox(
      blur: 5,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      decoration: BoxDecoration(
        color: DifyColors.componentsActionbarBg,
        border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        boxShadow: DifyShadows.md,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height: 24 - 2 * Css.hairline,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canRun)
              DifyPressable(
                semanticLabel: runLabel,
                onPressed: () => actions.runStep(id),
                builder: (context, hovered, focused) => Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: running && hovered ? DifyColors.stateBaseHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                  ),
                  child: running
                      ? DifyIcon('vender/line/mediaAndDevices/stop', size: 12, color: DifyColors.textTertiary)
                      : DifyTooltip(
                          content: Text(runLabel),
                          child: RemixIcon('play-large-line', size: 12, color: DifyColors.textTertiary),
                        ),
                ),
              ),
            NodeActionsDropdown(actions: actions, node: node, size: 20, onOpenChange: onMenuOpenChange),
          ],
        ),
      ),
    );
  }
}
