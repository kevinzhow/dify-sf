# Reports using the Raft Visual Testing framework

`raft_report.py` adapts real Dify / Flutter Web screenshots to the unchanged
`@botiverse/raft-visual-testing` **diff** and **site** commands used by
raft-flutter's `tool/parity`. It does not implement another visual comparator or
recreate the report UI. Framework source is supplied externally; it is not
vendored into this repository.

The initial integration uses raft-source commit
`26f77ef97c40d3d91aa2c5e42b0fd66b8bf39fe6`, the reference recorded by
raft-flutter's `docs/source-reference.json`. Preserve the upstream license and
use a separate dependency installation. The required CLI dependency for
`diff`/`site --skip-analysis` is Sharp; no model analysis is requested.

## Capture contract

- Render the actual Dify page and the formal Flutter Web Wasm build with the
  same fixture, locale, theme, browser window and real device pixel ratio.
  A synthetic Start → Answer chatflow can exercise `<think>` without any model
  calls. `fixtures/thinking_chatflow.yml` contains that fixture.
- Capture the same element region on both sides. Preserve full-page context
  separately. Declare component crops as `component-fixture`; reserve
  `real-screen` for full product screens. Do not describe Web captures as
  native Android evidence.
- Admit captures only after the declared interaction/animation has completed
  and the expected text has painted. A semantics node appearing is insufficient
  evidence that its glyphs are present in the screenshot. Preserve rejected
  first frames, their timings and the reason for recapture.
- Keep before/fixed captures in distinct providers, for example `react`,
  `flutter-web-before` and `flutter-web-after`. Raw images, including text, are
  copied byte for byte. No mask, resize, recolouring or text exclusion is
  performed. Unequal image dimensions fail admission rather than being
  normalized to hide geometry changes.
- Provide source/compiled hashes and the exact crop in metadata. Capture
  accounts must be isolated fixtures; authentication state never belongs in
  the report receipt. Metadata uses an explicit allowlist.

## Invocation

Create a JSON receipt with `name`, `runId`, `framework`, `project`, `pairs`,
`cases`. `framework.files` maps the original framework's `src/` and `site/`
relative filenames to SHA-256 values; record its repository and commit too.
Each case has the upstream manifest fields (`id`, `title`, `surface`,
`captureType`, `viewport`, `theme`, `locale`, `variants`) plus a `captures` map.
Each capture provides `image` (an actual PNG path), `source`, `sourceCommit`,
`sourceInputHash`, `compiledSha256`, `viewport`, `crop`, `state` and
`fixtureSha256`, as applicable. Browser/source facts must describe the actual
capture, not an intended build.

```sh
python3 tool/visual/raft_report.py \
  --receipt /path/to/capture-receipt.json \
  --framework-root /path/to/raft-source/packages/visual-testing \
  --node /path/to/node \
  --out /path/to/new-run \
  --site-dir /path/to/new-report
```

The adapter requires fresh directories, verifies framework hashes, generates
both official commands, and adds `provenance.json`. Test it with
`python3 -m unittest discover -s tool/visual -p test_raft_report.py`.

## Reading percentages

The framework's **Pixel** metric counts exactly equal RGBA pixels. Its **RGB**
metric describes average channel similarity. The former can be low when
cross-renderer gradients and glyph antialiasing differ slightly over a large
area. RGB is diagnostic and is not a replacement for Pixel or proof of correct
geometry. Keep the framework's original scores/statuses visible.

These percentages are different from `compare.py`'s legacy proportion of pixels
within a 16/255 channel difference. Do not relabel or mix the two metrics.
Raft-flutter's additional non-text geometry classification is also a separate
extension; running this adapter alone does not claim that extension passed.
