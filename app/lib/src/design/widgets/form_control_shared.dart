/// Shared by dify-ui's form controls (packages/dify-ui/src/form-control-shared.ts): pointer, focus and keyboard
/// activation for controls that are not buttons, and the focus-visible ring.
library;

import 'package:flutter/material.dart';

import '../dify_tokens.g.dart';

/// Pointer, focus and keyboard activation for controls that are not buttons (switch, segmented item).
class DifyControl extends StatefulWidget {
  const DifyControl({super.key, required this.builder, this.onActivate, this.disabled = false, this.focusNode});
  final FocusNode? focusNode;
  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final VoidCallback? onActivate;
  final bool disabled;

  @override
  State<DifyControl> createState() => _DifyControlState();
}

class _DifyControlState extends State<DifyControl> {
  bool _hovered = false, _focused = false;

  void _activate() {
    if (!widget.disabled) widget.onActivate?.call();
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    focusNode: widget.focusNode,
    enabled: !widget.disabled,
    mouseCursor: widget.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
    actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate())},
    onShowFocusHighlight: (v) => setState(() => _focused = v),
    onShowHoverHighlight: (v) => setState(() => _hovered = v),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: widget.disabled ? null : _activate,
      child: widget.builder(context, _hovered && !widget.disabled, _focused),
    ),
  );
}

/// `focus-visible:ring-2 focus-visible:ring-state-accent-solid` ([width] 1: `ring-1`); null when not [focused].
List<BoxShadow>? difyFocusRing(bool focused, {double width = 2}) =>
    focused ? [difyFocusRingShadow(width: width)] : null;

/// Marker for DifyFocusDecoration, including lists with ordinary shadows.
/// Never pass this marker to a plain BoxDecoration: CSS rings must not fill the interior.
BoxShadow difyFocusRingShadow({double width = 2}) => _DifyFocusShadow(DifyColors.stateAccentSolid, width);

/// A CSS focus ring is outside the border box. Flutter's solid BoxShadow also
/// paints underneath a translucent background, turning a focused control blue.
/// This decoration paints ordinary shadows/background first, then an outside-only
/// stroke; it contributes no padding and preserves that behavior during lerps.
class DifyFocusDecoration extends BoxDecoration {
  const DifyFocusDecoration({
    super.color,
    super.image,
    super.border,
    super.borderRadius,
    super.boxShadow,
    super.gradient,
    super.backgroundBlendMode,
    super.shape,
  });

  static _DifyFocusShadow? _ring(BoxDecoration d) => d.boxShadow?.whereType<_DifyFocusShadow>().firstOrNull;
  static BoxDecoration _normal(BoxDecoration d) => BoxDecoration(
    color: d.color,
    image: d.image,
    border: d.border,
    borderRadius: d.borderRadius,
    gradient: d.gradient,
    backgroundBlendMode: d.backgroundBlendMode,
    shape: d.shape,
    boxShadow: d.boxShadow?.where((s) => s is! _DifyFocusShadow).toList(),
  );

  static DifyFocusDecoration _between(BoxDecoration a, BoxDecoration b, double t) {
    final d = BoxDecoration.lerp(_normal(a), _normal(b), t)!;
    final x = _ring(a), y = _ring(b);
    final ring = x == null && y == null
        ? null
        : _DifyFocusShadow(
            Color.lerp(x?.color ?? y!.color.withValues(alpha: 0), y?.color ?? x!.color.withValues(alpha: 0), t)!,
            (x?.spreadRadius ?? 0) * (1 - t) + (y?.spreadRadius ?? 0) * t,
          );
    return DifyFocusDecoration(
      color: d.color,
      image: d.image,
      border: d.border,
      borderRadius: d.borderRadius,
      gradient: d.gradient,
      backgroundBlendMode: d.backgroundBlendMode,
      shape: d.shape,
      boxShadow: [...?d.boxShadow, ?ring],
    );
  }

  @override
  BoxDecoration? lerpFrom(Decoration? a, double t) => a is BoxDecoration
      ? _between(a, this, t)
      : a == null
      ? _between(const BoxDecoration(), this, t)
      : super.lerpFrom(a, t);
  @override
  BoxDecoration? lerpTo(Decoration? b, double t) => b is BoxDecoration
      ? _between(this, b, t)
      : b == null
      ? _between(this, const BoxDecoration(), t)
      : super.lerpTo(b, t);
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DifyFocusPainter(_normal(this).createBoxPainter(onChanged), _ring(this), borderRadius, shape);
}

class _DifyFocusShadow extends BoxShadow {
  const _DifyFocusShadow(Color color, double width) : super(color: color, spreadRadius: width);
}

class _DifyFocusPainter extends BoxPainter {
  _DifyFocusPainter(this.base, this.ring, this.radius, this.shape);
  final BoxPainter base;
  final _DifyFocusShadow? ring;
  final BorderRadiusGeometry? radius;
  final BoxShape shape;
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    base.paint(canvas, offset, configuration);
    final shadow = ring, size = configuration.size;
    if (shadow == null || shadow.spreadRadius <= 0 || size == null) return;
    final width = shadow.spreadRadius;
    final paint = Paint()
      ..color = shadow.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final rect = offset & size;
    if (shape == BoxShape.circle) {
      canvas.drawCircle(rect.center, size.shortestSide / 2 + width / 2, paint);
    } else {
      canvas.drawRRect(
        (radius ?? BorderRadius.zero).resolve(configuration.textDirection).toRRect(rect).inflate(width / 2),
        paint,
      );
    }
  }

  @override
  void dispose() {
    base.dispose();
    super.dispose();
  }
}
