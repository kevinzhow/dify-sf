# UI acceptance: Raft Visual Testing

All visual component and page reviews use the unmodified Raft Visual Testing `diff` and `site` commands, pinned in `raft_framework.json` (the same framework used by raft-flutter). `raft_report.py` is a capture/provenance adapter, not a replacement scoring algorithm. Run with `--skip-analysis`; this workflow makes no model requests.

A unit test, typography inventory, successful compile, or high RGB average does not establish UI parity. Review the actual Pixel/RGB values, raw pairs and Matrix. Pixel is exact RGBA agreement. Keep failing and missing cases visible. No exclusion masks, text exclusion, image resizing, manual pixel edits or thresholds that relabel differences as passes.

Inventory the actual shared exports, leaf routes and node panels in `ui_coverage.json`. Every visual family needs concrete case IDs; a wrapper may share its child's case only when it really renders there. Nonvisual infrastructure needs an explicit reason. New exports/routes/classes must update this inventory; the normal `tool/test_control_typography.sh` entry point runs this guard. `check_ui_coverage.py` checks source membership, public class inventories and case references; it is a coverage guard, not proof of capture success. Compare declared coverage with the run's capture receipts.

Capture the actual pinned Dify React implementation and Flutter Web Wasm from known source/builds. Shared fixtures use the same labels, state, viewport and DPR. Page cases use real navigation. Network fixtures must be labeled and identical in meaning; they do not prove backend integration. Use disposable accounts/apps and block unexpected runtime/model calls. Never publish sessions, credentials, private headers or private fixture state.

Record theme, locale, viewport/DPR, selected/open/focused state, source commit, fixture/build hash and actual capture admission. Semantics alone do not prove pixels painted. Wait for the expected state and rendered content, preserve the full context plus any declared crop. Use a fresh output directory for every attempt; keep the first failure and explain reruns. A timeout or wrong page remains Missing with an error receipt; do not admit the screenshot of the wrong state as a valid provider image.

The report must state the actual tested matrix and omissions. Light/dark and English/Chinese control captures do not imply every page was tested in both languages. Desktop emulation does not imply a physical Android/TalkBack test.

## Entry points

- `react_ui/`: imports the pinned original React controls and production CSS.
- `app/tool/ui_parity_probe.dart`: imports the real Flutter design-system widgets.
- `capture_components.py`: equal-stage component capture with raw context and errors.
- `compare.py`: legacy real-product provider/navigation helpers; its historical custom score/masks are not acceptance metrics.
- `raft_report.py --receipt ... --framework-root ... --out ... --site-dir ... --node ...`: unchanged framework diff + report.
- `python3 check_ui_coverage.py`: source/case coverage guard.

See `RAFT_REPORT.md` for upstream checkout and report commands. Test infrastructure failures and existing product differences must be reported separately.


## Reproduce the actual component reference

Set `PRODUCT_COMMIT` to the verified source SHA of the supplied Flutter build. Use a fresh owned directory on disk. The reference checkout is read-only; the exporter binds the Dify tag to `ui_reference.json`.

```sh
python3 tool/visual/prepare_ui_reference.py --checkout /path/to/dify --deps-root /owned/ui-deps
cp tool/visual/react_ui/package{,-lock}.json /owned/ui-deps/
(cd /owned/ui-deps && npm ci --ignore-scripts --legacy-peer-deps --no-audit --no-fund)
python3 tool/visual/prepare_ui_reference.py --checkout /path/to/dify --deps-root /owned/ui-deps --link-deps
node tool/visual/build_react_ui.mjs --deps-root /owned/ui-deps --reference-root /owned/ui-deps/reference --stage /owned/ui-deps/react-stage --out /owned/ui-deps/react-build
tool/build_web.sh --target tool/ui_parity_probe.dart --output /owned/flutter-build
python tool/visual/capture_components.py --catalog tool/visual/component_cases_complete.json --reference-build /owned/ui-deps/react-build --product-commit "$PRODUCT_COMMIT" --flutter-build /owned/flutter-build --out /owned/captures
```

