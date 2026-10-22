// Keep card chrome in Flutter's own paint/compositing pipeline on the Web.
// Scene's detached widget -> texture captures can introduce blank compositor
// frames during hover on skwasm. The retained, culled WidgetRenderer still
// runs entirely in Dart Wasm and uses skwasm; it does not select a JS fallback.
// Explicit opt-in remains available for diagnosing the Scene capture bridge.
bool preferWidgets() => Uri.base.queryParameters['canvas'] != 'scene';
