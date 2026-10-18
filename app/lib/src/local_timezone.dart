import 'local_timezone_io.dart' if (dart.library.js_interop) 'local_timezone_web.dart' as impl;

/// The system's IANA time zone (`Intl.DateTimeFormat().resolvedOptions().timeZone` in a browser; `TZ`, /etc/timezone
/// or the /etc/localtime link on desktop), or null when it cannot be told.
String? localTimezone() => impl.localTimezone();
