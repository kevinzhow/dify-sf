# Web startup and glyph-demand fonts

This is a dify-sf Flutter deployment extension. It does not introduce a different font, a CSS text renderer, synthetic glyphs or per-label offsets.

The HTML document paints a small Dify loading shell before Flutter downloads. Its theme and translated messages come from the pinned design tokens and translations through `tool/gen_web_startup.py`. It is removed after `flutter-first-frame` and the glyph requests discovered by that initial layout have settled and scheduled their repaint. First-frame and visible-ready performance marks remain distinct. Terminal initialization failures offer a document retry; recovering iOS Wasm startup retains the shell while the supported compatibility path starts.

The active regional Noto Sans CJK face is split into an interface core and 512-code-point shards. Both original weights retain their original global metrics, glyph outlines, names and advances. For Chinese, Japanese and Korean the core is loaded before the first app frame; English does not fetch CJK before a glyph is needed. The engine's existing missing-glyph detector invokes the optional application provider. It still shapes, draws, handles fallback and relayout through Flutter. Unknown code points use the original Flutter fallback detector. All pinned Flutter Noto and Roboto fallback files are self-hosted on the deployment origin, including emoji and other scripts.

Successful shard faces are requested once. A failed shard is blocked until explicit retry or an online event; its already downloaded partner weight remains available for that retry. Failure is shown using the shared Dify controls, without document reload or loss of typed input. Locale changes select that region's families; they preserve successfully registered faces. No user text or code points are sent to a separate font service.

## Reproducible build

Use the repository's pinned Flutter 3.47.6. The optional engine hook is guarded by its exact engine revision and source hash; an SDK upgrade requires review. The installed SDK is never modified. Both Wasm and CanvasKit platform libraries are compiled in an isolated directory. The build must use that local SDK; installing a hook into only one renderer is insufficient.

```sh
python3 -m venv /owned/font-tools
/owned/font-tools/bin/pip install -r tool/fonts/requirements.txt
FONTTOOLS_PYTHON=/owned/font-tools/bin/python tool/build_web.sh
```

Generation requires FontTools; ordinary validation uses the standard library and checked-in hashes. Font assets are reproducible build outputs, excluded from Git. The build verifies every source and output hash against `subsets.lock.json`. An intentional generator/source/core-text change requires running `subset.py` and `check_subsets.py --certify` with the FontTools Python, reviewing the new lock, then running the ordinary checks. Certification compares all covered glyphs and both weights with the original regional fonts. Native targets retain the original complete CJK assets; Web ships only the shards.

A release uses `DIFY_RELEASE_REVISION=<full clean HEAD>` and writes `version.json` containing resource hashes, public commit/protocol identifiers and the isolated engine proof. `tool/release_manifest.py --web <output> --check` validates a frozen release without modifying it. The account page shows the compiled client revision, the server's reported revision/protocols and actual advertised Agent, isolated Shell and mail switches. Older servers are shown as not reporting a version.

## Evidence and limits

The initial isolated browser proof ran both actual Wasm/Skwasm and JavaScript/CanvasKit. With Latin, CJK, emoji and rare supplementary characters, both weights matched full original SC faces byte for byte in raw RGBA. Only the required shards and emoji fallback were fetched; no external runtime font request occurred. Fault checks additionally cover failed partners, independent glyph failures, retry, locale reuse and preservation of user input. Full application and real-page acceptance is recorded separately for the release candidate; a minimal font proof is not a claim of whole-application parity or physical-device performance.
