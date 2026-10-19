# Local SVG renderer extensions

The three packages in `packages/` are copied from Flutter's BSD-3-Clause licensed
[flutter/packages](https://github.com/flutter/packages) repository. Their LICENSE files are retained.

Pinned foundation: [PR 12988](https://github.com/flutter/packages/pull/12988), commit
`e6d2f2ea018c5169b4ef80198e7d02073edef3ef`. This is an upstream draft, not a released Flutter package.
`SOURCE.json` records the source. Gaussian-blur parameters and validation were also researched in
[PR 11909](https://github.com/flutter/packages/pull/11909), fixed commit
`6ec752fe45ed02accf34a914a7bd9806b7c8dd30`. Its AST duplication approach is not applied: blur participates in
12988's named-input filter graph instead. There is no dependency on a moving branch.

Local changes:

- Discover pattern IDs before parsing their uses, including definitions after the drawing element.
- Resolve bitmap/vector pattern tiles in user-space or object-bounding-box coordinates. Preserve tile origins,
  pattern transforms and element transforms; restore nested pattern state. Cache keys include the target tile geometry and complete transform, so repeated uses with different bounding boxes receive independent shaders. Compiler command expectations now assert those per-target tile dimensions. The bounds implementation covers
  paths, vertices and images, which covers Dify's pattern-filled assets; text bounding boxes and pattern viewBox
  support are not added here.
- Clone shared paints before applying a pattern, so its shader cannot leak into subsequent ordinary fills or text.
- Record image draws on the pattern's active canvas, retain image handles for CanvasKit, rasterize the tile at
  its display resolution and adjust its shader transform accordingly. Bitmap minification uses mipmapped
  filtering. Pattern textures participate in the existing shared size/allocation budget; oversized tiles now
  fail before allocating a recorder. The corresponding upstream budget test checks that earlier failure.
- Add `feGaussianBlur` (one/two standard deviations), `feBlend`, and Porter–Duff `feComposite`. Reuse the
  foundation's coordinate systems, primitive regions, named inputs, color-space conversions and resource limits.
  These support the blur, drop-shadow and inner-shadow graphs used by Dify. Direct `feDropShadow` and arithmetic
  `feComposite` are not implemented, and are not used by the common-effects asset group.
- When a blend would exceed the existing replay budget, materialize its effect/background branch first. Keep
  the final vector foreground intact rather than resampling the entire icon. Outset hard blend clips by 1/256 of a sample pixel
  so rounding a half-pixel boundary cannot discard the foreground coverage fringe. Avoid a redundant normal-sRGB
  SourceGraphic layer: CanvasKit would reapply viewport clip coverage and dim the first row. Other primitives
  retain upstream clipping rules. A focused regression test covers both bounded replay and a fractional placement.
- Honor `mask-type: alpha` by converting mask RGB to white while preserving alpha through the shared color-matrix
  pipeline before the codec's luminance-mask command. This is necessary for Gemini's filtered icon.
- Keep the previous unfiltered appearance for an entire filter graph containing the explicitly deferred
  `feMorphology`, `feTurbulence`, `feDisplacementMap` or `feComponentTransfer` primitives. Other unknown primitives
  remain errors. The five affected Dify assets are `embedded/{chromeplugin-option,scripts-option}.svg` and
  `dify_icons/public/knowledge/online-drive/{buckets-blue,buckets-gray,folder}.svg`.
  Deferred boundaries are removed before compiler optimizations; the runtime also handles precompiled graphs.
- Resolve dependencies among these vendored packages by sibling paths so package tests use the same pinned
  codec/compiler/runtime as the application. The application's dependency overrides select this stack for
  flutter_svg; a different codec must not be substituted independently.

Validation is reproducible from the package directories with `flutter pub get` followed by `flutter test`.
The application also has a provider-icon regression test. For the complete merged asset matrix, run
`tool/visual/render_svg_inventory.dart` with Flutter's test runner from `app/`, then `tool/visual/svg_inventory.py`.
Their command-line comments describe output paths and colors. Generated screenshots, source hashes, per-icon
scores and the five deferred-effect comparisons are artifacts under `build/`, not production raster assets.
There are no pre-rendered provider icons in the application bundle.

The foundation also fixes source opacity quantization to match `dart:ui`: 1% opacity becomes alpha 3/255,
where the previous compiler truncated it to 2/255. This is retained, with the upstream tests checking all
encoded alpha bytes and 1,001 opacity values. Consequently even a deferred icon can differ slightly in a
low-opacity outline; the per-icon comparison records these differences rather than changing the original SVG.

Replace this copy with a released upstream implementation once its behavior passes the same provider,
full-inventory and filter tests. Retain the binary codec/compiler/runtime version pairing when upgrading.

## Accepted pixel differences

The complete comparison covers 1,734 light/dark cases (857 application SVGs and 20 provider cases),
at 40 CSS pixels, device scale 2 (80 physical pixels), against Chromium. A pixel passes when all
RGB channels differ by at most 16. Scores below are the fraction of passing pixels, not a claim that
the images are identical. The measured baseline is `0f48b8c`; the renderer is the implementation
originally committed as `9cf47bb`. The complete JSON and image comparisons remain validation artifacts.

Native rendering improves 78 cases, leaves 1,655 equal, and lowers one score by one pixel.
Web rendering improves 98 cases, leaves 1,627 equal, and lowers nine scores by 1–3 pixels.
Seven of those nine Web cases nevertheless have a lower mean absolute RGB error (MAE).
The accepted differences retain correct opacity quantization and CanvasKit antialiasing;
they do not restore truncation or alter assets, masks, thresholds, or the reference images.

| Renderer | Asset / theme | Before (%) | After (%) | MAE before | MAE after |
|---|---|---:|---:|---:|---:|
| native | `dify_icons/public/knowledge/online-drive/buckets-blue.svg` / light | 98.000000 | 97.984375 | 1.979167 | 1.997031 |
| web | `dify_icons/public/files/csv.svg` / light | 97.484375 | 97.468750 | 1.348750 | 0.856198 |
| web | `dify_icons/public/files/json.svg` / dark | 98.765625 | 98.750000 | 0.765885 | 0.800000 |
| web | `dify_icons/public/llm/azureai.svg` / light | 97.453125 | 97.437500 | 0.875052 | 0.874115 |
| web | `dify_icons/public/llm/azureai.svg` / dark | 97.687500 | 97.671875 | 0.679479 | 0.678542 |
| web | `dify_icons/public/llm/chatglm.svg` / light | 94.859375 | 94.812500 | 1.382865 | 1.376719 |
| web | `dify_icons/public/llm/gpt-4.svg` / light | 96.593750 | 96.578125 | 0.919635 | 0.842448 |
| web | `dify_icons/vender/line/education/book-open-01.svg` / light | 95.109375 | 95.093750 | 1.607187 | 1.435156 |
| web | `dify_icons/vender/plugin/box-sparkle-fill.svg` / dark | 97.609375 | 97.593750 | 0.743021 | 0.727812 |
| web | `dify_icons/vender/solid/general/question-triangle.svg` / light | 97.921875 | 97.890625 | 0.727760 | 0.728021 |

The native blue-bucket/light MAE rises from 1.979167 to 1.997031 because the corrected opacity rounds
1% to alpha 3/255 instead of truncating to 2/255; that recorded increase is accepted.

The five deferred assets listed above still use their unfiltered appearance. This acceptance covers
the recorded pixel differences; it does not mark deferred filter primitives as implemented.

## Upgrade checklist

Before replacing this draft foundation or changing Flutter, flutter_svg, or another consumer of these overrides:

- Upgrade codec, compiler, and runtime together; inspect all dependency consumers and retained licenses/pins.
- Run `vector_graphics/test/filters/dify_extensions_test.dart`, especially
  `forward pattern references use the geometry of each differently sized target`,
  `equal-sized targets with different transforms do not share a pattern shader`,
  `a patterned fill does not change later unpatterned fills sharing its paint`, both
  `black mask uses alpha/luminance as declared` cases, and the Gaussian/blend/composite cases.
- Run `vector_graphics/test/filters/foreground_test.dart`:
  `a bounded shadow graph preserves vector foreground edges at a fractional display offset`.
  Recheck the replay budget and the 1/256-sample clip outset in both native rendering and CanvasKit.
- Run the compiler's `filter_foundation_regression_test.dart` and `paint_test.dart`, including
  `opacity quantization matches dart:ui throughout the unit interval` and
  `all encoded alpha bytes survive an opacity round trip`.
- Inspect deferred-primitive removal before compiler optimization and the runtime guard for precompiled graphs;
  rerender all five deferred assets in both themes to check the intentionally unfiltered appearance.
- Rerun full package/application tests and the complete native/Web/Chromium asset comparison with the same
  source hashes and scoring contract. Preserve before/after scores and inspect differences rather than
  treating the accepted historical deltas as permission for unrelated future regressions.
