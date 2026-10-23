/// Times in the account's time zone: Dify's `useTimestamp` (web/hooks/use-timestamp.ts). Dify formats every console time
/// (logs, annotations, API keys, ...) with `dayjs.unix(value).tz(timezone)`, where the zone is the account's
/// (`userProfile.timezone`, set in Preferences) or else the browser's. [AccountTime.of] is that hook.
library;

import 'package:flutter/widgets.dart';

import '../local_timezone.dart';
import '../timezone_offset.dart';
import '../workflow_editor/header/format.dart' show formatDateFields;
import '../workflow_editor/node_panel/bodies/entry/trigger_schedule/schedule_timezone.dart'
    show defaultTimezoneOffset, isKnownTimezone;
import 'auth_controller.dart';

/// The signed-in account's time zone (`userProfile.timezone`), subscribing [context] to account changes; null when
/// there is none (or nobody is signed in).
String? accountTimezone(BuildContext context) {
  final tz = AuthScope.maybeOf(context)?.account?.timezone;
  return tz == null || tz.isEmpty ? null : tz;
}

/// The clock of one time zone ([timezone]; null: the system's own, Dify's browser zone).
@immutable
class AccountTime {
  const AccountTime(this.timezone);

  /// `useTimestamp()`: the account's time zone, else the system's. Rebuilds [context] when the account's zone changes.
  factory AccountTime.of(BuildContext context) => AccountTime(accountTimezone(context));

  /// The same without subscribing (for callbacks).
  factory AccountTime.read(BuildContext context) {
    final tz = AuthScope.read(context)?.account?.timezone;
    return AccountTime(tz == null || tz.isEmpty ? null : tz);
  }

  /// An IANA name, or null for the system's zone.
  final String? timezone;

  /// Whether times read like the system's local time (no zone, the system's own, or a name nobody knows).
  bool get isLocal {
    final tz = timezone;
    if (tz == null) return true;
    return _local.putIfAbsent(
      tz,
      () =>
          tz == _systemTimezone || (!isKnownTimezone(tz) && platformTimezoneOffset(tz, DateTime.now().toUtc()) == null),
    );
  }

  static final _local = <String, bool>{};
  static final String? _systemTimezone = localTimezone();

  /// Minutes east of UTC at [instant]: the platform's database (browsers), else Dify's standard offsets with the common
  /// daylight-saving rules (`defaultTimezoneOffset`), else the system's own offset.
  int offsetAt(DateTime instant) {
    final tz = timezone;
    if (tz == null || isLocal) return instant.toLocal().timeZoneOffset.inMinutes;
    final utc = instant.toUtc();
    return platformTimezoneOffset(tz, utc) ?? defaultTimezoneOffset(tz, utc);
  }

  /// [instant] as the zone's wall clock: a [DateTime] whose fields read as that clock (local for the system's zone, else
  /// a UTC [DateTime] shifted by the offset).
  DateTime wallClock(DateTime instant) {
    if (isLocal) return instant.toLocal();
    final utc = instant.toUtc();
    return utc.add(Duration(minutes: offsetAt(utc)));
  }

  /// `formatTime(seconds, format)`: a Unix time in seconds as the zone's clock, in a dayjs [format] (`YYYY`, `MM`, `DD`,
  /// `HH`, `hh`, `mm`, `ss`, `A`).
  String formatTime(int seconds, String format) =>
      formatDateFields(wallClock(DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)), format);

  /// The start of the zone's day [days] days before [now], as an instant (`dayjs().tz().subtract(days, 'day')
  /// .startOf('day')`): for date-range queries in the account's zone.
  DateTime startOfDay(DateTime now, {int days = 0}) {
    if (isLocal) {
      final l = now.toLocal();
      return DateTime(l.year, l.month, l.day - days);
    }
    final w = wallClock(now);
    final wallStart = DateTime.utc(w.year, w.month, w.day - days);
    // The offset at the start of that day (one correction step covers a daylight-saving change in between).
    var instant = wallStart.subtract(Duration(minutes: offsetAt(wallStart)));
    instant = wallStart.subtract(Duration(minutes: offsetAt(instant)));
    return instant;
  }

  @override
  bool operator ==(Object other) => other is AccountTime && other.timezone == timezone;

  @override
  int get hashCode => timezone.hashCode;

  @override
  String toString() => 'AccountTime(${timezone ?? 'local'})';
}
