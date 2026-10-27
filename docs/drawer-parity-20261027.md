# Shared drawer and responsive page-state fixes

Opening Features in a 390px viewport previously sized the drawer against the editor after its 64px sidebar: the popup began at x=96 and was 294px wide. The pinned Dify page begins at x=32 and is 358px wide. Clicking the left viewport gutter also failed to dismiss the candidate drawer. Resizing from desktop to phone remounted the page and closed both Features and annotation drawers; an unsaved Unicode form value became empty.

The shared drawer now supplies the source viewport limit and full available height. Its default right edge has no border. Features uses the canonical root-overlay portal, and the detail sidebar preserves the existing page element across layout changes. Annotation, workflow-tool and log drawers retain their explicitly inset gutter and border recipes. The old feature-page offscreen-border compensation is removed.

The source remains Dify 1.17.1, commit `8387590ace4a094de812b7847fc6a4c3a27cd52b`, with `@langgenius/dify-ui` 0.0.1 resolved through `workspace:*`. Drawer dimensions are generated from the package classes, with strict recognition and a source hash in `tool/design/reference.json`. No scoring thresholds, masks or colors were adjusted.

## Evidence and limits

[Full original images, actual-page geometry, interactions and unchanged Raft scoring](https://k17.tail4653d.ts.net/reports/drawer-20261027/analysis.html) cover two themes and 1440, 390 and 320px widths. Each actual drawer is opened before resizing the native Chromium window, which retains DPR 2. These are browser window checks, not physical-device tests.

- All twelve reference page states pass. The previous client passes two of twelve interaction/geometry checks and fails ten. The new client passes all twelve. The full images and failed attempts are retained.
- Six existing visual scenarios were rerun: four basic drawer variants and two real editor Features states. They remain two basic passes and four differences. The twelve supplemental full-page pairs also remain pixel-different, despite passing geometry and interaction checks. Navigation folding, header extensions, actual save times, input styling and rendering differences remain visible.
- The complete 450-case matrix was not rerun. Its historical e84f90b result remains 171 strict / 67 basic / 212 different / 0 missing. This slice does not establish a new whole-application count or visual parity.
- A remaining annotation Answer input border/background difference is recorded for the shared input family. Physical Android Chrome / iOS Safari acceptance remains pending.

Both new default-drawer regressions, the unsaved-input regression and the constrained-viewport portal regression failed before their respective fixes. The final portal/sidebar/mobile suite passes 500 tests; analysis reports zero issues. An earlier 651-test family suite also passed before the portal change. The old single-frame portal assertion was updated to wait for actual portal mounting; its initial failure remains in the evidence. The first 4GiB web compile exceeded its cap; the same source built successfully under the existing 6GiB slot.

The application and component-probe release builds are from `db94b6ebe1599419d45e422c13a9ec1f922e4953`, with 2763 files each. Application Wasm SHA-256: `cd47e95524593895916573e241fd9c30908e505b8acfd5bdc90664e868ac7240`. All 440 font assets were reused byte-for-byte after proving their generation inputs unchanged. No backend or migration files changed.

Run the real-page check with disposable sessions only:

```sh
python tool/visual/capture_drawer_pages.py \
  --source . --session /private/disposable-session.json \
  --build /owned/frozen-web-build --revision SOURCE_COMMIT \
  --out /owned/new-attempt
```

The session format is the same as the other visual runners. The script imports and deletes its own test apps, rejects execution requests and preserves failures. It must never use a real trial account.
