/// Timezones as the schedule trigger needs them: the UTC offset label (date-and-time-picker/utils/dayjs.ts
/// convertTimezoneToOffsetStr), whether a name is a timezone (`Intl.DateTimeFormat` accepting it) and the wall-clock
/// time in a timezone.
///
/// Dart has no IANA database, so the offsets are the standard ones of Dify's timezone list (timezones.g.dart) plus
/// the daylight-saving rules of the US / Canada, the EU / UK, south-east Australia and New Zealand. A host with a
/// full database passes its own [TimezoneOffset] (see ScheduleHost).
library;

import 'timezones.g.dart';

/// The offset (minutes east of UTC) of [timezone] at the instant [utc].
typedef TimezoneOffset = int Function(String timezone, DateTime utc);

const _utcNames = {'UTC', 'Etc/UTC', 'GMT', 'Etc/GMT', 'Etc/Universal', 'Etc/Zulu', 'Universal', 'Zulu', 'UCT'};
final _etcGmt = RegExp(r'^Etc/GMT([+-])(\d{1,2})$');

const _usRules = {
  'America/Adak', 'America/Anchorage', 'America/Los_Angeles', 'America/Tijuana', 'America/Vancouver', //
  'America/Edmonton', 'America/Ciudad_Juarez', 'America/Denver', 'America/Chicago', 'America/Matamoros',
  'America/Winnipeg', 'America/Grand_Turk', 'America/Nassau', 'America/New_York', 'America/Port-au-Prince',
  'America/Toronto', 'America/Halifax', 'Atlantic/Bermuda', 'America/Thule', 'America/St_Johns', 'America/Miquelon',
};
const _noEuRules = {
  'Europe/Istanbul', 'Europe/Minsk', 'Europe/Moscow', 'Europe/Simferopol', 'Europe/Kaliningrad', 'Europe/Samara', //
};
const _euRulesOutsideEurope = {'Atlantic/Azores', 'Atlantic/Canary', 'Atlantic/Faroe', 'Asia/Beirut'};
const _auRules = {'Australia/Adelaide', 'Australia/Sydney', 'Australia/Melbourne', 'Australia/Hobart'};

/// Whether `new Intl.DateTimeFormat(undefined, { timeZone })` would accept [timezone]: a zone of Dify's list, UTC
/// and its aliases, or `Etc/GMT±h`.
bool isKnownTimezone(String timezone) =>
    timezoneStandardOffsets.containsKey(timezone) || _utcNames.contains(timezone) || _etcGmt.hasMatch(timezone);

/// The `n`-th (1-based; -1: last) Sunday of [month] in [year], as a day of the month.
int _sunday(int year, int month, int n) {
  if (n < 0) {
    final last = DateTime.utc(year, month + 1, 0);
    return last.day - last.weekday % 7;
  }
  final first = DateTime.utc(year, month);
  return 1 + (7 - first.weekday % 7) % 7 + (n - 1) * 7;
}

/// The built-in [TimezoneOffset]: standard offset plus an hour while daylight saving time is on.
int defaultTimezoneOffset(String timezone, DateTime utc) {
  if (_utcNames.contains(timezone)) return 0;
  final etc = _etcGmt.firstMatch(timezone);
  // POSIX sign: Etc/GMT+5 is five hours behind UTC.
  if (etc != null) return (etc[1] == '+' ? -1 : 1) * int.parse(etc[2]!) * 60;
  final std = timezoneStandardOffsets[timezone];
  if (std == null) return 0;
  final u = utc.toUtc();
  final y = u.year;
  DateTime at(int month, int day, int hour) => DateTime.utc(y, month, day, hour);
  bool between(DateTime start, DateTime end) => !u.isBefore(start) && u.isBefore(end);
  final bool dst;
  if (_usRules.contains(timezone)) {
    // 2nd Sunday of March 2:00 standard time to the 1st Sunday of November 2:00 daylight time.
    dst = between(
      at(3, _sunday(y, 3, 2), 2).subtract(Duration(minutes: std)),
      at(11, _sunday(y, 11, 1), 1).subtract(Duration(minutes: std)),
    );
  } else if ((timezone.startsWith('Europe/') && !_noEuRules.contains(timezone)) ||
      _euRulesOutsideEurope.contains(timezone)) {
    // Last Sunday of March to the last Sunday of October, 1:00 UTC.
    dst = between(at(3, _sunday(y, 3, -1), 1), at(10, _sunday(y, 10, -1), 1));
  } else if (_auRules.contains(timezone)) {
    // 1st Sunday of October 2:00 standard time to the 1st Sunday of April 3:00 daylight time.
    dst = !between(
      at(4, _sunday(y, 4, 1), 2).subtract(Duration(minutes: std)),
      at(10, _sunday(y, 10, 1), 2).subtract(Duration(minutes: std)),
    );
  } else if (timezone == 'Pacific/Auckland') {
    // Last Sunday of September 2:00 standard time to the 1st Sunday of April 3:00 daylight time.
    dst = !between(
      at(4, _sunday(y, 4, 1), 2).subtract(Duration(minutes: std)),
      at(9, _sunday(y, 9, -1), 2).subtract(Duration(minutes: std)),
    );
  } else {
    dst = false;
  }
  return std + (dst ? 60 : 0);
}

/// The wall-clock time in [timezone] at the instant [utc], held in a UTC [DateTime] (Dify's "user timezone
/// representation": a Date whose fields read as that timezone's clock).
DateTime wallClockAt(String timezone, DateTime utc, {TimezoneOffset offset = defaultTimezoneOffset}) {
  final u = utc.toUtc();
  final w = u.add(Duration(minutes: offset(timezone, u)));
  return DateTime.utc(w.year, w.month, w.day, w.hour, w.minute, w.second);
}

/// convertTimezoneToOffsetStr: `UTC+8`, `UTC-3:30`, `UTC+0`, from the timezone list's standard offset (`UTC+0` for
/// a name the list lacks, UTC included).
String convertTimezoneToOffsetStr(String? timezone) {
  final minutes = timezone == null ? null : timezoneStandardOffsets[timezone];
  if (minutes == null) return 'UTC+0';
  // Dify parses "-03:30" as hours -3 and minutes 30.
  final hours = minutes ~/ 60;
  final rest = minutes.abs() % 60;
  final sign = minutes >= 0 ? '+' : (hours == 0 ? '-' : '');
  final h = '$sign$hours';
  return rest != 0 ? 'UTC$h:${rest.toString().padLeft(2, '0')}' : 'UTC$h';
}
