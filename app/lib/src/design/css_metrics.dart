import 'package:flutter/widgets.dart';

/// Where Chrome turns CSS lengths into pixels differently from Flutter (Dify is the specification as Chrome shows
/// it): border widths snap to device pixels, and a line of text puts its baseline on rounded font metrics.
abstract final class Css {
  /// The device pixel ratio borders snap to.
  static double get devicePixelRatio => WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

  /// A border width as Chrome lays it out and draws it: rounded down to device pixels, but never below one.
  static double border(double width) {
    if (width <= 0) return 0;
    final dpr = devicePixelRatio;
    final px = (width * dpr).floor();
    return (px < 1 ? 1 : px) / dpr;
  }

  /// The 0.5 px borders Dify uses everywhere (`border-[0.5px]`).
  static double get hairline => border(0.5);

  /// How far the text line under an inline-block icon button (`p-1` around a 16 px icon) reaches below it when the
  /// button is all a block holds (as a Field's operations): the line box of the block's 16 px / 24 px strut is that
  /// much taller than the button, which sits at its top. Measured in Chrome: 2.5 px at 2x, 2 px at 1x.
  static double get inlineButtonLineGap => devicePixelRatio >= 2 ? 2.5 : 2;

  // Noto Sans (Dify's font stack on Linux, and ours): hhea ascent 1069, descent 293 per 1000 units.
  static const _ascent = 1.069, _descent = 0.293;

  /// A text line's space above and below the baseline in Chrome: ascent and descent are rounded to whole pixels
  /// first, and the leading (line height minus both) is split with the odd pixel below.
  static ({double above, double below}) textLine(double fontSize, double lineHeight) {
    final a = (_ascent * fontSize).roundToDouble(), d = (_descent * fontSize).roundToDouble();
    final above = a + ((lineHeight - a - d) / 2).floorToDouble();
    return (above: above, below: lineHeight - above);
  }

  /// A forced strut putting the baseline of text in [style] (its font size and line height) where Chrome does
  /// ([textLine]): Flutter's lies [_ascent] + half the leading below the line's top, unrounded (0.4 to 0.7 px lower for
  /// 12 px text in 16 or 18 px lines, 14 px text in 20 or 24 px lines). The strut's own font size moves its baseline
  /// (half the leading is `(lineHeight - (ascent + descent) * size) / 2`) and keeps the line height. Null for styles
  /// without a line height.
  static StrutStyle? lineStrut(TextStyle style) {
    final size = style.fontSize, height = style.height;
    if (size == null || height == null) return null;
    final lineHeight = size * height;
    final strutSize = (textLine(size, lineHeight).above - lineHeight / 2) / ((_ascent - _descent) / 2);
    if (strutSize <= 0) return null;
    return StrutStyle(
      fontFamily: style.fontFamily,
      fontSize: strutSize,
      height: lineHeight / strutSize,
      leadingDistribution: TextLeadingDistribution.even,
      forceStrutHeight: true,
    );
  }
}

/// CSS `border: <width> dashed` around a box with rounded corners, as Chrome strokes it (one closed path along the
/// border's centre line, from the top edge's start after the top-left corner, clockwise): dashes 3 widths long and
/// gaps of about 2 widths, the gap stretched or shrunk so that whole dashes fill the path (StrokeData's
/// SelectBestDashGap). Widths under 3 px only (Dify's dashed borders are 1 px).
class CssDashedBorder extends Decoration {
  const CssDashedBorder({required this.color, this.width = 1, this.radius = 0});
  final Color color;
  final double width, radius;

  /// The dash and gap lengths along a closed path of [length].
  static ({double dash, double gap})? intervals(double length, double width) {
    final dash = 3 * width, gap = 2 * width;
    if (length <= dash * 2) return null; // solid
    final fewer = (length / (dash + gap)).floorToDouble(), more = fewer + 1;
    final fewerGap = (length - fewer * dash) / fewer, moreGap = (length - more * dash) / more;
    return (dash: dash, gap: moreGap <= 0 || (fewerGap - gap).abs() < (moreGap - gap).abs() ? fewerGap : moreGap);
  }

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _CssDashedPainter(this);
}

class _CssDashedPainter extends BoxPainter {
  _CssDashedPainter(this.d);
  final CssDashedBorder d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final b = (offset & configuration.size!).deflate(d.width / 2);
    final r = (d.radius - d.width / 2).clamp(0.0, b.shortestSide / 2);
    final corner = Radius.circular(r);
    final path = Path()
      ..moveTo(b.left + r, b.top)
      ..lineTo(b.right - r, b.top)
      ..arcToPoint(Offset(b.right, b.top + r), radius: corner)
      ..lineTo(b.right, b.bottom - r)
      ..arcToPoint(Offset(b.right - r, b.bottom), radius: corner)
      ..lineTo(b.left + r, b.bottom)
      ..arcToPoint(Offset(b.left, b.bottom - r), radius: corner)
      ..lineTo(b.left, b.top + r)
      ..arcToPoint(Offset(b.left + r, b.top), radius: corner)
      ..close();
    final paint = Paint()
      ..color = d.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = d.width;
    final metric = path.computeMetrics().first;
    final iv = CssDashedBorder.intervals(metric.length, d.width);
    if (iv == null) {
      canvas.drawPath(path, paint);
      return;
    }
    final dashes = Path();
    for (var t = 0.0; t < metric.length - 0.01; t += iv.dash + iv.gap) {
      dashes.addPath(metric.extractPath(t, t + iv.dash), Offset.zero);
    }
    canvas.drawPath(dashes, paint);
  }
}