`--legacy-peer-deps` is needed because upstream's Vite dependency is the `@voidzero-dev/vite-plus-core` alias (version 0.3.1) while the React plugin declares a Vite-major peer range. Versions and integrity are fixed by the test-host lockfile. Create package links after npm finishes; do not run npm over links pointing back into the reference subtree. Future dependency updates should use a new owned stage.

The reference host sets `<html lang>` exactly as the production layout does. Record Chromium’s actual platform face rather than inferring it from HTML language: on this Linux host, even the original Chinese page selects Noto Sans CJK JP while Flutter loads its pinned SC face. Keep this environment difference visible; do not rewrite images or fonts to inflate similarity. The production CSS and all control implementations come from the pinned export. The only environment shim is `IS_PROD=true`, read by the calendar's date utility; no control or style code is replaced. Table/surface/text/toolbar fixtures use declared CSS primitives or compositions where upstream has no standalone component. Reorderable fixtures import upstream's actual keyboard-sortable hook. Animated spinners/toasts retain their real behavior; one captured frame does not prove animation parity.

The component fixture has a neutral 640×480 stage. Default captures explicitly leave focus after enabling Flutter semantics; focus/open variants then enter their declared state. Global overlays get the full viewport, not an inline 400px constraint. Capture receipts distinguish the React direct child/Flutter GlobalKey rectangle from popup semantic rectangles.

Page/editor runners require a private `--session` JSON, mode 0600: `dify.base`, `dify.cookies` (name/value), optional `dify.headers`, and `sf.base`/`sf.tokens` from disposable accounts. It is a runtime input, never a repository fixture or report attachment. Auth refresh and preview/search fixtures are explicit. Built-in-only runtime cases verify the graph whitelist and restrict invocation paths to the just-created app IDs; this is not authorization for model, HTTP, tool or sandbox calls.

## Assemble and audit a complete run

`editor_cases.json`, `extra_panel_cases.json` and `editor_overlay_cases.json` are logical cases; the editor runner expands each to light/dark English captures. `page_cases.json` and `component_cases_complete.json` already contain explicit variants. Page captures use `real-screen`, the upstream capture type, and explicit viewport/density rather than framework defaults.

```sh
python tool/visual/capture_pages.py --session /private/session.json --catalog tool/visual/page_cases.json --product-commit "$PRODUCT_COMMIT" --flutter-build /owned/product-build --out /owned/pages
python tool/visual/capture_editors.py --session /private/session.json --catalog tool/visual/editor_cases.json --product-commit "$PRODUCT_COMMIT" --flutter-build /owned/product-build --out /owned/editors
python tool/visual/capture_editors.py --session /private/session.json --catalog tool/visual/extra_panel_cases.json --product-commit "$PRODUCT_COMMIT" --flutter-build /owned/product-build --out /owned/panels
python tool/visual/capture_editors.py --session /private/session.json --catalog tool/visual/editor_overlay_cases.json --product-commit "$PRODUCT_COMMIT" --flutter-build /owned/product-build --out /owned/overlays
python tool/visual/assemble_ui_receipt.py --run /owned/controls --run /owned/pages --run /owned/editors --run /owned/panels --run /owned/overlays --product-commit "$PRODUCT_COMMIT" --run-id ui-baseline --out /owned/receipt
python tool/visual/raft_report.py --receipt /owned/receipt/receipt.json --framework-root /readonly/visual-testing --out /owned/report-input --site-dir /owned/site --node /path/to/node
```

For retries, append the fresh attempt directory after the previous one. The latest attempt wins even if it failed. The assembler rejects unattempted declarations, unknown cases and unexpected providers; it does not select the best score. `superseded_cases.json` records the exceptional case where source inspection proves a reference was the wrong component. Such attempts remain in a separate history with their reason and declared replacements, outside the comparable matrix. In this baseline the editor scrollbar is compared in the actual Monaco code panel, rather than with the unrelated modern ScrollArea.

