# Pinned grapheme data

GraphemeBreakProperty-16.0.0.txt comes from https://www.unicode.org/Public/16.0.0/ucd/auxiliary/GraphemeBreakProperty.txt, matching the Unicode version of the pinned Dart characters 1.4.1 package. Its hash is checked by both generation and the build lock.

The generator keeps the original face’s Extend, ZWJ, SpacingMark, Prepend and conjoining Jamo (L/V/T) glyphs beside every shard’s base characters. Code-point ownership remains a partition, while these shaping companions intentionally occur in multiple faces. This prevents a font-family boundary from breaking an original combining sequence. Existing cmap format 14 variation mappings and their non-default glyphs remain with their base. Input strings are never normalized or rewritten.

The data’s original copyright header and the Unicode license are retained here.
