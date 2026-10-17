/// nodes/trigger-schedule/utils/cron-parser.ts over a Dart port of the `cron-parser` package's 5-field syntax.
library;

import 'schedule_timezone.dart';

/// A 5-field cron expression (or a predefined `@` macro) as cron-parser reads it: `*` and `?`, lists, ranges,
/// steps (`*/5`, `1-10/2`, `5/15`), month and weekday names, weekday 7 for Sunday, `L` (last day of the month),
/// `<weekday>L` (last such weekday) and `<weekday>#<n>` (n-th such weekday). When both the day of month and the day
/// of week are restricted, either matching is enough.
final class CronExpression {
  CronExpression._(this._minutes, this._hours, this._months, this._dom, this._dow);

  final List<int> _minutes, _hours;
  final Set<int> _months;
  final bool Function(DateTime)? _dom, _dow; // null: `*` / `?`

  static const _macros = {
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
    '@monthly': '0 0 1 * *',
    '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *',
    '@hourly': '0 * * * *',
    '@minutely': '* * * * *',
    '@weekdays': '0 0 * * 1-5',
    '@weekends': '0 0 * * 0,6',
  };
  static const _monthNames = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  static const _dayNames = {'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6};

  /// `CronExpressionParser.parse`: throws a [FormatException] for anything cron-parser rejects.
  factory CronExpression.parse(String expression) {
    final e = expression.trim();
    final macro = e.startsWith('@') ? _macros[e.toLowerCase()] : null;
    if (e.startsWith('@') && macro == null) throw FormatException('Unknown predefined expression', expression);
    final fields = (macro ?? e).split(RegExp(r'\s+'));
    if (fields.length != 5) throw FormatException('Expected 5 fields', expression);
    final minutes = _values(fields[0], 0, 59), hours = _values(fields[1], 0, 23);
    final months = _values(fields[3], 1, 12, _monthNames);
    final dom = _day(fields[2], false), dow = _day(fields[4], true);
    bool wild(String f) => f == '*' || f == '?';
    return CronExpression._(
      minutes.toList()..sort(),
      hours.toList()..sort(),
      months,
      wild(fields[2]) ? null : dom,
      wild(fields[4]) ? null : dow,
    );
  }

  static int _value(String s, int lo, int hi, Map<String, int> names) {
    final v = RegExp(r'^\d+$').hasMatch(s) ? int.parse(s) : names[s.toLowerCase()];
    if (v == null || v < lo || v > hi) throw FormatException('Invalid value', s);
    return v;
  }

  static Set<int> _values(String field, int lo, int hi, [Map<String, int> names = const {}]) {
    final out = <int>{};
    for (final part in field.split(',')) {
      final slash = part.split('/');
      if (slash.length > 2 || part.isEmpty) throw FormatException('Invalid field', field);
      final step = slash.length == 2 ? int.tryParse(slash[1]) : 1;
      if (step == null || step < 1) throw FormatException('Invalid step', field);
      final range = slash[0];
      final int a, b;
      if (range == '*' || range == '?') {
        (a, b) = (lo, hi);
      } else {
        final ends = range.split('-');
        if (ends.length > 2) throw FormatException('Invalid range', field);
        a = _value(ends.first, lo, hi, names);
        b = ends.length == 2 ? _value(ends.last, lo, hi, names) : (slash.length == 2 ? hi : a);
      }
      if (a > b) throw FormatException('Invalid range', field);
      for (var v = a; v <= b; v += step) {
        out.add(v);
      }
    }
    return out;
  }

  static int _length(DateTime d) => DateTime.utc(d.year, d.month + 1, 0).day;

  static bool Function(DateTime) _day(String field, bool weekday) {
    final special = <bool Function(DateTime)>[];
    final plain = <String>[];
    for (final part in field.split(',')) {
      final m = RegExp(r'^(\w+?)(L|#([1-5]))$', caseSensitive: false).firstMatch(part);
      if (!weekday && part.toUpperCase() == 'L') {
        special.add((d) => d.day == _length(d));
      } else if (weekday && m != null) {
        final w = _value(m[1]!, 0, 7, _dayNames) % 7;
        final n = m[3] == null ? null : int.parse(m[3]!);
        special.add((d) => d.weekday % 7 == w && (n == null ? d.day + 7 > _length(d) : (d.day - 1) ~/ 7 + 1 == n));
      } else {
        plain.add(part);
      }
    }
    final values = plain.isEmpty
        ? <int>{}
        : _values(plain.join(','), weekday ? 0 : 1, weekday ? 7 : 31, weekday ? _dayNames : const {});
    final set = weekday ? {for (final v in values) v % 7} : values;
    return (d) => set.contains(weekday ? d.weekday % 7 : d.day) || special.any((s) => s(d));
  }

  bool _dayMatches(DateTime d) => switch ((_dom, _dow)) {
    (null, null) => true,
    (final dom?, null) => dom(d),
    (null, final dow?) => dow(d),
    (final dom?, final dow?) => dom(d) || dow(d),
  };

  /// The first matching minute after [after] (a wall-clock time), searched over eight years; null if none.
  DateTime? next(DateTime after) {
    final start = DateTime.utc(after.year, after.month, after.day, after.hour, after.minute + 1);
    final first = DateTime.utc(start.year, start.month, start.day);
    for (var i = 0; i < 366 * 8; i++) {
      final day = DateTime.utc(first.year, first.month, first.day + i);
      if (!_months.contains(day.month) || !_dayMatches(day)) continue;
      for (final h in _hours) {
        for (final m in _minutes) {
          final t = DateTime.utc(day.year, day.month, day.day, h, m);
          if (!t.isBefore(start)) return t;
        }
      }
    }
    return null;
  }

  /// `interval.take(count)` from [after].
  List<DateTime> take(int count, DateTime after) {
    final out = <DateTime>[];
    var from = after;
    while (out.length < count) {
      final t = next(from);
      if (t == null) break;
      out.add(t);
      from = t;
    }
    return out;
  }
}

/// parseCronExpression: the next 5 runs of [cronExpression] after [now] (default: the current time) as wall-clock
/// times in [timezone] (UTC [DateTime]s whose fields read as that clock); empty when it is not valid.
List<DateTime> parseCronExpression(
  String cronExpression, [
  String timezone = 'UTC',
  DateTime? now,
  TimezoneOffset offset = defaultTimezoneOffset,
]) {
  if (cronExpression.trim().isEmpty) return const [];
  final parts = cronExpression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5 && !cronExpression.startsWith('@')) return const [];
  try {
    final cron = CronExpression.parse(cronExpression);
    return cron.take(5, wallClockAt(timezone, now ?? DateTime.now(), offset: offset));
  } on FormatException {
    return const [];
  }
}

/// isValidCronExpression: 5 fields (or an `@` macro) cron-parser accepts.
bool isValidCronExpression(String cronExpression) {
  if (cronExpression.trim().isEmpty) return false;
  final parts = cronExpression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5 && !cronExpression.startsWith('@')) return false;
  try {
    CronExpression.parse(cronExpression);
    return true;
  } on FormatException {
    return false;
  }
}
