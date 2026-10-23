/// Seeded randomized simulation: several clients make random edits through an unreliable network while
/// crashing and reconnecting; afterwards every invariant must hold. Reproduce a failure with
/// `SIM_SEED=<n> SIM_PROFILE=<name> dart test test/random_test.dart`.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/sim.dart';

void main() {
  final runs = int.tryParse(Platform.environment['SIM_RUNS'] ?? '') ?? 40;
  final only = int.tryParse(Platform.environment['SIM_SEED'] ?? '');
  final onlyProfile = Platform.environment['SIM_PROFILE'];

  final total = SimStats();
  for (final profile in Profile.values) {
    if (onlyProfile != null && onlyProfile != profile.name) continue;
    test('profile ${profile.name}: $runs seeded runs hold all invariants', () {
      final stats = SimStats();
      for (var seed = 1; seed <= runs; seed++) {
        if (only != null && seed != only) continue;
        stats.add(runSim(seed, profile));
      }
      total.add(stats);
      printOnFailure('${profile.name}: $stats');
      // ignore: avoid_print
      print('${profile.name}: $stats');
    });
  }

  tearDownAll(() {
    // ignore: avoid_print
    print('TOTAL: $total');
  });
}
