/// The "Next step" section at the bottom of node panels (nodes/_base/components/next-step/*): the node's tile, the
/// connector lines and, per branch, the nodes it leads to with an add button.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import 'var_reference_picker.dart' show hasErrorHandleNode;
import 'var_reference_vars.dart' show SmallBlockIcon;

String _wf(String key) => DifyI18n.tr('workflow', key);

/// A node one step after the panel's node.
final class NextStepNode {
  const NextStepNode({required this.id, required this.type, required this.title});
  final String id, type, title;
}

/// A branch of the panel's node ([id] is its source handle) and the nodes connected to it.
final class NextStepBranch {
  const NextStepBranch({required this.id, this.name = '', this.nextNodes = const [], this.isFailBranch = false});
  final String id, name;
  final List<NextStepNode> nextNodes;
  final bool isFailBranch;
}

/// The branches NextStep lists for [node] (next-step/index.tsx): one per [targetBranches] entry (`_targetBranches`:
/// if-else cases, question-classifier classes, which are named "Class n"), or the [defaultHandle] branch plus, with a
/// fail-branch error strategy, "On Failure". Edges to nodes not in [nodes] are skipped.
List<NextStepBranch> nextStepBranches({
  required Node node,
  required Map<String, Node> nodes,
  required Iterable<Edge> edges,
  List<({String id, String name})> targetBranches = const [],
  String defaultHandle = 'source',
}) {
  final out = [
    for (final e in edges)
      if (e.source == node.id) e,
  ];
  List<NextStepNode> next(String handle) => [
    for (final e in out)
      if (e.sourceHandle == handle)
        if (nodes[e.target] case final n?) NextStepNode(id: n.id, type: n.type, title: n.title),
  ];
  if (targetBranches.isNotEmpty) {
    return [
      for (final (i, b) in targetBranches.indexed)
        NextStepBranch(
          id: b.id,
          name: node.type == 'question-classifier' ? '${_wf('nodes.questionClassifiers.class')} ${i + 1}' : b.name,
          nextNodes: next(b.id),
        ),
    ];
  }
  return [
    NextStepBranch(id: defaultHandle, nextNodes: next(defaultHandle)),
    if (jsStr(plainOf(node.config['error_strategy'])) == 'fail-branch' && hasErrorHandleNode(node.type))
      NextStepBranch(
        id: 'fail-branch',
        name: _wf('common.onFailure'),
        nextNodes: next('fail-branch'),
        isFailBranch: true,
      ),
  ];
}

/// What the section's buttons do. [onAdd] / [onChange] open the block selector at the pressed button ([anchor]):
/// to add a node after [sourceHandle], or to replace node [nodeId].
class NextStepActions {
  const NextStepActions({this.onSelectNode, this.onAdd, this.onChange, this.onDisconnect, this.onDelete});
  final ValueChanged<String>? onSelectNode;
  final void Function(BuildContext anchor, String sourceHandle)? onAdd;
  final void Function(BuildContext anchor, String nodeId, String sourceHandle)? onChange;
  final ValueChanged<String>? onDisconnect, onDelete;
}

/// NextStep: the node's 36 px tile, the connector lines, and a container per branch.
class NextStep extends StatelessWidget {
  const NextStep({
    super.key,
    required this.nodeType,
    required this.branches,
    this.actions = const NextStepActions(),
    this.readonly = false,
  });

  final String nodeType;
  final List<NextStepBranch> branches;
  final NextStepActions actions;
  final bool readonly;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: DifyColors.backgroundDefault,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
            boxShadow: DifyShadows.xs,
          ),
          child: Center(child: SmallBlockIcon(type: nodeType)),
        ),
        NextStepLine(counts: branches.isEmpty ? const [1] : [for (final b in branches) b.nextNodes.length + 1]),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              for (final b in branches) _BranchContainer(branch: b, actions: actions, readonly: readonly),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The connector (next-step/line.tsx): a 24 px wide drawing, a straight line to the first branch and a curve down to
/// each further one, ending on small ticks.
class NextStepLine extends StatelessWidget {
  const NextStepLine({super.key, required this.counts});

  /// Items per branch (its next nodes plus the add button).
  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final heights = [for (final n in counts) n * 36.0 + (n - 1) * 2 + 12 + 6];
    final tops = <double>[];
    var sum = 0.0;
    for (final h in heights) {
      tops.add(sum + h);
      sum += h;
    }
    final height = tops.last + (tops.length - 1) * 8;
    return CustomPaint(size: Size(24, height), painter: _LinePainter(tops));
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.list);
  final List<double> list;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = DifyColors.dividerSolid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final fill = Paint()..color = DifyColors.dividerSolidAlt;
    for (var i = 0; i < list.length; i++) {
      final space = (i > 0 ? list[i - 1] : 0.0) + i * 8 + 16;
      if (i == 0) {
        canvas.drawLine(const Offset(0, 18), const Offset(24, 18), stroke);
        canvas.drawRect(const Rect.fromLTWH(0, 16, 1, 4), fill);
      } else {
        canvas.drawPath(
          Path()
            ..moveTo(0, 18)
            ..quadraticBezierTo(12, 18, 12, 28)
            ..lineTo(12, space - 8)
            ..quadraticBezierTo(12, space + 2, 24, space + 2),
          stroke,
        );
      }
      canvas.drawRect(Rect.fromLTWH(23, space, 1, 4), fill);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.list.join(',') != list.join(',');
}

