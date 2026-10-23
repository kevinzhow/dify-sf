import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import '../css_metrics.dart';
import 'text.dart';

/// A box with `backdrop-blur-[blur px]` behind it: the backdrop is blurred inside [borderRadius], the decoration
/// (whose shadows fall outside the clip) is painted over it.
class DifyBlurredBox extends StatelessWidget {
  const DifyBlurredBox({
    super.key,
    required this.blur,
    required this.borderRadius,
    required this.child,
    this.decoration,
    this.padding,
  });

  /// CSS `blur()` length: the Gaussian's standard deviation.
  final double blur;
  final BorderRadius borderRadius;
  final Decoration? decoration;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Like Container (and CSS's border-box), the border insets the content.
    final inset = (decoration?.padding ?? EdgeInsets.zero).add(padding ?? EdgeInsets.zero);
    Widget box = inset == EdgeInsets.zero ? child : Padding(padding: inset, child: child);
    if (decoration != null) box = DecoratedBox(decoration: decoration!, child: box);
    if (blur <= 0) return box;
    // The blur does not change the box's size: the content gets the constraints as they are (a `w-full` button
    // stays full width).
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        box,
      ],
    );
  }
}

/// web/app/styles/glass-surface.css `dify-blue-glass-surface`, used by the
/// current primary navigation destination. Gradients/rings paint inside the box
/// and never alter label, hit-test or focus coordinates.
class DifyBlueGlassSurface extends StatelessWidget {
  const DifyBlueGlassSurface({super.key, required this.child, this.radius = 10});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => DifyBlurredBox(
    blur: 5,
    borderRadius: BorderRadius.circular(radius),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: CssLinearGradient(
        angle: 91.46,
        colors: [
          DifyColors.componentsMainNavGlassSurfaceFirst,
          DifyColors.componentsMainNavGlassSurfaceMiddle1,
          DifyColors.componentsMainNavGlassSurfaceMiddle2,
          // The source last stop is 101.09%; interpolate at the box edge instead
          // of clamping that stop to 100% (Flutter's shader stop domain).
          Color.lerp(
            DifyColors.componentsMainNavGlassSurfaceMiddle2,
            DifyColors.componentsMainNavGlassSurfaceEnd,
            (1 - .5875) / (1.0109 - .5875),
          )!,
        ],
        stops: const [0, .1798, .5875, 1],
      ),
      boxShadow: [
        BoxShadow(
          offset: const Offset(0, 4),
          blurRadius: Css.shadowBlur(8),
          color: DifyColors.componentsMainNavGlassShadowReflectionGlow,
        ),
        BoxShadow(
          offset: const Offset(0, 10),
          blurRadius: Css.shadowBlur(12),
          spreadRadius: -4,
          color: DifyColors.shadowShadow4,
        ),
        BoxShadow(
          offset: const Offset(0, 3),
          blurRadius: Css.shadowBlur(5),
          spreadRadius: -2,
          color: DifyColors.shadowShadow1,
        ),
        BoxShadow(
          offset: const Offset(0, 8),
          blurRadius: Css.shadowBlur(16),
          spreadRadius: -4,
          color: DifyColors.componentsMainNavGlassShadowReflection,
        ),
      ],
    ),
    child: CustomPaint(
      foregroundPainter: _BlueGlassRings(radius, DifyColors.isDark),
      child: DefaultTextStyle.merge(
        style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.saasDifyBlueInverted).copyWith(
          shadows: [Shadow(blurRadius: 8, color: DifyColors.componentsMainNavGlassTextGlow)],
        ),
        child: child,
      ),
    ),
  );
}

class _BlueGlassRings extends CustomPainter {
  const _BlueGlassRings(this.radius, this.dark);
  final double radius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(shape)
      ..addRRect(shape.deflate(1));
    for (final gradient in [
      CssLinearGradient(
        angle: 0,
        colors: [
          DifyColors.componentsMainNavGlassEdgeReflectionFirst,
          DifyColors.componentsMainNavGlassEdgeReflectionMiddle,
          DifyColors.componentsMainNavGlassEdgeReflectionEnd,
        ],
        stops: const [0, .5, 1],
      ),
      CssLinearGradient(
        angle: 180,
        colors: [
          DifyColors.componentsMainNavGlassEdgeHighlightFirst,
          DifyColors.componentsMainNavGlassEdgeHighlightMiddle,
          DifyColors.componentsMainNavGlassEdgeHighlightEnd,
        ],
        stops: const [0, .18, 1],
      ),
    ]) {
      canvas.drawPath(ring, Paint()..shader = gradient.createShader(rect));
    }
    canvas.save();
    canvas.clipPath(ring);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(16))
      ..addRRect(shape);
    canvas.drawPath(
      outside,
      Paint()
        ..color = DifyColors.componentsMainNavGlassInnerGlow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BlueGlassRings old) => old.radius != radius || old.dark != dark;
}
