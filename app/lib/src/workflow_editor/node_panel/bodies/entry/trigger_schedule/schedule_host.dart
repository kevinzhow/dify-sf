/// What the schedule trigger's panel takes from the host app: the account's timezone (Dify's user profile) and the
/// clock / timezone rules (tests pin the time; a host with an IANA database passes its offsets).
library;

import 'package:flutter/widgets.dart';

import 'execution_time_calculator.dart';

class ScheduleHost extends InheritedWidget {
  const ScheduleHost({super.key, this.profileTimezone, this.clock = const ScheduleClock(), required super.child});

  /// `userProfile.timezone`; null: none (the panel then uses UTC, as Dify does).
  final String? profileTimezone;
  final ScheduleClock clock;

  static const _none = ScheduleHost(child: SizedBox.shrink());

  /// The nearest host, or one with no profile timezone and the real clock.
  static ScheduleHost of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ScheduleHost>() ?? _none;

  @override
  bool updateShouldNotify(ScheduleHost old) => old.profileTimezone != profileTimezone || old.clock != clock;
}
