// Polish after batch 4 (item 6): `formatTimeFromNow` (dayjs `fromNow`, used by the publisher, the header's titles,
// version history, comments and members) reads a time up to a minute ahead of the device's clock (the server's clock
// ahead of it) as now, "a few seconds ago" (dayjs's words for now; Dify has no "just now" string of its own); a time
// meant to lie ahead (a form's expiry) keeps dayjs's "in …".
import 'package:dify_sf_app/src/workflow_editor/header/format.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart' show getRelativeTime;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 3, 12);
  int at(Duration d) => now.add(d).millisecondsSinceEpoch;

  test('the past is dayjs\'s: a few seconds ago, a minute ago, 5 minutes ago', () {
    expect(formatTimeFromNow(at(Duration.zero), now: now), 'a few seconds ago');
    expect(formatTimeFromNow(at(const Duration(seconds: -30)), now: now), 'a few seconds ago');
    expect(formatTimeFromNow(at(const Duration(seconds: -60)), now: now), 'a minute ago');
    expect(formatTimeFromNow(at(const Duration(minutes: -5)), now: now), '5 minutes ago');
  });

  test('up to a minute ahead (the server\'s clock ahead of the device\'s) is now: "a few seconds ago"', () {
    for (final s in [1, 20, 44, 45, 59, 60]) {
      expect(
        formatTimeFromNow(at(Duration(seconds: s)), now: now),
        'a few seconds ago',
        reason: '$s s ahead',
      );
    }
  });

  test('further ahead keeps dayjs\'s future: in 2 minutes, in an hour', () {
    expect(formatTimeFromNow(at(const Duration(seconds: 61)), now: now), 'in a minute');
    expect(formatTimeFromNow(at(const Duration(minutes: 2)), now: now), 'in 2 minutes');
    expect(formatTimeFromNow(at(const Duration(hours: 1)), now: now), 'in an hour');
  });

  test('a time meant to lie ahead (a human input form\'s expiry) keeps "in a few seconds"', () {
    expect(formatTimeFromNow(at(const Duration(seconds: 20)), now: now, happened: false), 'in a few seconds');
    final soon = DateTime.now().add(const Duration(seconds: 20)).millisecondsSinceEpoch;
    expect(getRelativeTime(soon), 'in a few seconds');
  });
}
