import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'dify_fonts.dart';
import 'css_border_stub.dart' if (dart.library.js_interop) 'css_border_web.dart';

/// Where Chrome turns CSS lengths into pixels differently from Flutter (Dify is the specification as Chrome shows
/// it): border widths snap to device pixels, and a line of text puts its baseline on rounded font metrics.
abstract final class Css {
  /// The device pixel ratio borders snap to.
  static double get devicePixelRatio => WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

  /// A border width as Chrome lays it out and draws it: rounded down to device pixels, but never below one.
  static double border(double width) {
    if (width <= 0) return 0;
    final native = browserBorderWidth(width);
    if (native != null) return native;
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

  /// Chrome's intrinsic width of Dify Input (`size=20`, Noto Sans 13px/16px, px-3 and a 1px border).
  /// A flex child with `min-width:auto` keeps this width even when its declared width is 100%; siblings with
  /// flex-shrink (such as IconButton) give up space first. Measured in the pinned Dify 1.17.1 browser fixture.
  static const inputMinContentWidth = 174.640625;

  /// The browser's native input canvas under the requested native colour
  /// scheme, as the original TagInput leaves it visible (`appearance-none`).
  /// Native targets use the matching Chromium Field defaults.
  static Color inputBackground(bool dark) {
    final css = browserInputBackground(dark);
    final channels = css == null ? <String>[] : RegExp(r'[\d.]+').allMatches(css).map((m) => m[0]!).toList();
    if (channels.length >= 3) {
      return Color.from(
        alpha: channels.length > 3 ? double.parse(channels[3]) : 1,
        red: double.parse(channels[0]) / 255,
        green: double.parse(channels[1]) / 255,
        blue: double.parse(channels[2]) / 255,
      );
    }
    return dark ? const Color(0xFF3B3B3B) : const Color(0xFFFFFFFF);
  }

  /// Blink's size=20 intrinsic input width, before padding/borders. The primary
  /// font's OpenType average and bounding-box width are rounded at the current
  /// font size (LayoutTextControlSingleLine::PreferredContentLogicalWidth).
  /// This is independent of the placeholder; a CSS grid still keeps the input's
  /// intrinsic contribution when a hidden text mirror is shorter.
  static double nativeInputWidth(TextStyle style, TextScaler scaler, {int size = 20}) {
    style = DifyFonts.resolveStyle(style);
    final fontSize = scaler.scale(style.fontSize ?? 14);
    final average = DifyFonts.averageCharWidthRatio(style);
    final maximum = DifyFonts.maxCharWidthRatio(style);
    if (average != null && maximum != null) {
      final charWidth = (average * fontSize).roundToDouble();
      return (charWidth * size).ceilToDouble() + (maximum * fontSize).roundToDouble() - charWidth;
    }
    // Native, unbundled fonts: the CSS ch fallback uses the current primary 0.
    final probe = TextPainter(
      text: TextSpan(text: '0', style: style),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final width = probe.width * size;
    probe.dispose();
    return math.max(0, width);
  }

  /// CSS Backgrounds and Borders: outer box shadows are clipped to the
  /// outside of the border box. Flutter BoxDecoration otherwise paints them
  /// beneath translucent backgrounds, tinting the interior of glass surfaces.
  static Decoration boxDecoration(BoxDecoration source) => _CssBoxDecoration(source);

  /// Flutter BoxShadow uses sigma = radius*0.57735+0.5; CSS blur uses
  /// sigma = blur/2 (the same conversion as gen_dify_tokens.py).
  static double shadowBlur(double css) => css <= 0 ? 0 : math.max(.001, (css / 2 - .5) / .57735);

  /// CSS's baseline from the selected primary face, including native fonts.
  static ({double above, double below}) textLine(
    double fontSize,
    double lineHeight, {
    TextStyle style = const TextStyle(),
  }) {
    final m = fontMetrics(style);
    final a = (m.ascent * fontSize).roundToDouble(), d = (m.descent * fontSize).roundToDouble();
    final above = a + ((lineHeight - a - d) / 2).floorToDouble();
    return (above: above, below: lineHeight - above);
  }

  static ({double ascent, double descent}) fontMetrics(TextStyle style) => _metrics(DifyFonts.resolveStyle(style));

  // Metrics are measured from the selected primary font, never from a fixed
  // Latin hhea constant. Fallback glyphs share that CSS strut; they do not add
  // a second line height merely because the string contains Chinese.
  static final _primaryMetrics = <TextStyle, ({double ascent, double descent})>{};

  static ({double ascent, double descent}) _metrics(TextStyle style) {
    final key = TextStyle(
      inherit: false,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
      fontVariations: style.fontVariations,
      fontSize: 100,
      height: kTextHeightNone,
    );
    if (_primaryMetrics.length >= 256) _primaryMetrics.clear();
    return _primaryMetrics.putIfAbsent(key, () {
      final probe = TextPainter(
        text: TextSpan(text: 'Hg', style: key),
        textDirection: TextDirection.ltr,
      )..layout();
      final m = probe.computeLineMetrics().first;
      probe.dispose();
      return (ascent: m.ascent / 100, descent: m.descent / 100);
    });
  }

  /// One CSS baseline/line height for all ordinary text and input controls.
  /// Measures the actual primary face (also for native platform/mono fonts),
  /// and accounts for accessibility scaling before rounding browser metrics.
  /// Font size and line height remain independent: no per-string translation.
  static StrutStyle? lineStrut(
    TextStyle style, {
    TextScaler textScaler = TextScaler.noScaling,
    bool centerCap = false,
  }) {
    style = DifyFonts.resolveStyle(style);
    final size = style.fontSize, height = style.height;
    if (size == null || height == null || height <= 0) return null;
    final m = _metrics(style);
    final scaledSize = textScaler.scale(size), lineHeight = scaledSize * height;
    final a = (m.ascent * scaledSize).roundToDouble(), d = (m.descent * scaledSize).roundToDouble();
    var baseline = a + ((lineHeight - a - d) / 2).floorToDouble();
    final cap = centerCap ? DifyFonts.capHeightRatio(style.fontFamily, style.fontWeight) : null;
    if (cap != null) {
      // Equivalent to centering a cap/alphabetic trimmed text box (CSS
      // Inline Layout). Keep the font-derived fractional value: no per-label
      // offsets, fixed font ratios or device-independent pixel nudges.
      baseline = (lineHeight + scaledSize * cap) / 2;
    }
    final difference = m.ascent - m.descent;
    if (difference.abs() < .00001) return null;
    final scaledStrut = 2 * (baseline - lineHeight / 2) / difference;
    if (scaledStrut <= 0) return null;
    var strutSize = scaledStrut;
    if (textScaler != TextScaler.noScaling) {
      // TextScaler may be nonlinear; dividing by one scale factor is invalid.
      var low = 0.0, high = size;
      while (textScaler.scale(high) < scaledStrut) {
        high *= 2;
      }
      for (var i = 0; i < 40; i++) {
        final middle = (low + high) / 2;
        textScaler.scale(middle) < scaledStrut ? low = middle : high = middle;
      }
      strutSize = (low + high) / 2;
    }
    return StrutStyle(
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
      fontSize: strutSize,
      height: lineHeight / scaledStrut,
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

/// Preserve the source layout/gradient/border while applying CSS's outer-shadow
/// knockout. Paint-only: the decoration's padding and content coordinates stay
/// those of its underlying border box.
class _CssBoxDecoration extends Decoration {
  const _CssBoxDecoration(this.source);
  final BoxDecoration source;

  @override
  EdgeInsetsGeometry get padding => source.padding;

  @override
  bool get isComplex => source.isComplex;

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) => source.getClipPath(rect, textDirection);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _CssBoxPainter(source, onChanged);
}

class _CssBoxPainter extends BoxPainter {
  _CssBoxPainter(this.source, VoidCallback? onChanged)
    : shadows = BoxDecoration(
        borderRadius: source.borderRadius,
        shape: source.shape,
        boxShadow: source.boxShadow,
      ).createBoxPainter(onChanged),
      foreground = source.copyWith(boxShadow: const []).createBoxPainter(onChanged),
      super(onChanged);

  final BoxDecoration source;
  final BoxPainter shadows, foreground;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    if (source.boxShadow?.isNotEmpty ?? false) {
      final rect = offset & configuration.size!;
      final shape = Path();
      if (source.shape == BoxShape.circle) {
        shape.addOval(rect);
      } else {
        shape.addRRect((source.borderRadius ?? BorderRadius.zero).resolve(configuration.textDirection).toRRect(rect));
      }
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(canvas.getLocalClipBounds())
        ..addPath(shape, Offset.zero);
      canvas.save();
      canvas.clipPath(outside);
      shadows.paint(canvas, offset, configuration);
      canvas.restore();
    }
    foreground.paint(canvas, offset, configuration);
  }

  @override
  void dispose() {
    shadows.dispose();
    foreground.dispose();
    super.dispose();
  }
}
