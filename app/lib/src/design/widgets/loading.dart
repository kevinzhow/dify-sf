/// Dify's Loading (web/app/components/base/loading), the chat's LoadingAnim (base/chat/chat/loading-anim) and the
/// spinning loader icon.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';

/// base/loading (`type="area"`): four squares fading in turn (2 s each, 0.5 s apart), centred; `role="status"`.
class DifyLoading extends StatefulWidget {
  const DifyLoading({super.key, this.app = false});

  /// `type="app"` (full height).
  final bool app;

  @override
  State<DifyLoading> createState() => _DifyLoadingState();
}

class _DifyLoadingState extends State<DifyLoading> with SingleTickerProviderStateMixin {
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

/// base/chat/chat/loading-anim (LoadingAnim): three dots flashing in turn (`dot-flashing`, 1 s alternate): `text` 4 px grey dots 7 px apart,
/// `avatar` 2 px blue dots 5 px apart.
class DifyLoadingAnim extends StatefulWidget {
  const DifyLoadingAnim({super.key, this.avatar = false});
  final bool avatar;

  @override
  State<DifyLoadingAnim> createState() => _DifyLoadingAnimState();
}

class _DifyLoadingAnimState extends State<DifyLoadingAnim> with SingleTickerProviderStateMixin {
  // One 2 s cycle covers `1s infinite alternate` with the dots' 0 / 0.5 / 1 s delays.
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// The keyframes (`0%` solid, `50%`–`100%` at 30 %) of a dot delayed by [delay] seconds, at cycle time [t].
  double _alpha(double t, double delay) {
    var x = (t * 2 - delay) % 2; // seconds into its own alternate cycle
    if (x > 1) x = 2 - x; // alternate direction
    return x < 0.5 ? 1 - 0.7 * (x / 0.5) : 0.3;
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.avatar ? 2.0 : 4.0, gap = widget.avatar ? 5.0 : 7.0;
    final color = widget.avatar ? DifyColors.primary600 : DifyColors.gray500;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => SizedBox(
        width: size + gap * 2,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (i, delay) in const [(0, 0.0), (1, 0.5), (2, 1.0)])
              Positioned(
                left: gap * i,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: _alpha(_c.value, delay)),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- spinner ------------------------------------------------------------------------------------------------------

/// `animate-spin motion-reduce:animate-none` on [child]: one linear turn a second; still when the platform asks for
/// reduced motion.
class DifySpinnerIcon extends StatefulWidget {
  const DifySpinnerIcon({super.key, required this.child});
  final Widget child;

  @override
  State<DifySpinnerIcon> createState() => _DifySpinnerIconState();
}

class _DifySpinnerIconState extends State<DifySpinnerIcon> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: widget.child);
}

/// The loader Dify spins everywhere (`i-ri-loader-2-line animate-spin`), [size] px in [color] (the icon's inherited
/// colour when null); decorative (no semantics).
class DifySpinner extends StatelessWidget {
  const DifySpinner({super.key, this.color, this.size = 12});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: DifySpinnerIcon(
      child: RemixIcon('loader-2-line', size: size, color: color),
    ),
  );
}
