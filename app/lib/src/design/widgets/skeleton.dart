/// Dify's Skeleton (web/app/components/base/skeleton/index.tsx: SkeletonContainer, SkeletonRow, SkeletonRectangle,
/// SkeletonPoint) and Tailwind's `animate-pulse` ([DifyPulse]).
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'text.dart';

/// SkeletonContainer: `flex flex-col gap-1` (children stretch across).
class DifySkeletonContainer extends StatelessWidget {
  const DifySkeletonContainer({super.key, required this.children, this.gap = 4});
  final List<Widget> children;

  /// `gap-1` unless the caller's class overrides it.
  final double gap;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: gap,
    children: children,
  );
}

/// SkeletonRow: `flex items-center gap-2`.
class DifySkeletonRow extends StatelessWidget {
  const DifySkeletonRow({super.key, required this.children, this.gap = 8});
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(spacing: gap, children: children);
}

/// SkeletonRectangle: `my-1 h-2 rounded-xs bg-text-quaternary opacity-20`. Without [width] or [widthFactor] it takes
/// the width it is given (a block in a column); [widthFactor] is a fractional `w-*` of that width, [width] a fixed
/// one (start aligned). [height], [radius], [margin] and [opacity] stand for the caller's overriding classes; [pulse]
/// adds `animate-pulse`.
class DifySkeletonRectangle extends StatelessWidget {
  const DifySkeletonRectangle({
    super.key,
    this.width,
    this.widthFactor,
    this.height = 8,
    this.radius = DifyRadius.xs,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
    this.opacity = 0.2,
    this.pulse = false,
  });

  final double? width, widthFactor;
  final double height, radius, opacity;
  final EdgeInsetsGeometry margin;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final color = DifyColors.textQuaternary;
    Widget box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: color.a * opacity),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    if (pulse) box = DifyPulse(child: box);
    if (widthFactor != null) {
      box = FractionallySizedBox(alignment: AlignmentDirectional.centerStart, widthFactor: widthFactor, child: box);
    } else if (width != null) {
      box = Align(alignment: AlignmentDirectional.centerStart, heightFactor: 1, child: box);
    }
    return margin == EdgeInsets.zero ? box : Padding(padding: margin, child: box);
  }
}

/// SkeletonPoint: a `·` in `text-xs font-medium text-text-quaternary`.
class DifySkeletonPoint extends StatelessWidget {
  const DifySkeletonPoint({super.key});

  @override
  Widget build(BuildContext context) =>
      DifyTextLine('·', style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textQuaternary));
}

/// Tailwind's `animate-pulse`: opacity 1 -> 0.5 -> 1 every 2 s (`cubic-bezier(0.4, 0, 0.6, 1)`); still when the
/// platform asks for reduced motion.
class DifyPulse extends StatefulWidget {
  const DifyPulse({super.key, required this.child});
  final Widget child;

  @override
  State<DifyPulse> createState() => _DifyPulseState();
}

class _DifyPulseState extends State<DifyPulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 2));
  late final _opacity = _c.drive(
    TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.5), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.5, end: 1.0), weight: 1),
    ]).chain(CurveTween(curve: const Cubic(0.4, 0, 0.6, 1))),
  );

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
  Widget build(BuildContext context) => FadeTransition(opacity: _opacity, child: widget.child);
}
