# Comparing the browser UIs

`compare.py` captures the pinned Dify 1.17.1 and a fixed Flutter web build in Chromium. These are selected screenshot cases, not a claim of whole-application visual parity. Behavioral tests and the design-system allowlist do not establish visual parity either.

Supply local fixture credentials through `DIFY_EMAIL`, `DIFY_PASSWORD`, `DIFYSF_EMAIL`, `DIFYSF_PASSWORD`, and the corresponding `DIFY_URL` / `DIFYSF_URL`. Use an isolated dify-sf database; never point the fixture at someone's trial account. Workflow cases import and delete test apps on both servers. Studio toolbar cases only read the page after signing in. Keep credentials out of commands, reports and attachments.

Build the client with `tool/build_web.sh`, and pass a fixed build directory with `--ours-build`. Install Python dependencies (`playwright`, `requests`, `numpy`, `Pillow`) in a virtual environment and install Playwright's Chromium there.

```sh
python tool/visual/compare.py \
  --cases tool/visual/studio_cases.json --only studio-toolbar-light \
  --locale zh-Hans --theme light --ours-build /path/to/fixed/wasm/build \
  --out /path/to/results --fail-under 99.5 --fail-all-under 99.5
```

Run this for `en-US` and `zh-Hans`, in both light and dark (`--only studio-toolbar-dark --theme dark`). The legacy `cases.json` covers other selected pages/panels, predominantly in English; its locators are not automatically translated. `studio_cases.json` adds the previously missing Studio toolbar. It includes default, keyboard focus and expanded sort-menu states (`studio-toolbar-focus-*` / `studio-toolbar-open-*`). It does not cover every control/state elsewhere.

The original script was report-only despite a “pass: 99.5%” table heading. That heading has been removed. `--fail-under` now makes a low non-text score fail the process, and `--fail-all-under` also gates the score including text. Without thresholds legacy cases remain report-only. Cases with `controls` additionally fail geometry mismatches. A known failing capture is useful evidence, not an accepted baseline: do not lower thresholds or add masks to label it passing.

## What is measured

Both sides use the same Chromium binary, window size and real browser DPR (default 2, using `--force-device-scale-factor`, rather than Playwright's emulated density). Locale is set in both applications. Captures save actual viewport, DPR, visual-viewport scale and user agent. Control comparison rejects mismatched environment/locale/theme metadata, including a stale reused Dify capture. Reference CSS and Chromium's actual platform fonts are recorded. Flutter semantics DOM fonts do **not** identify the fonts painted on its canvas.

The pixel score is the fraction of compared pixels whose maximum RGB-channel difference is at most 16/255. It is neither perceptual similarity nor “percent of the UI correctly implemented.” Large uniform backgrounds dilute a small control's errors. The legacy report includes an all-pixel score and a separate score excluding reference text rectangles; explicit case masks apply to both scores. Therefore a legacy all-pixel score with masks is not an unmasked typography verdict. `alignment_audit.py` is a separate text/edge position diagnostic, not a font/weight assertion and not automatically run by `compare.py`.

Cases with `controls` capture each named control tightly (2 CSS px of surrounding margin), with **no masks, no text exclusion and no image resizing**. `controls.json` contains the local all-pixel scores, original and actual bounding boxes, absolute position/size deltas, and distinct size/geometry comparisons (0.5 CSS px tolerance). Differently sized crops have no fabricated similarity score and fail the geometry check. The full-page crop is still retained: local crops cannot prove correct placement of the control in the page. Studio's intentionally omitted Tags control remains visible in the full difference and in the absolute positions of later controls.

The 99.5% invocation above deliberately exposes current failures, including text shape/baseline and known scope omissions. It is not a declaration that this threshold has been met on all platforms. Inspect paired PNGs, geometry, typography and interaction states together. The focus case traverses the real Flutter keyboard focus order and requires painted accent-ring pixels; merely focusing a semantics DOM node does not establish a focused Flutter widget. A static screenshot also cannot verify a route transition: the desktop navigation regression tests inspect real Navigator push/pop frames separately.

```sh
python -m unittest discover -s tool/visual -p test_compare.py -v
```

These regression tests reject background dilution, text-only masking and rescaled size mismatches, as well as wrong-language/zoomed references.
