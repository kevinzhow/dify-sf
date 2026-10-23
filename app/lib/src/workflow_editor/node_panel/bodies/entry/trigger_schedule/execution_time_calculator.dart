/// nodes/trigger-schedule/utils/execution-time-calculator.ts: the next runs of a schedule as wall-clock times in its
/// timezone, and their en-US texts. Times are UTC [DateTime]s whose fields read as that timezone's clock (Dify's
/// "user timezone representation").
library;

import 'cron_parser.dart';
import 'schedule_timezone.dart';

/// What the calculator reads besides the node data: the current instant and the timezone rules.
final class ScheduleClock {
  const ScheduleClock({this.now, this.offset = defaultTimezoneOffset, this.localTimezone = 'UTC'});

  /// The current instant (null: [DateTime.now]).
  final DateTime Function()? now;
  final TimezoneOffset offset;

  /// The browser's timezone (`Intl.DateTimeFormat().resolvedOptions().timeZone`), for data without a timezone.
  final String localTimezone;

  DateTime instant() => now?.call() ?? DateTime.now();
}

String _resolveTimezone(Object? timezone, ScheduleClock clock) =>
    timezone is String && timezone.isNotEmpty ? timezone : clock.localTimezone;

Map<String, Object?> _map(Object? v) => v is Map<String, Object?> ? v : const {};

/// "h:mm A" as (hour 0-23, minute): Dify's `parseInt` of the parts (NaN reads as 0 here).
(int, int) _time(String s) {
  final words = s.split(' ');
  final period = words.length > 1 ? words[1] : null;
  final parts = words.first.split(':');
  int lead(String? x) => int.tryParse(RegExp(r'^\s*[+-]?\d+').stringMatch(x ?? '')?.trim() ?? '') ?? 0;
  var hour = lead(parts.first);
  final minute = lead(parts.length > 1 ? parts[1] : null);
  if (period == 'PM' && hour != 12) hour += 12;
  if (period == 'AM' && hour == 12) hour = 0;
  return (hour, minute);
}

