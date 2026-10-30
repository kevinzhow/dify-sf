// The loop helper's own Python (loopHelperScript) against a simulated loop
// device (test/loop_helper/kernel_sim.py): placeholder swaps, a slow
// release, a run-down device and another binder taking the device at each
// step. Needs python3 on the host (the helper itself runs in the tool
// image); skipped without it.
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/supervisor.dart';
import 'package:test/test.dart';

void main() {
  final python = Process.runSync('sh', [
    '-c',
    'command -v python3',
  ]).stdout.toString().trim();
  late Directory dir;
  late String script;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('loop-helper-');
    script = '${dir.path}/helper.py';
    File(script).writeAsStringSync(loopHelperScript);
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  Map<String, Object?> run(Map<String, Object?> scenario) {
    final r = Process.runSync(python, [
      '-I',
      'test/loop_helper/kernel_sim.py',
      script,
      jsonEncode(scenario),
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return jsonDecode((r.stdout as String).trim().split('\n').last)
        as Map<String, Object?>;
  }

  final skip = python.isEmpty ? 'python3 is not installed' : false;

  test('prepare swaps the placeholder for the written image', skip: skip, () {
    final r = run({'op': 'prepare', 'start': 'hold'});
    expect(r['answer'], {'state': 'attached', 'dev': 1, 'ino': 2});
    expect((r['binding'], r['formats']), ('image', 1));
  });

  for (final when in ['steal_before_bind', 'steal_after_clear']) {
    test(
      'a device taken during the swap ($when) is busy, lost_hold, and '
      'says the image is written',
      skip: skip,
      () {
        final r = run({'op': 'prepare', 'start': 'hold', when: true});
        expect(r['exit'], 3);
        expect(r['answer'], {
          'state': 'busy',
          'holder': 'example_1.snap',
          'lost_hold': true,
          'formatted': true,
        });
        expect((r['binding'], r['formats']), ('foreign', 1));
        // The next device attaches the written image.
        final next = run({'op': 'attach', 'start': 'hold', 'size': 128 << 20});
        expect(next['answer'], {'state': 'attached', 'dev': 1, 'ino': 2});
      },
    );
  }

  test(
    'a cleared binding that another opener keeps is waited for without '
    'holding the device open',
    skip: skip,
    () {
      final r = run({
        'op': 'attach',
        'start': 'hold',
        'size': 1,
        'other_opener': 5,
      });
      expect(r['answer'], {'state': 'attached', 'dev': 1, 'ino': 2});
      expect(r['sleeps'], 5);
    },
  );

  for (final openable in [false, true]) {
    test(
      'a device running down (open ${openable ? 'allowed' : 'ENXIO'}) is '
      'waited for',
      skip: skip,
      () {
        final r = run({
          'op': 'attach',
          'start': 'hold',
          'size': 1,
          'udev_after_clear': 4,
          'open_in_rundown': openable,
        });
        expect(r['answer'], {'state': 'attached', 'dev': 1, 'ino': 2});
      },
    );
  }

  test('a binding that never goes away ends in clear_timeout', skip: skip, () {
    final r = run({
      'op': 'attach',
      'start': 'hold',
      'size': 1,
      'other_opener': -1,
    });
    expect(r['exit'], 7);
    expect(r['answer'], {'state': 'clear_timeout'});
    expect(r['elapsed'] as num, inInclusiveRange(4.9, 5.05));
  });

  test(
    're-opens refused and then the old binding again share one 5 s '
    'budget',
    skip: skip,
    () {
      for (final op in ['attach', 'detach']) {
        final r = run({
          'op': op,
          'start': op == 'attach' ? 'hold' : 'image',
          'size': 1,
          'other_opener': -1,
          'enxio_opens': 120,
        });
        expect(r['exit'], 7, reason: op);
        expect(r['answer'], {'state': 'clear_timeout'});
        expect(r['elapsed'] as num, inInclusiveRange(4.9, 5.05), reason: op);
      }
    },
  );

  test(
    'detach binds the placeholder again unless another binder was '
    'faster',
    skip: skip,
    () {
      expect(run({'op': 'detach', 'start': 'image', 'size': 1})['answer'], {
        'state': 'detached',
        'held': true,
      });
      final r = run({
        'op': 'detach',
        'start': 'image',
        'size': 1,
        'steal_after_clear': true,
      });
      expect(r['answer'], {'state': 'detached', 'held': false});
      expect(r['binding'], 'foreign');
    },
  );

  test('hold, unhold and another binder', skip: skip, () {
    expect(run({'op': 'hold', 'start': null})['binding'], 'hold');
    final other = run({'op': 'hold', 'start': 'foreign'});
    expect(other['exit'], 3);
    expect(other['answer'], {'state': 'other', 'holder': 'example_1.snap'});
    final busy = run({'op': 'prepare', 'start': 'foreign'});
    expect(busy['exit'], 3);
    // Refused before anything is written: the next device prepares.
    expect(busy['answer'], {'state': 'busy', 'holder': 'example_1.snap'});
    expect(busy['formats'], 0);
    final freed = run({'op': 'unhold', 'start': 'hold'});
    expect(freed['answer'], {'state': 'free'});
    expect(freed['binding'], isNull);
  });
}
