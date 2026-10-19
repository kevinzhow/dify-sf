/// hooks/use-helpline.ts and help-line/index.tsx: while a node is dragged, the nodes whose top-left lies within 5 px of
/// its own (horizontally or vertically) are found, a line is drawn along them, and the node snaps onto the first of
/// them (use-nodes-interactions.ts handleNodeDrag). Entry nodes (Start, triggers) align by their card, below the
/// 21 px status row.
library;

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../cards/node_helpers.dart' show isTriggerNode;
import '../../design/dify_tokens.g.dart';
import '../store/store.dart';

/// A node as the helplines see it: React Flow's `position`, `width`, `height`, and whether it is inside an
/// iteration or loop (`data.isInIteration` / `data.isInLoop`).
typedef HelplineNode = ({String id, String type, double x, double y, double width, double height, bool inContainer});

/// `ENTRY_NODE_WRAPPER_OFFSET`: the EntryNodeContainer's status row above an entry node's card.
const entryNodeWrapperOffset = Offset(0, 21);

/// `ALIGN_THRESHOLD`.
const _alignThreshold = 5;

bool _isEntryNode(HelplineNode n) => isTriggerNode(n.type) || n.type == 'start';

/// `getNodeAlignPosition`: an entry node aligns by its card.
Offset _alignPosition(HelplineNode n) => _isEntryNode(n) ? Offset(n.x, n.y) + entryNodeWrapperOffset : Offset(n.x, n.y);

double _width(HelplineNode n) => _isEntryNode(n) ? n.width - entryNodeWrapperOffset.dx : n.width;
double _height(HelplineNode n) => _isEntryNode(n) ? n.height - entryNodeWrapperOffset.dy : n.height;

/// `getAlignedNodes`: the other top-level nodes within the threshold on [axis] (x: same column, y: same row), left to
/// right.
List<HelplineNode> _alignedNodes(List<HelplineNode> nodes, HelplineNode node, Offset at, Axis axis) {
  double of(Offset p) => axis == Axis.horizontal ? p.dx : p.dy;
  return [
    for (final c in nodes)
      if (c.id != node.id && !c.inContainer)
        if ((of(_alignPosition(c)).ceil() - of(at).ceil()).abs() < _alignThreshold) c,
  ]..sort((a, b) => _alignPosition(a).dx.compareTo(_alignPosition(b).dx));
}

HelpLineHorizontalPosition? _horizontalLine(List<HelplineNode> aligned, HelplineNode node, Offset at) {
  if (aligned.isEmpty) return null;
  final first = aligned.first, last = aligned.last;
  final firstPos = _alignPosition(first), lastPos = _alignPosition(last);
  var top = firstPos.dy, left = firstPos.dx, width = lastPos.dx + _width(last) - firstPos.dx;
  if (at.dx < firstPos.dx) {
    left = at.dx;
    width = firstPos.dx + _width(first) - at.dx;
  }
  if (at.dx > lastPos.dx) width = at.dx + _width(node) - firstPos.dx;
  return (top: top, left: left, width: width);
}

HelpLineVerticalPosition? _verticalLine(List<HelplineNode> aligned, HelplineNode node, Offset at) {
  if (aligned.isEmpty) return null;
  final first = aligned.first, last = aligned.last;
  final firstPos = _alignPosition(first), lastPos = _alignPosition(last);
  var top = firstPos.dy, left = firstPos.dx, height = lastPos.dy + _height(last) - firstPos.dy;
  if (at.dy < firstPos.dy) {
    top = at.dy;
    height = firstPos.dy + _height(first) - at.dy;
  }
  if (at.dy > lastPos.dy) height = at.dy + _height(node) - firstPos.dy;
  return (top: top, left: left, height: height);
}

typedef HelplineNodes = ({
  List<HelplineNode> showHorizontalHelpLineNodes,
  List<HelplineNode> showVerticalHelpLineNodes,
});

/// `useHelpline().handleSetHelpline`: the nodes [node] aligns with among [nodes], with the lines along them set in
/// [store]. A node inside a container aligns with nothing (and the store is left as it is).
HelplineNodes handleSetHelpline(WorkflowStore store, List<HelplineNode> nodes, HelplineNode node) {
  if (node.inContainer) return (showHorizontalHelpLineNodes: const [], showVerticalHelpLineNodes: const []);
  final at = _alignPosition(node);
  final horizontal = _alignedNodes(nodes, node, at, Axis.vertical);
  final vertical = _alignedNodes(nodes, node, at, Axis.horizontal);
  store
    ..setHelpLineHorizontal(_horizontalLine(horizontal, node, at))
    ..setHelpLineVertical(_verticalLine(vertical, node, at));
  return (showHorizontalHelpLineNodes: horizontal, showVerticalHelpLineNodes: vertical);
}

/// handleNodeDrag's position for [node] after [handleSetHelpline]: on the first aligned node's column and row (entry
/// nodes' offsets accounted for), else where it was dragged.
Offset snapToHelplines(HelplineNode node, HelplineNodes aligned) {
  var x = node.x, y = node.y;
  final offset = _isEntryNode(node) ? entryNodeWrapperOffset : Offset.zero;
  if (aligned.showVerticalHelpLineNodes.firstOrNull case final t?) {
    x = t.x + (_isEntryNode(t) ? entryNodeWrapperOffset.dx : 0) - offset.dx;
  }
  if (aligned.showHorizontalHelpLineNodes.firstOrNull case final t?) {
    y = t.y + (_isEntryNode(t) ? entryNodeWrapperOffset.dy : 0) - offset.dy;
  }
  return Offset(x, y);
}

/// The canvas's nodes as [HelplineNode]s (React Flow's node box: the drawn node and its 1 px border on each side).
List<HelplineNode> helplineNodesOf(CanvasController canvas) => [
  for (final n in canvas.graph?.nodes ?? const <Never>[])
    (
      id: n.id,
      type: n.type,
      x: n.x,
      y: n.y,
      width: n.layout.visual.width + 2,
      height: n.layout.visual.height + 2,
      inContainer: n.parentId != null,
    ),
];

/// help-line/index.tsx: the store's lines over the canvas, 1 px in `primary-300`.
class HelpLine extends StatelessWidget {
  const HelpLine({super.key, required this.canvas});

  final CanvasController canvas;

  /// `bg-primary-300`.
  static Color get color => DifyColors.primary300;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([store.helpLineHorizontal, store.helpLineVertical, canvas.view]),
        builder: (context, _) {
          final h = store.helpLineHorizontal.value, v = store.helpLineVertical.value;
          if (h == null && v == null) return const SizedBox.shrink();
          final view = canvas.view, zoom = view.scale;
          return Stack(
            children: [
              if (h != null)
                Positioned(
                  key: const ValueKey('help-line-horizontal'),
                  left: view.toScreen(Offset(h.left, h.top)).dx,
                  top: view.toScreen(Offset(h.left, h.top)).dy,
                  width: h.width * zoom,
                  height: 1,
                  child: ColoredBox(color: color),
                ),
              if (v != null)
                Positioned(
                  key: const ValueKey('help-line-vertical'),
                  left: view.toScreen(Offset(v.left, v.top)).dx,
                  top: view.toScreen(Offset(v.left, v.top)).dy,
                  width: 1,
                  height: v.height * zoom,
                  child: ColoredBox(color: color),
                ),
            ],
          );
        },
      ),
    );
  }
}
