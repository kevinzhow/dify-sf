import 'open_url_io.dart' if (dart.library.js_interop) 'open_url_web.dart' as impl;

/// Opens [url] outside the app (a new browser tab on the web, the system's handler on desktop). Best effort: there is
/// nothing to report when no handler exists.
Future<void> openExternalUrl(String url) => impl.openExternalUrl(url);
