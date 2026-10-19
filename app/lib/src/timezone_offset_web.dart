import 'dart:js_interop';

@JS('Intl.DateTimeFormat')
extension type _DateTimeFormat._(JSObject _) implements JSObject {
  external _DateTimeFormat(String locale, JSObject options);
  external JSArray<_Part> formatToParts(JSNumber date);
}

extension type _Part._(JSObject _) implements JSObject {
  external String get type;
  external String get value;
}

final _formats = <String, _DateTimeFormat?>{};

_DateTimeFormat? _format(String timezone) => _formats.putIfAbsent(timezone, () {
  try {
    return _DateTimeFormat(
      'en-US',
      {
            'timeZone': timezone,
            'hourCycle': 'h23',
            'year': 'numeric',
            'month': 'numeric',
            'day': 'numeric',
            'hour': 'numeric',
            'minute': 'numeric',
            'second': 'numeric',
          }.jsify()!
          as JSObject,
    );
  } on Object {
    return null; // RangeError: not a time zone
  }
});

/// The wall clock of [timezone] at [utc] (`formatToParts`), minus the instant.
int? platformTimezoneOffset(String timezone, DateTime utc) {
  final f = _format(timezone);
  if (f == null) return null;
  final u = utc.toUtc();
  final at = DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second);
  try {
    final parts = <String, int>{};
    for (final p in f.formatToParts(at.millisecondsSinceEpoch.toJS).toDart) {
      final n = int.tryParse(p.value);
      if (n != null) parts[p.type] = n;
    }
    final wall = DateTime.utc(
      parts['year']!,
      parts['month']!,
      parts['day']!,
      parts['hour']! % 24,
      parts['minute']!,
      parts['second']!,
    );
    return wall.difference(at).inMinutes;
  } on Object {
    return null;
  }
}