A batch provider qualification records real Dart/Skia Wasm loading and Chromium platform fonts for the immutable component build. This supplements, and does not pretend to be, per-case network/font observations. The page/editor runners also record the actual Wasm resources in each admitted candidate capture. Keep the source inventory, attempt history, provider qualification and raw image hashes beside the official report.

Runtime UI fixtures allow only Start, End, literal Answer and Variable Aggregator nodes, restricted to newly imported app IDs. Template Transform also requires the code sandbox and is deliberately outside this visual-run whitelist. Non-executed panel fixtures may contain other node types; the capture guard blocks their invocation.

The fixture compositions provide the same explicit text preset and layout on both sides. For example, DialogContent’s source `p-6` is 24 CSS px and its content is left aligned; the Dart fixture supplies those same caller-owned values to DifyDialogSurface. Surface and drawer labels use `system-sm-regular` on both sides. A fixture accidentally omitting caller-owned padding/alignment is an invalid comparison, not a product defect. Preserve that attempt before correcting the fixture and recapturing.

## Read small controls without background dilution

Keep the complete stage/page report. Additionally run `local_control_receipt.py --receipt /owned/receipt/receipt.json --out /owned/local-controls` and feed that receipt to the same unchanged Raft `diff`/`site` adapter in a second fresh report directory. These are additional views of the same scenarios, not extra scenario coverage.

The crop is fixed mechanically from the union of **both** providers’ observed control and overlay rectangles, with the existing 2 CSS px stroke margin, clipped to the stage. Both PNGs get the identical integer pixel rectangle. It retains size and position differences; no image is resized or aligned independently. Crop provenance contains the original/crop hashes and coordinates. All pixels outside it remain in the full-stage report. Missing pairs stay Missing. Local views expose a small wrong control that a large uniform background could otherwise dilute; they are not substitutes for checking full-page placement or overflow.

For menus/buttons whose positions can differ between implementations, use a semantic candidate locator (`oursClick`) and assert the resulting visible state. Coordinate replay alone is insufficient admission: it can close a popup or hit a different control. A transient toast needs its actual message present when the PNG is captured; reduce only the declared state wait, never its pixels or comparison threshold.

The neutral stage fixes the **maximum inline width** while leaving inline content at its natural height (`height:auto`). Flutter's fixture uses a loose-width Align and a vertical UnconstrainedBox; it must not stretch every control to 400px, or stretch a collapsed section/pagination/table to the stage height. Explicit caller widths are declared as `fixtureWidth` in the catalog and checked at capture admission. The constraint smoke checks the real input/collapse/pagination/table/checkbox before starting a complete batch.

The React host mirrors next-themes’ `data-theme` **and** the document’s native `color-scheme`; the latter affects native inputs and scrollbars even when CSS palette variables already look correct. Qualify both against the live original. `check_raft_site.py --url ... --expected-cases ... --out ...` checks the generated report's Matrix, source tabs and loaded images at desktop/mobile report widths, separately from product UI acceptance.

Width admission is limited to a fixture’s **outer caller constraint**, such as a SizedBox. It must not reinterpret a widget's internal paint-width parameter as its outer layout width: SkeletonRectangle, for example, can paint a 300px block inside a wider alignment wrapper. Preserve both measured rectangles and the PNG; such layout differences belong in review rather than being hidden as capture failures. Framework `basic-pass` is also not a typography or geometry verdict.

Pass `--product-commit` for the **supplied compiled build**, rather than assuming the checkout HEAD is its source. If unknown, capture metadata omits it; a build hash still identifies the bytes. The assembler also accepts `--product-commit` and `--run-id`; it must not hardcode a past audit’s product commit or run identifier. Reference source is separately pinned by `ui_reference.json`.
