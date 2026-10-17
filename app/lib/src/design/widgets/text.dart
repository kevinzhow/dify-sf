import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';

/// A Dify typography utility in [color], for a [DefaultTextStyle] or a [Text]. The font family is left to the
/// ambient style (the app theme's), like Dify's `font-sans` stack.
TextStyle difyTextStyle(DifyTextStyle s, Color color) => s.style.copyWith(color: color);

/// [text] as Dify's utility renders it (`uppercase` utilities upper-case it; Flutter has no text-transform).
String difyTransform(DifyTextStyle s, String text) => s.uppercase ? text.toUpperCase() : text;

/// CSS `text-transform: capitalize`: the first letter of each word upper-cased.
String cssCapitalize(String text) =>
    text.replaceAllMapped(RegExp(r'(^|\s)(\S)'), (m) => '${m[1]}${m[2]!.toUpperCase()}');

/// Tailwind's default transition: 150 ms, `cubic-bezier(0.4, 0, 0.2, 1)`.
const difyTransitionDuration = Duration(milliseconds: 150);
const difyTransitionCurve = Cubic(0.4, 0, 0.2, 1);
