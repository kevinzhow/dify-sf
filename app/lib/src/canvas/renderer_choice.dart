import 'renderer_choice_io.dart' if (dart.library.js_interop) 'renderer_choice_web.dart' as impl;

enum CanvasRendererKind { scene, widgets }

/// Flutter Scene, except under `flutter test` (no GPU there) or when DIFYSF_CANVAS=widgets.
CanvasRendererKind defaultRendererKind() =>
    impl.preferWidgets() ? CanvasRendererKind.widgets : CanvasRendererKind.scene;
