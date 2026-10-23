import 'package:flutter/widgets.dart';

import 'text_line.dart';
export 'text_line.dart';
import '../dify_tokens.g.dart';
import '../dify_fonts.dart';

/// A Dify typography utility in [color], for a [DefaultTextStyle] or a [Text]. The font family is left to the
/// selected app font profile, including its explicit Web CJK fallback.
TextStyle difyTextStyle(DifyTextStyle s, Color color) => s.style.copyWith(color: color);

/// [text] as Dify's utility renders it (`uppercase` utilities upper-case it; Flutter has no text-transform).
String difyTransform(DifyTextStyle s, String text) => s.uppercase ? text.toUpperCase() : text;

/// CSS `text-transform: capitalize`: the first letter of each word upper-cased (words as Chrome splits them:
/// punctuation other than apostrophes ends one, so `array[number]` becomes `Array[Number]`).
String cssCapitalize(String text) => text.replaceAllMapped(
  RegExp(r"(^|[^\p{L}\p{N}'’])(\p{L})", unicode: true),
  (m) => '${m[1]}${m[2]!.toUpperCase()}',
);

/// Tailwind's default transition: 150 ms, `cubic-bezier(0.4, 0, 0.2, 1)`.
const difyTransitionDuration = Duration(milliseconds: 150);
const difyTransitionCurve = Cubic(0.4, 0, 0.2, 1);

/// The font cards render with (the app theme's family); measurement outside the widget tree needs it explicitly.
String? get cardFontFamily => DifyFonts.primaryFamily;
set cardFontFamily(String? family) => DifyFonts.primaryFamily = family;

/// [difyTextStyle] with the family pinned to [cardFontFamily], for text that is also measured outside the widget
/// tree (cards); uppercase styles are applied by [DifyText].
TextStyle difyStyle(DifyTextStyle s, Color color) =>
    DifyFonts.resolveStyle(difyTextStyle(s, color).copyWith(fontFamily: cardFontFamily));

/// Text in a Dify typography utility (applies `uppercase`).
class DifyText extends StatelessWidget {
  const DifyText(
    this.text,
    this.style, {
    super.key,
    this._color,
    this.align,
    this.centerCap = false,
    this.maxLines = 1,
  });
  final String text;
  final DifyTextStyle style;
  final Color? _color;
  Color get color => _color ?? DifyColors.textPrimary;
  final TextAlign? align;
  final bool centerCap;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final s = difyStyle(style, color);
    return DifyTextLine(
      difyTransform(style, text),
      style: s,
      centerCap: centerCap,
      textAlign: align,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}
