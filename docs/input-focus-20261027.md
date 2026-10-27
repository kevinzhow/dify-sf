# Initial input focus and annotation editing

The actual Dify Add Annotation page focuses Answer when the drawer opens. Immediate typing goes into that field. The previous Flutter page kept DOM focus on a non-input span, so typing was ignored and the textarea displayed its inactive colors.

The common `difyTextField` helper and canonical `DifyInput` / `DifyTextarea` now expose `autofocus`, delegated to the framework TextField lifecycle. The add form requests Answer focus once, matching the final winner of React's two autoFocus siblings. Flutter chooses the first eligible autofocus request, so requesting it for both fields would produce a different result. Annotation editing also forwards the source's focus request when its textarea mounts. Rebuilding controlled values or resizing the window does not refocus the original field after the user selects another one.

No style recipe, color, border, font or offset was changed. The active appearance follows the existing shared input focus state. The reference lock now guards fourteen source files, including the Input, Textarea, shared focus classes and annotation call sites in Dify 1.17.1 / dify-ui 0.0.1.

[Original images, scoped unchanged Raft scoring and interaction receipts](https://k17.tail4653d.ts.net/reports/input-focus-20261027/analysis.html) cover six real-page pairs: two themes and 1440, 390 and 320px native Chromium windows at DPR 2. Each pair has an initial Answer state and a user-selected Question state. All twelve original/candidate page checks pass initial direct typing, focus/value persistence during resizing, and typing into the selected field after controlled-value updates.

The first attempt retained two 320px field-switch input failures. The final harness waits for the target DOM focus and Flutter's input listener before sending synthetic text. Some recorded focus events precede that listener's attachment, consistent with the pinned SDK's asynchronous semantics-input activation. Both attempts use the same product bytes; the earlier failures remain available and are not counted as another product fix.

The mounted initial-Answer regression fails before the fix. 284 related tests and a strengthened 29-test edit suite pass; these suites overlap. The edit helper now types through the already-focused input instead of using a test helper that focuses it automatically. Unicode values, selecting another field, rebuilding and resizing are covered. Flutter analysis and design/reference/coverage guards pass. The release web build contains 2763 files and is from `800652f725f844e477dafb16d66fa29dbcd6a247`.

The report's twelve new focus-state visual cases remain pixel-different. The complete 450-scene matrix was not rerun: its historical e84f90b result remains 171 strict / 67 basic / 212 different / 0 missing. DOM/canvas caret capture, navigation folding, rendering and other existing differences remain visible. Physical Android Chrome and iOS Safari are still pending.

Reproduce against disposable accounts with the same private session format as the other visual runners:

```sh
python tool/visual/capture_input_focus_pages.py \
  --source . --session /private/disposable-session.json \
  --build /owned/frozen-web-build --revision SOURCE_COMMIT \
  --out /owned/fresh-attempt
```

The runner imports and deletes its own test apps, blocks execution calls, records input-listener admission and keeps failed attempts. No actual trial account or paid provider call is used.
