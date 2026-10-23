# Self-hosted Web CJK font faces

These are the upstream regional Noto Sans 2.004 subsets, compressed losslessly as WOFF2. `sources.json` pins the official commit, original Git blob and SHA-256 for every input. `app/assets/fonts/cjk/provenance.json` records every output, family, weight and size; OFL is distributed beside them. The original Latin Noto Sans files remain the primary face.

Only the active Web region is loaded with `FontLoader`, before initial rendering or completing a locale switch: SC for Simplified Chinese/default, TC for Traditional Chinese, HK for Hong Kong/Macao, JP for Japanese, KR for Korean. Both real Regular and Bold faces are supplied. The files contain the complete corresponding upstream regional subset, not a sample of translated UI characters. Rare characters outside a face's coverage can still use Flutter's normal font fallback.

All ten assets total about 47 MiB. The default SC pair costs about 13.76 MiB on its first fetch; the other regional pairs are requested only on demand. This prioritizes deterministic, self-hosted Chinese rendering over the engine's remote, character-by-character fallback. It does not load an installed macOS PingFang or Windows font into skwasm, and does not claim their glyph shapes are identical. Native platforms retain their existing platform font choice.

Rebuild in an isolated build environment (`fonttools[woff]==4.59.0`, `brotli==1.1.0`):

```sh
python tool/fonts/build_cjk.py --cache /var/tmp/Winnie/<task>/upstream
```

The generator verifies pinned input bytes, preserves the upstream cmap and hhea metrics, and records output digests. Brotli quality 6 trades a little compression for substantially less build CPU; WOFF2 is lossless at every quality. The deployed app has no Python dependency.

Sources: [pinned Noto deployment formats](https://github.com/notofonts/noto-cjk/blob/523d033d6cb47f4a80c58a35753646f5c3608a78/Sans/README.md), [Flutter FontLoader](https://api.flutter.dev/flutter/services/FontLoader-class.html), [StrutStyle](https://api.flutter.dev/flutter/painting/StrutStyle-class.html).

## Shared control alignment metrics

Run `build_metrics.py` with the same FontTools environment to regenerate
`app/lib/src/design/font_metrics.g.dart` and `metrics.json` from the **actual
bundled font bytes**. Every entry records the family/weight, units per em,
OpenType `sCapHeight` / `sxHeight`, source hash and path. Legacy faces without
those OS/2 fields use the OpenType-defined H/x outline fallback. Ratios must
never be adjusted by eye.

Compact labels use the cap/alphabetic text edge described by
[CSS Inline Layout](https://www.w3.org/TR/css-inline-3/#text-box-edge), preserving
fractional values and a consistent baseline across translations and fallback
runs. Normal paragraphs and multiline editors retain CSS line boxes. Inline
chips use their current face's x-height and measured line metrics. Unknown
native faces retain engine layout rather than inheriting another font's profile.
Flutter does not currently expose tight glyph outlines through GlyphInfo;
its layout bounds must not be treated as visible ink bounds.
