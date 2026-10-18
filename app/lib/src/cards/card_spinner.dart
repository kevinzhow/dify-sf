import 'package:flutter/widgets.dart';

import '../canvas/node_card.dart';
import '../canvas/run_view.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';

/// `i-ri-loader-2-line size-3.5 animate-spin`: the 14 px loader turning once a second, in its own repaint boundary
/// (only the icon repaints). Where the renderer draws loaders itself ([CanvasSpinners]) its place is left empty.
class CardSpinner extends StatefulWidget {
  const CardSpinner({super.key, this.color = DifyColors.textAccent, this.size = 14});
  final Color color;
  final double size;

  @override
  State<CardSpinner> createState() => _CardSpinnerState();
}

class _CardSpinnerState extends State<CardSpinner> with TickerProviderStateMixin {
  AnimationController? _turns;

  @override
  Widget build(BuildContext context) {
    final box = SizedBox.square(dimension: widget.size);
    if (CanvasSpinners.drawnByCanvasOf(context)) {
      _turns?.dispose();
      _turns = null;
      return box;
    }
    final turns = _turns ??= AnimationController(vsync: this, duration: spinPeriod)..repeat();
    return RepaintBoundary(
      child: RotationTransition(
        turns: turns,
        child: RemixIcon('loader-2-line', size: widget.size, color: widget.color),
      ),
    );
  }

  @override
  void dispose() {
    _turns?.dispose();
    super.dispose();
  }
}
