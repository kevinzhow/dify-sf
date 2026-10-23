import 'timezone_offset_io.dart' if (dart.library.js_interop) 'timezone_offset_web.dart' as impl;

/// The offset (minutes east of UTC) of the IANA time zone [timezone] at the instant [utc], from the platform's time zone
/// database when it has one (a browser's `Intl.DateTimeFormat`); null when the platform cannot tell (desktop builds:
/// callers fall back to the built-in rules of `defaultTimezoneOffset`) or the name is unknown.
int? platformTimezoneOffset(String timezone, DateTime utc) => impl.platformTimezoneOffset(timezone, utc);
