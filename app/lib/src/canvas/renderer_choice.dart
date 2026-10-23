import 'renderer_choice_io.dart' if (dart.library.js_interop) 'renderer_choice_web.dart' as impl;

enum CanvasRendererKind { scene, widgets }

/// The retained widget canvas on Web and in tests. Native GPU builds use
/// Flutter Scene; Web may opt in with `canvas=scene` for capture diagnostics.
CanvasRendererKind defaultRendererKind() =>
    impl.preferWidgets() ? CanvasRendererKind.widgets : CanvasRendererKind.scene;
