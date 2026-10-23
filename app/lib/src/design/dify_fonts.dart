import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';

import 'font_metrics.g.dart';

/// Self-hosted CJK faces for skwasm. A CSS family name cannot read an installed
/// OS font into Skia. Only the active region is loaded; text still uses the
/// existing Latin face first, and real regional CJK glyphs as its fallback.
abstract final class DifyFonts {
  static String? primaryFamily;
  static TextStyle resolveStyle(TextStyle style) {
    final current = fallbackFamilies;
    final fallbacks = current == null
        ? style.fontFamilyFallback
        : <String>[
            for (final f in style.fontFamilyFallback ?? const <String>[])
              if (!f.startsWith('Dify CJK ')) f,
            ...current,
          ];
    return style.copyWith(
      fontFamily: style.fontFamily ?? primaryFamily,
      fontFamilyFallback: fallbacks,
    );
  }

  /// Actual per-face OpenType metrics generated from the pinned font bytes.
  /// Unknown system faces retain their measured CSS baseline; no guessed profile.
  static double? _metric(Map<String, Map<int, double>> table, String? family, FontWeight? weight) {
    final faces = table[family];
    if (faces == null) return null;
    final target = (weight ?? FontWeight.w400).value;
    final nearest = faces.keys.reduce((a, b) => (a - target).abs() <= (b - target).abs() ? a : b);
    return faces[nearest];
  }

  static double? capHeightRatio(String? family, FontWeight? weight) => _metric(bundledCapHeights, family, weight);
  static double? xHeightRatio(TextStyle style) {
    final effective = resolveStyle(style);
    return _metric(bundledXHeights, effective.fontFamily, effective.fontWeight);
  }

  static final _loads = <String, Future<void>>{};
  static String? _active;
  static List<String>? get fallbackFamilies => _active == null ? null : ['Dify CJK $_active'];

  static String regionFor(String language) {
    final code = language.replaceAll('_', '-').toLowerCase();
    if (code == 'ja' || code.startsWith('ja-')) return 'JP';
    if (code == 'ko' || code.startsWith('ko-')) return 'KR';
    if (code.startsWith('zh') && code.contains('hans')) return 'SC';
    if (code.startsWith('zh') && (code.contains('-hk') || code.contains('-mo'))) return 'HK';
    if (code.startsWith('zh') && (code.contains('hant') || code.contains('-tw'))) return 'TC';
    return 'SC';
  }

  static Future<void> loadFor(String language) async {
    final region = regionFor(language);
    await _loads.putIfAbsent(region, () async {
      final loader = FontLoader('Dify CJK $region');
      for (final weight in ['Regular', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/cjk/NotoSansCJK$region-$weight.woff2'));
      }
      await loader.load();
    });
    _active = region;
  }
}
