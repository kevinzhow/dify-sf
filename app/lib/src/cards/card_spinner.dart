import 'package:flutter/widgets.dart';

import '../canvas/node_card.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart' show DifySpinner;

/// `i-ri-loader-2-line size-3.5 animate-spin` ([DifySpinner]) in its own repaint boundary (only the icon repaints).
/// Where the renderer draws loaders itself ([CanvasSpinners]) its place is left empty.
class CardSpinner extends StatelessWidget {
  const CardSpinner({super.key, this._color, this.size = 14});
  final Color? _color;
  Color get color => _color ?? DifyColors.textAccent;
  final double size;

  @override
  Widget build(BuildContext context) => CanvasSpinners.drawnByCanvasOf(context)
      ? SizedBox.square(dimension: size)
      : RepaintBoundary(
          child: DifySpinner(color: color, size: size),
        );
}
