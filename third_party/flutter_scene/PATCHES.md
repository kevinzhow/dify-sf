# Local flutter_scene patch

Source: official flutter_scene 0.24.3 pub archive, MIT license retained in LICENSE.
Archive: https://pub.dev/api/archives/flutter_scene-0.24.3.tar.gz
SHA-256: 6d2a4acb76307b2cf45a6e458fdf61c6bcf02693514656433e5ae67eda9d4056
Repository: https://github.com/bdero/flutter_scene

Only runtime source change: lib/src/widget_texture.dart serializes the full detached
layer capture/image/readback lifetime across WidgetTexture hosts when compiled to
Dart Wasm. The previous per-host throttle allowed simultaneous captures to produce
blank or striped card textures with Flutter 3.47.6/skwasm. The app's offline editor
reproduced it after CANVAS_SETTLED in both themes; serial captures corrected it.
This is a scoped workaround, not a claim about the ultimate engine root cause.
The JavaScript/CanvasKit and native paths retain their original concurrency.

The queue releases even after an exception or a host detaching while queued. It
preserves the latest-pending-capture coalescing within each host. Wasm captures
can take longer to converge after a large change; steady-state rendering and
Scene geometry are unchanged.

Validation: from app/, build `flutter build web --release --wasm --target
tool/wasm_widget_capture_probe.dart --output <probe-directory>`, serve that directory,
and run `python3 tool/verify_web_runtime.py --capture-probe --url <probe-url>
--output <evidence-directory>` from the repository root. The probe captures twenty
nonuniform cards at different sizes and fractional densities, then compares the
actual uploaded texture pixels with independently rasterized references. It
requires all twenty textures to match. This exercises the real browser GPU path,
not a simulated queue. This standalone probe also passes against upstream 0.24.3;
it is an interop conformance check, not by itself a reproducer of the app's corruption.
The regression evidence is the actual editor before/after screenshots after
CANVAS_SETTLED; the real editor must also be exercised when upgrading.

Upgrade: run that probe and the app's actual
Wasm browser flow, inspect both themes after captures settle, and verify the
browser selected main.dart.wasm + skwasm. When upgrading Flutter or flutter_scene,
repeat the probe against the unmodified upstream implementation; remove this
vendored override once the same scenario passes without serialization. Generated
shader bundles and build caches remain ignored and must not be committed.
