# Control typography regression

Run `tool/test_control_typography.sh` in the normal resource-limited job. It checks
all bundled font hashes, rejects unclassified new shared widget files, checks the
design-system rules, analyzes Dart, and runs the whole client test suite. An
inventory entry describes a test strategy; it does **not** mean every browser
state of that component has passed a screenshot comparison.

The actual widgets in `app/tool/control_gallery.dart` are reused, unchanged, by
`app/test/control_gallery_typography_test.dart` and the Wasm test entry point
`app/tool/control_alignment_probe.dart`. This prevents a separate test drawing
from concealing a defect in the real control. The gallery includes input,
borderless editor, search, number field, select, chip, textarea, checkbox list,
tags, checkbox, radio, switch, segmented control, tabs, tab slider, labeled
switch, collapse, badges/keycaps, slider, pagination, menu, calendar and tooltip.
Disabled and invalid examples are visible alongside ordinary controls.

Native tests use the bundled Noto Sans, DejaVu Sans Mono and regional CJK face,
in both themes. They compare actual RenderParagraph baselines with independently
specified font-file cap heights, exercise Unicode input and menu selection, and
reject focus/open-state layout changes and framework overflow errors. Studio's
three bespoke filter triggers have their own application-level regression. The
button matrix additionally covers three sizes, six styles, Chinese/Latin/mixed
labels and disabled/loading states. Font primitive tests cover other sizes,
scaling, multiline text, inline widgets and regional fallback switching.

Build the real browser fixture with:

```sh
tool/build_web.sh --target tool/control_alignment_probe.dart --output /path/to/probe-web
python tool/visual/control_typography.py --web /path/to/probe-web --out /path/to/results
```

Python dependencies are Playwright/Chromium, NumPy and Pillow (same environment as
other visual tools). `--forms-only` reruns gallery interaction checks without the
720 button/font/theme/DPR comparisons. Default captures include real Wasm and
self-hosted skwasm, actual keyboard input, focus, open popup and selected states.
A failed assertion exits nonzero and does not write a success result.

The independent button reference uses Chromium's CSS `text-box-trim: trim-both;
text-box-edge: cap alphabetic` with the same font bytes. Modern font-file cap
metrics have 0.06 CSS px comparison tolerance. Legacy DejaVu lacks OS/2 cap
height; its OpenType-recommended H-outline fallback is unhinted, whereas Chromium
rounds its legacy synthesized height. That reference has a separately reported
0.26 CSS px bound (half a pixel of synthesized edge rounding, plus geometry
precision); this is a comparison tolerance, never a production text offset.

This suite is not a claim that every glyph's painted center is identical to an
icon center. Cap/alphabetic edges keep a coherent baseline across strings;
descenders, accents and rasterization have different ink shapes. Body paragraphs
retain normal CSS line boxes. No per-language/string translation is applied.
Unknown operating-system fonts do not silently borrow Noto metrics.

Remaining limits are explicit: popup/dialog/table/toast compositions retain their
functional tests and shared text contract, but the browser gallery does not yet
capture every combination of their states. The gallery does not establish whole
page parity with Dify, arbitrary user-provided fonts, physical Android behavior,
all accessibility zoom levels, or every script. Selected Dify page comparisons
remain in `tool/visual/compare.py`; do not replace them with a gallery score.
