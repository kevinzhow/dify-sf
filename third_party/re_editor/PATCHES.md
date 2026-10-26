# Re-Editor input/layout integration

Upstream: https://github.com/reqable/re-editor, commit `e2f4a967` (0.10.0), MIT, copyright Reqable. The full immutable commit and source/patch hashes are recorded in `UPSTREAM.json`; only `lib`, `pubspec.yaml` and `LICENSE` are vendored. Run `python3 tool/check_editor_vendor.py` after review.

Dify's canonical `CodeEditorView` retains its existing Monaco 0.52.2 document, token styles, auto-closing/indentation commands and chrome. Re-Editor supplies Flutter input, gestures, selection, undo and text-input geometry. Its default toolbar/scrollbar styles are replaced by the existing Dify design-system families. No embedded DOM editor or second font pipeline is introduced.

Local changes:

- A public `CodeParagraphBuilder` controller/delegate hook accepts one `IParagraph` implementation for drawing, hit testing, selections, caret and input-method rectangles. Ordinary controllers retain the original paragraph provider.
- `scrollBeyondLastLine` adds scroll extent without using bottom padding. Padding would shrink the interactive viewport and make visible continuation rows unclickable.
- The obsolete isolate-manager dependency constrained Web to 0.5. Flutter's existing `compute` replaces that optional highlighter/chunk task bridge, with closed/latest-result guards. The app retains its own Monarch spans and explicitly disables chunk analysis; original syntax styles are not replaced by Re-Highlight.
- Web uses Flutter’s ordinary full-state text-input channel: the pinned engine’s `SemanticsTextEditingStrategy.addEventHandlers` omits the `beforeinput`/composition hooks needed by its delta inference. Native platforms retain delta input. This avoids ignoring real browser insertions when semantics is enabled.
- Platform selection/composition-only changes update selection metadata without replacing a selected multi-line document. This applies to both native delta and full-state updates.
- Legacy text-input updates go through the same delta/prefix path. Native composing regions and UTF-16 offsets remain source positions. The adapter groups a plain edit and Monaco's typed-character adjustment before publishing `onChanged`.
- Delayed mobile cursor reveal, completion updates and composing-rectangle retries are owned cancellable timers, cleared on disposal. Read-only mobile key handlers refuse edits.
- Theme color changes invalidate cached styled paragraphs and schedule layout, rather than painting an old cached color. The app releases retired paragraph painters after the frame and handles system-font arrival without recreating the focused editor.

These are narrow integration changes. The fork does not claim additional Dify features such as code folding, a minimap or arbitrary extension APIs. Original MIT notices are retained.
