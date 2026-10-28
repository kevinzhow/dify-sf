// The official Codex runtime against a scripted app-server (see
// codex_app_server_fake.dart): the run's JSON-RPC exchange with Codex and how
// Codex's notifications become events and the run's result. The real binary
// is covered by tool/codex_e2e.sh.
import 'dart:convert';

import 'package:test/test.dart';

import 'codex_app_server_fake.dart';

void main() {
  Future<(Map<String, Object?>, List<String>, List<Map<String, Object?>>)> ran(
    FakeCodexAppServer fake, {
    Map<String, Object?>? op,
  }) async {
    final (h, run, _) = await fake.startRun(op ?? officialCodexOp());
    final status = await h.waitEnded(run);
    final events = await h.events(run);
    return (
      (status['result'] as Map).cast<String, Object?>(),
      [for (final e in events) e.event],
      [for (final e in events) e.data],
    );
  }

  group('final answer', () {
    for (final phase in [null, 'partial_answer']) {
      test('a last message with phase $phase is the final answer', () async {
        final fake = FakeCodexAppServer(
          turn: (s) async {
            s
              ..message('Looking first.', phase: phase, id: 'm1')
              ..item('started', {
                'type': 'commandExecution',
                'id': 'c1',
                'command': 'ls',
                'cwd': '/workspace',
              })
              ..item('completed', {
                'type': 'commandExecution',
                'id': 'c1',
                'command': 'ls',
                'cwd': '/workspace',
                'status': 'completed',
                'exitCode': 0,
                'aggregatedOutput': 'a\n',
              })
              ..usage()
              ..message('All done.', phase: phase, id: 'm2')
              ..usage()
              ..complete({'status': 'completed'});
          },
        );
        final (result, names, data) = await ran(fake);
        expect(names.last, 'succeeded', reason: jsonEncode(result));
        expect(result['candidate'], {'text': 'All done.'});
        // The first one, followed by a tool call, is commentary.
        final commentary = [
          for (var i = 0; i < names.length; i++)
            if (names[i] == 'commentary') data[i]['text'],
        ];
        expect(commentary, ['Looking first.']);
        expect(
          ((result['snapshot'] as Map)['codex'] as Map)['final_answer'],
          'All done.',
        );
      });
    }

    test('final_answer wins over a later unphased message', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s
            ..message('The answer.', phase: 'final_answer', id: 'm1')
            ..message('trailing remark', id: 'm2')
            ..complete({'status': 'completed'});
        },
      );
      final (result, _, _) = await ran(fake);
      expect(result['candidate'], {'text': 'The answer.'});
    });
  });
}
