import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../card_kit.dart';
import '../node_body.dart';

/// Iteration and Loop (nodes/iteration/node.tsx, nodes/loop/node.tsx): the card is the area that holds the child
/// nodes, sized by the node's `width`/`height` (kept in `_dify_node`). The body (`grow px-1 pb-1`) is a rounded
/// `bg-workflow-canvas-workflow-bg` area with its own React Flow dot background.
class ContainerBody extends NodeBody {
  const ContainerBody();

  /// Without a stored size the DOM decides in Dify: min-w-60 and a min-h-22.5 area under the header.
  static const _defaultFrame = Size(1 + 4 + 240 + 4 + 1 + 2, 1 + 44 + 90 + 4 + 4 + 1 + 2);

  /// React Flow's node element (the card and the 1 px frame around it).
  static Size frame(BodyContext ctx) {
    double? num(Value? v) => switch (v) {
      VInt(:final value) => value.toDouble(),
      VDouble(:final value) => value,
      _ => null,
    };
    final extra = ctx['_dify_node'];
    if (extra is! VMap) return _defaultFrame;
    return Size(
      num(extra.entries['width']) ?? _defaultFrame.width,
      num(extra.entries['height']) ?? _defaultFrame.height,
    );
  }

  @override
  CardChrome get chrome => CardChrome.container;

  @override
  Size cardSize(BodyContext ctx) {
    final f = frame(ctx);
    return Size(f.width - 2, f.height - 2);
  }

  // Card = border 1 + header 44 + body + card pb-1 + border 1.
  @override
  double height(BodyContext ctx) => cardSize(ctx).height - 50;

  @override
  Widget build(BuildContext context, BodyContext ctx) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
    child: SizedBox(
      height: height(ctx) - 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        child: CustomPaint(painter: _NestedDots(ctx.viewOrigin)),
      ),
    ),
  );
}

/// React Flow's `<Background gap={14 / zoom} size={2 / zoom}>` inside the container: in the node's own units the
/// pattern is 14 apart with 2 wide dots, and its offset is the viewport's x, y (screen pixels) modulo 14, used as
/// node units (Background reads `transform[0] % scaledGap`).
class _NestedDots extends CustomPainter {
  _NestedDots(this.origin);
  final Offset origin;
  static const gap = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = DifyColors.workflowCanvasWorkflowBg);
    final dot = Paint()..color = DifyColors.workflowCanvasWorkflowDotColor;
    // JS `%` keeps the dividend's sign, like Dart's remainder.
    final x0 = origin.dx.remainder(gap), y0 = origin.dy.remainder(gap);
    for (var y = y0 - gap; y < size.height + gap; y += gap) {
      for (var x = x0 - gap; x < size.width + gap; x += gap) {
        canvas.drawCircle(Offset(x, y), 1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_NestedDots old) => old.origin != origin;
}