const _dayMap = {'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6};

/// getNextExecutionTimes: up to [count] next runs of the schedule in [data] (Dify's node `data`).
List<DateTime> getNextExecutionTimes(
  Map<String, Object?> data, [
  int count = 5,
  ScheduleClock clock = const ScheduleClock(),
]) {
  final timezone = _resolveTimezone(data['timezone'], clock);
  final instant = clock.instant();
  if (data['mode'] == 'cron') {
    final cron = data['cron_expression'];
    if (cron is! String || cron.isEmpty || !isValidCronExpression(cron)) return [];
    return parseCronExpression(cron, timezone, instant, clock.offset).take(count).toList();
  }

  final config = _map(data['visual_config']);
  final configTime = config['time'];
  final defaultTime = configTime is String && configTime.isNotEmpty ? configTime : '12:00 AM';
  final current = wallClockAt(timezone, instant, offset: clock.offset);
  final today = DateTime.utc(current.year, current.month, current.day);
  DateTime at(int days, int hour, int minute) => DateTime.utc(today.year, today.month, today.day + days, hour, minute);
  final times = <DateTime>[];

  switch (data['frequency']) {
    case 'hourly':
      final onMinute = switch (config['on_minute']) {
        final num n => n.toInt(),
        _ => 0,
      };
      final hour = current.hour + (current.minute >= onMinute ? 1 : 0);
      for (var i = 0; i < count; i++) {
        times.add(at(0, hour + i, onMinute));
      }
    case 'daily':
      final (hour, minute) = _time(defaultTime);
      final startOffset = !at(0, hour, minute).isAfter(current) ? 1 : 0;
      for (var i = 0; i < count; i++) {
        times.add(at(startOffset + i, hour, minute));
      }
    case 'weekly':
      final listed = config['weekdays'];
      // `weekdays || ['sun']`: an empty list is truthy in JavaScript, so it yields no runs.
      final selectedDays = listed is List ? listed : const ['sun'];
      final (hour, minute) = _time(defaultTime);
      var weekOffset = 0;
      while (times.length < count) {
        var hasValidDays = false;
        for (final selectedDay in selectedDays) {
          if (times.length >= count) break;
          final targetDay = _dayMap[selectedDay];
          if (targetDay == null) continue;
          hasValidDays = true;
          final daysUntilTarget = (targetDay - today.weekday % 7 + 7) % 7;
          final adjusted = daysUntilTarget == 0 && !at(0, hour, minute).isAfter(current) ? 7 : daysUntilTarget;
          final execution = at(adjusted + weekOffset * 7, hour, minute);
          if (execution.isAfter(current)) times.add(execution);
        }
        if (!hasValidDays) break;
        weekOffset++;
      }
      times.sort();
    case 'monthly':
      final listed = config['monthly_days'];
      final selectedDays = {
        ...(listed is List && listed.isNotEmpty ? listed : const [1]),
      };
      final (hour, minute) = _time(defaultTime);
      // Dify loops until it has [count] runs; days no month has (e.g. 32) would never end, so stop after ten years.
      for (var monthOffset = 0; times.length < count && monthOffset < 120; monthOffset++) {
        final target = DateTime.utc(today.year, today.month + monthOffset);
        final daysInMonth = DateTime.utc(target.year, target.month + 1, 0).day;
        final monthly = <DateTime>[];
        final processed = <int>{};
        for (final selectedDay in selectedDays) {
          final int targetDay;
          if (selectedDay == 'last') {
            targetDay = daysInMonth;
          } else if (selectedDay is num) {
            if (selectedDay > daysInMonth) continue;
            targetDay = selectedDay.toInt();
          } else {
            continue;
          }
          if (!processed.add(targetDay)) continue;
          final execution = DateTime.utc(target.year, target.month, targetDay, hour, minute);
          if (execution.isAfter(current)) monthly.add(execution);
        }
        monthly.sort();
        for (final e in monthly) {
          if (times.length >= count) break;
          times.add(e);
        }
      }
    default:
      for (var i = 0; i < count; i++) {
        times.add(at(i, 0, 0));
      }
  }
  return times;
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/// formatUserTimezoneDate: en-US `"[Weekday, ]Month D, YYYY, h:mm AM"`, plus ` (UTC+8)` with [includeTimezone].
String formatUserTimezoneDate(
  DateTime date,
  String timezone, {
  bool includeWeekday = true,
  bool includeTimezone = true,
}) {
  final h = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final day =
      '${includeWeekday ? '${_weekdays[date.weekday % 7]}, ' : ''}'
      '${_months[date.month - 1]} ${date.day}, ${date.year}';
  final time = '$h:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
  return includeTimezone ? '$day, $time (${convertTimezoneToOffsetStr(timezone)})' : '$day, $time';
}

bool _includeWeekday(Map<String, Object?> data) => data['mode'] == 'visual' && data['frequency'] == 'weekly';

/// getFormattedExecutionTimes: the panel's texts of the next [count] runs, with the timezone offset.
List<String> getFormattedExecutionTimes(
  Map<String, Object?> data, [
  int count = 5,
  ScheduleClock clock = const ScheduleClock(),
]) {
  final timezone = _resolveTimezone(data['timezone'], clock);
  return [
    for (final d in getNextExecutionTimes(data, count, clock))
      formatUserTimezoneDate(d, timezone, includeWeekday: _includeWeekday(data)),
  ];
}

/// getNextExecutionTime: the canvas card's text of the next run (no timezone); `--` for a missing or invalid cron
/// expression; today 12:00 PM when nothing can be computed.
String getNextExecutionTime(Map<String, Object?> data, [ScheduleClock clock = const ScheduleClock()]) {
  final timezone = _resolveTimezone(data['timezone'], clock);
  if (data['mode'] == 'cron') {
    final cron = data['cron_expression'];
    if (cron is! String || cron.isEmpty || !isValidCronExpression(cron)) return '--';
  }
  final times = getNextExecutionTimes(data, 1, clock);
  final DateTime date;
  if (times.isEmpty) {
    final now = wallClockAt(timezone, clock.instant(), offset: clock.offset);
    date = DateTime.utc(now.year, now.month, now.day, 12);
  } else {
    date = times.first;
  }
  return formatUserTimezoneDate(date, timezone, includeWeekday: _includeWeekday(data), includeTimezone: false);
}