/// Container (next-step/container.tsx): `space-y-0.5 rounded-[10px] bg-background-section-burn p-0.5`; the fail
/// branch is on the warning hover colours.
class _BranchContainer extends StatelessWidget {
  const _BranchContainer({required this.branch, required this.actions, required this.readonly});
  final NextStepBranch branch;
  final NextStepActions actions;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    final b = branch;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: b.isFailBranch ? DifyColors.stateWarningHover : DifyColors.backgroundSectionBurn,
        borderRadius: BorderRadius.circular(10),
        border: b.isFailBranch ? Border.all(color: DifyColors.stateWarningHoverAlt, width: Css.hairline) : null,
      ),
      // `space-y-0.5`: 2 px above each child but the first; not above Add, whose wrapper (the block selector's,
      // `display: contents`) has no box to take the margin.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (b.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DifyText(
                b.name,
                DifyType.system2xsSemiboldUppercase,
                color: b.isFailBranch ? DifyColors.textWarning : DifyColors.textTertiary,
              ),
            ),
          for (final (i, n) in b.nextNodes.indexed)
            Padding(
              padding: EdgeInsets.only(top: i > 0 || b.name.isNotEmpty ? 2 : 0),
              child: NextStepItem(node: n, actions: actions, readonly: readonly),
            ),
          _AddButton(
            label: _wf(
              b.isFailBranch
                  ? 'common.addFailureBranch'
                  : b.nextNodes.isNotEmpty
                  ? 'common.addParallelNode'
                  : 'panel.selectNextStep',
            ),
            onPressed: readonly || actions.onAdd == null ? null : (anchor) => actions.onAdd!(anchor, b.id),
          ),
        ],
      ),
    );
  }
}

/// Item (next-step/item.tsx): `h-9 rounded-lg border-[0.5px] bg-background-default px-2 shadow-xs` with the block
/// icon and title; hovered (and not read-only) it shows "Jump to this node" and the operator menu.
class NextStepItem extends StatefulWidget {
  const NextStepItem({super.key, required this.node, required this.actions, this.readonly = false});
  final NextStepNode node;
  final NextStepActions actions;
  final bool readonly;

  @override
  State<NextStepItem> createState() => _NextStepItemState();
}

class _NextStepItemState extends State<NextStepItem> {
  bool _hovered = false, _menu = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final show = !w.readonly && (_hovered || _menu);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _hovered ? DifyColors.backgroundDefaultHover : DifyColors.backgroundDefault,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
          boxShadow: DifyShadows.xs,
        ),
        child: Row(
          children: [
            SmallBlockIcon(type: w.node.type),
            const SizedBox(width: 6),
            Expanded(child: DifyText(w.node.title, DifyType.systemXsMedium, color: DifyColors.textSecondary)),
            if (show) ...[
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: DifyButton(
                  size: DifyButtonSize.small,
                  onPressed: () => w.actions.onSelectNode?.call(w.node.id),
                  child: Text(_wf('common.jumpToNode')),
                ),
              ),
            ],
            if (!w.readonly)
              Visibility(
                visible: show,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: false,
                child: NextStepOperator(
                  nodeId: w.node.id,
                  sourceHandle: 'source',
                  actions: w.actions,
                  onOpenChange: (open) => setState(() => _menu = open),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Operator (next-step/operator.tsx): the "…" button's menu with Change, Disconnect and Delete.
class NextStepOperator extends StatelessWidget {
  const NextStepOperator({
    super.key,
    required this.nodeId,
    required this.sourceHandle,
    required this.actions,
    this.onOpenChange,
  });
  final String nodeId, sourceHandle;
  final NextStepActions actions;
  final ValueChanged<bool>? onOpenChange;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    alignOffset: -4,
    onOpenChange: onOpenChange,
    builder: (context, c) => DifyIconButton(
      label: _wf('common.moreActions'),
      variant: DifyButtonVariant.secondary,
      onPressed: c.toggle,
      icon: const RemixIcon('more-fill', size: 16),
    ),
    children: [
      Builder(
        builder: (anchor) => DifyMenuItem(
          onSelect: () => actions.onChange?.call(anchor, nodeId, sourceHandle),
          child: Text(_wf('panel.change')),
        ),
      ),
      DifyMenuItem(onSelect: () => actions.onDisconnect?.call(nodeId), child: Text(_wf('common.disconnect'))),
      const SizedBox(height: 8),
      DifyMenuItem(
        onSelect: () => actions.onDelete?.call(nodeId),
        child: Text(DifyI18n.tr('common', 'operation.delete')),
      ),
    ],
  );
}

/// Add (next-step/add.tsx): a dashed 36 px button with a small "+" tile and the upper-case [label].
class _AddButton extends StatefulWidget {
  const _AddButton({required this.label, this.onPressed});
  final String label;
  final void Function(BuildContext anchor)? onPressed;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.onPressed != null,
    child: MouseRegion(
      cursor: widget.onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed == null ? null : () => widget.onPressed!(context),
        child: Container(
          height: 36,
          // px-2 inside the 1 px dashed border.
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: _hovered && widget.onPressed != null ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          foregroundDecoration: const CssDashedBorder(color: DifyColors.dividerRegular, radius: DifyRadius.lg),
          child: Row(
            spacing: 6,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: DifyColors.backgroundDefaultDimmed,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Center(child: RemixIcon('add-line', size: 12, color: DifyColors.textPlaceholder)),
              ),
              Flexible(
                child: Text(
                  widget.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 16 / 12,
                    fontWeight: FontWeight.w600,
                    color: DifyColors.textPlaceholder,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
