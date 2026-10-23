import 'package:flutter/widgets.dart';

import '../css_metrics.dart';
import '../dify_fonts.dart';

/// Optical alignment for compact control labels. It changes only the shared
/// strut baseline, keeping the line box, hit area and focus geometry unchanged.
/// Body paragraphs and editors continue to use the normal CSS baseline.
class DifyControlLabelScope extends InheritedWidget {
  const DifyControlLabelScope({super.key, required super.child});
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DifyControlLabelScope>() != null;
  @override
  bool updateShouldNotify(DifyControlLabelScope oldWidget) => false;
}

/// Ordinary Dify text. The browser's line box and primary-font baseline are
/// shared by labels, buttons and plain rich text, including CJK fallback runs.
/// Flutter still owns selection, semantics, shaping, wrapping and scaling.
class DifyTextLine extends StatelessWidget {
  const DifyTextLine(
    String this.data, {
    super.key,
    this.style,
    this.centerCap = false,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const DifyTextLine.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.centerCap = false,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final bool centerCap;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel, semanticsIdentifier;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  // Embedded controls and deliberately different font sizes need their own
  // intrinsic line metrics. A forced label strut must never clip a chip/image.
  static bool _hasIndependentMetrics(InlineSpan span, TextStyle base) {
    if (span is! TextSpan) return true;
    final s = span.style;
    if (s != null &&
        ((s.fontSize != null && s.fontSize != base.fontSize) || (s.height != null && s.height != base.height))) {
      return true;
    }
    return span.children?.any((c) => _hasIndependentMetrics(c, base)) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final effective = DifyFonts.resolveStyle(DefaultTextStyle.of(context).style.merge(style));
    final scaler = textScaler ?? MediaQuery.textScalerOf(context);
    final span = textSpan;
    final strut =
        strutStyle ??
        (span != null && _hasIndependentMetrics(span, effective)
            ? null
            : Css.lineStrut(effective, textScaler: scaler, centerCap: centerCap || DifyControlLabelScope.of(context)));
    if (span != null) {
      return Text.rich(
        span,
        style: effective,
        strutStyle: strut,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel,
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return Text(
      data!,
      style: effective,
      strutStyle: strut,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
