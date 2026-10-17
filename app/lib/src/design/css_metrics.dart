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

  // Noto Sans (Dify's font stack on Linux, and ours): hhea ascent 1069, descent 293 per 1000 units.
  static const _ascent = 1.069, _descent = 0.293;

  /// A text line's space above and below the baseline in Chrome: ascent and descent are rounded to whole pixels
  /// first, and the leading (line height minus both) is split with the odd pixel below.
  static ({double above, double below}) textLine(double fontSize, double lineHeight) {
    final a = (_ascent * fontSize).roundToDouble(), d = (_descent * fontSize).roundToDouble();
    final above = a + ((lineHeight - a - d) / 2).floorToDouble();
    return (above: above, below: lineHeight - above);
  }
}
