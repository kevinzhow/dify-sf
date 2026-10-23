/// The time formats the header and the publisher show (Dify's `useTimestamp().formatTime`,
/// `useFormatTimeFromNow().formatTimeFromNow` and `formatWorkflowRunIdentifier`), with dayjs's English wording.
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// `formatTime(seconds, 'HH:mm:ss')` in local time (dayjs tokens `HH`, `hh`, `mm`, `ss`, `YYYY`, `MM`, `DD`, `A`).
/// The account's time zone (Dify's `useTimestamp`): `AccountTime.of(context).formatTime` (auth/account_time.dart).
String formatTime(int seconds, String format) =>
    formatDateFields(DateTime.fromMillisecondsSinceEpoch(seconds * 1000), format);

/// [d]'s fields as they read (local or UTC alike) in a dayjs [format] (the tokens of [formatTime]).
String formatDateFields(DateTime d, String format) {
  return format
      .replaceAll('YYYY', '${d.year}')
      .replaceAll('MM', _two(d.month))
      .replaceAll('DD', _two(d.day))
      .replaceAll('HH', _two(d.hour))
      .replaceAll('hh', _two(d.hour % 12 == 0 ? 12 : d.hour % 12))
      .replaceAll('mm', _two(d.minute))
      .replaceAll('ss', _two(d.second))
      .replaceAll('A', d.hour < 12 ? 'AM' : 'PM');
}

/// dayjs `fromNow()` (relativeTime plugin, default thresholds, en): "a few seconds ago", "5 minutes ago", "in 2 hours".
String formatTimeFromNow(int milliseconds, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).millisecondsSinceEpoch - milliseconds;
  final past = diff >= 0;
  final s = diff.abs() / 1000;
  final m = s / 60, h = m / 60, d = h / 24;
  String n(double v, String one, String many) => v.round() <= 1 ? one : '${v.round()} $many';
  final text = s < 44.5
      ? 'a few seconds'
      : s < 89.5
      ? 'a minute'
      : m < 44.5
      ? n(m, 'a minute', 'minutes')
      : m < 89.5
      ? 'an hour'
      : h < 21.5
      ? n(h, 'an hour', 'hours')
      : h < 35.5
      ? 'a day'
      : d < 25.5
      ? n(d, 'a day', 'days')
      : d < 45
      ? 'a month'
      : d < 319
      ? n(d / 30.4, 'a month', 'months')
      : d < 547
      ? 'a year'
      : n(d / 365, 'a year', 'years');
  return past ? '$text ago' : 'in $text';
}

/// workflow/utils/common.ts `formatWorkflowRunIdentifier`: ` (02:30:25 PM)` from a run's `finished_at` (seconds; the
/// en-US `toLocaleTimeString` with 2-digit hour, minute and second), else ` (Running)` (the capitalized fallback).
String formatWorkflowRunIdentifier(int? finishedAt, [String fallbackText = 'Running']) {
  if (finishedAt == null || finishedAt == 0) {
    final capitalized = fallbackText.isEmpty ? '' : fallbackText[0].toUpperCase() + fallbackText.substring(1);
    return ' ($capitalized)';
  }
  final d = DateTime.fromMillisecondsSinceEpoch(finishedAt * 1000);
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return ' (${_two(h12)}:${_two(d.minute)}:${_two(d.second)} ${d.hour < 12 ? 'AM' : 'PM'})';
}

/// The formatters the header uses; tests replace them (Dify's tests mock `useTimestamp` and `useFormatTimeFromNow`).
class HeaderFormatters {
  const HeaderFormatters({
    this.formatTime = _time,
    this.formatTimeFromNow = _fromNow,
    this.formatWorkflowRunIdentifier = _runIdentifier,
  });

  final String Function(int seconds, String format) formatTime;
  final String Function(int milliseconds) formatTimeFromNow;

  /// `(finishedAt, status)`: Dify's helper takes the status as its fallback text.
  final String Function(int? finishedAt, [String fallbackText]) formatWorkflowRunIdentifier;
}

String _time(int seconds, String format) => formatTime(seconds, format);
String _fromNow(int milliseconds) => formatTimeFromNow(milliseconds);
String _runIdentifier(int? finishedAt, [String fallbackText = 'Running']) =>
    formatWorkflowRunIdentifier(finishedAt, fallbackText);
