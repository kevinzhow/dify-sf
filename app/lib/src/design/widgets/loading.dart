/// Dify's Loading (web/app/components/base/loading) and the spinning loader icon.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';

/// base/loading (`type="area"`): four squares fading in turn (2 s each, 0.5 s apart), centred; `role="status"`.
class DifyAreaLoading extends StatefulWidget {
  const DifyAreaLoading({super.key, this.app = false});

  /// `type="app"` (full height).
  final bool app;

  @override
  State<DifyAreaLoading> createState() => _DifyAreaLoadingState();
}

class _DifyAreaLoadingState extends State<DifyAreaLoading> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  final _start = DateTime.now();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: DifyI18n.tr('appApi', 'loading'),
    child: Center(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) =>
            CustomPaint(size: const Size.square(16), painter: _LoadingPainter(DateTime.now().difference(_start))),
      ),
    ),
  );
}

class _LoadingPainter extends CustomPainter {
  _LoadingPainter(this.elapsed);
  final Duration elapsed;

  // (left, top, static opacity, delay) of each path, in document order.
  static const _squares = [(9.0, 0.0, 1.0, 0.0), (9.0, 9.0, 0.5, 0.5), (0.0, 9.0, 0.1, 1.0), (0.0, 0.0, 0.2, 1.5)];

  // @keyframes custom: 0 -> 0, 25% -> 0.1, 50% -> 0.2, 75% -> 0.5, 100% -> 1.
  static double _keyframe(double t) {
    const stops = [0.0, 0.1, 0.2, 0.5, 1.0];
    final x = t * 4, i = math.min(x.floor(), 3);
    return stops[i] + (stops[i + 1] - stops[i]) * (x - i);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = elapsed.inMicroseconds / 1e6;
    for (final (x, y, still, delay) in _squares) {
      final opacity = s < delay ? still : _keyframe(((s - delay) % 2) / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, 7, 7), const Radius.circular(1)),
        Paint()..color = const Color(0xFF1C64F2).withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_LoadingPainter old) => old.elapsed != elapsed;
}

// ---- locale menu --------------------------------------------------------------------------------------------------

/// Spins its child (`animate-spin`, 1 s per turn).
class DifySpinnerIcon extends StatefulWidget {
  const DifySpinnerIcon({super.key, required this.child});
  final Widget child;

  @override
  State<DifySpinnerIcon> createState() => _DifySpinnerIconState();
}

class _DifySpinnerIconState extends State<DifySpinnerIcon> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: widget.child);
}
