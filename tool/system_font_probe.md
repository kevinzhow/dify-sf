# System font research probe

This is a research tool, not a production font change. Build and run it separately from the application:

```sh
tool/build_web.sh --target tool/system_font_probe.dart --output /path/to/font-probe
python3 -m http.server --directory /path/to/font-probe 8081
```

Open `/?lang=zh-Hans`; also test `zh-Hant`, `en-US`, `ja`, and `ko` on the actual target operating systems. The left side uses a native browser text/input view with Dify's CSS font stack and the requested language; the right side uses the current Flutter text/input implementation. Both are hosted by a Dart Wasm application. Confirm `main.dart.wasm` and skwasm were actually selected in the browser's network log.

The production app currently pins Noto Sans for Web and relies on the Flutter engine's fallback fonts for missing glyphs. This does not reproduce the operating system's CSS font stack. Merely listing PingFang or Microsoft YaHei in `fontFamilyFallback` cannot establish that their font data reached skwasm. The upstream discussion explains the renderer's access limitation: [Flutter issue 163823](https://github.com/flutter/flutter/issues/163823). The tested Flutter 3.47.6 engine registers loaded font bytes in `skwasm_impl/font_collection.dart`; its `font_fallback_service.dart` selects Noto fallbacks by locale.

The [Local Font Access specification](https://wicg.github.io/local-font-access/) requires a secure context and permission to access font data. It is a separate browser capability, not an automatic CSS font fallback. The production trial uses an HTTP address; this probe does not invoke that API or collect font files.

The native side uses Flutter's supported [HtmlElementView](https://api.flutter.dev/flutter/widgets/HtmlElementView-class.html). This proves a browser-native text path can coexist with Dart Wasm. It does **not** establish a finished replacement for Flutter text: layout measurement, wrapping/ellipsis, mixed spans, IME, focus, selection, accessibility, overlays, canvas clipping/zoom, image export, and performance all require a shared implementation and end-to-end validation before production use. HTML text views are not automatically included in Flutter's offscreen card captures.

On the Linux Chromium fixture, the browser's actual platform-font metadata identified NotoSansCJKjp-Regular for Chinese and NotoSans-Regular for Latin. Five locale variants loaded through Dart Wasm and accepted native input. This is Linux evidence; do not describe it as proof that macOS Web loaded PingFang. Inspect the probe on macOS and record the actual platform font there before claiming macOS parity.

Cody's Raft implementation separates CSS line-box/baseline alignment from its Android-specific Chinese control correction. Its native system-font bridge excludes Web; that fact alone proves neither that Raft Web loaded PingFang nor that every other Web path failed to do so. Android's numeric leading correction should not be copied into this Web design system.


## Fallback experiment (Flutter 3.47.6 / skwasm)

Use `?fallback=current` for the existing style, `?fallback=name` for family names (including an optional CSS-local alias `DifyCssLocal`), and `?fallback=file` to register a supplied **licensed test font** as `DifyFallbackProbe` via FontLoader. The last mode fetches `font-probe.otf` beside the built index.html; the font is intentionally not committed or added to the production bundle. Supply its license alongside it. The comparison on K17 used the system-installed OFL NotoSansCJK-Regular.ttc bytes (JP face, SHA256 b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a), with no local-font-access permission or proprietary Mac font extraction.

An actual Wasm browser run confirmed that CSS could load the installed local face, yet the Flutter sample with only its fallback names had **zero changed pixels** against the current style. Registering the font bytes changed 1.034% of the same sample area (>16/255 channel difference). This proves that other font files work; it is not a production baseline fix or a claim that Mac PingFang was loaded. Latin continues to use the primary Noto Sans face. The screenshot samples also show that selecting a font does not by itself finish CSS line-box/baseline alignment.

There is also an upstream browser-font effort, [WebParagraph](https://github.com/flutter/flutter/issues/172561). The installed engine exposes an experimental `preferWebParagraph` configuration, but its skwasm renderer's `createWebParagraphPainter` explicitly throws `UnimplementedError`. It is therefore not a supported flag-only substitute for this application's current Wasm renderer. Recheck the actual engine implementation before revisiting this decision.
