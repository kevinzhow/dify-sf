// Checkpoint hand-in (docs/agent-v2.md, "Checkpoint hand-in"): a run of the
// official Codex runtime that fails after real work hands in the agent's last
// checkpoint; without a usable one it fails as before. Against the scripted
// app-server; the real binary is in checkpoint_binary_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/checkpoint.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart';
import 'retain_rig.dart';

const _schema = <String, Object?>{
  'type': 'object',
  'properties': {
    'notes': {'type': 'string'},
    'report': {
      'type': 'string',
      'x-dify-sf-file': {
        'extensions': ['csv'],
      },
    },
    partialHandinOutput: {'type': 'string'},
  },
  'required': ['notes', 'report'],
};

const _reportPath = '$checkpointDir/1/report.csv';

const _valid = <String, Object?>{
  'notes': 'the whole object, board 3',
  'report': _reportPath,
};

/// A checkpoint in the fake sandbox: [json] (default the valid one) and its
/// report file.
void _write(FakeCodexAppServer s, {Object? json, String? raw}) {
  s.sandbox.files
    ..['/workspace/$_reportPath'] = utf8.encode('a,b\n1,2\n')
    ..['/workspace/$checkpointFile'] = utf8.encode(
      raw ?? jsonEncode(json ?? _valid),
    );
}

Future<(Map<String, Object?>, List<String>)> _ran(
  FakeCodexAppServer fake, {
  Map<String, Object?>? schema = _schema,
  int maxTurns = 10,
  int timeoutSeconds = 30,
}) async {
  final (h, run, _) = await fake.startRun({
    ...officialCodexOp(
      outputSchema: schema,
      maxTurns: maxTurns,
      timeoutSeconds: timeoutSeconds,
    ),
    'tools': {'shell': true},
  });
  final status = await h.waitEnded(run, timeout: const Duration(seconds: 40));
  final names = [for (final e in await h.events(run)) e.event];
  return ((status['result'] as Map).cast<String, Object?>(), names);
}

void _expectHandedIn(
  Map<String, Object?> result,
  List<String> names,
  String reason, {
  int? notice,
  required int calls,
}) {
  expect(names.last, 'succeeded', reason: jsonEncode(result));
  expect(result['candidate_errors'], isEmpty);
  expect(result['partial'], {
    'reason': reason,
    'notice_call_index': notice,
    'handin': 'checkpoint',
    'call_index': calls,
  });
  final candidate = result['candidate'] as Map;
  expect(candidate['notes'], 'the whole object, board 3');
  final report = candidate['report'] as Map;
  expect(report['filename'], 'report.csv');
  expect(report['upload_id'], isA<String>());
  expect(report['size'], 8);
  expect(candidate[partialHandinOutput], startsWith('$reason: '));
  expect(
    candidate[partialHandinOutput],
    contains('at about model call $calls'),
  );
  final snapshot = result['snapshot'] as Map;
  expect((snapshot['codex'] as Map)['runtime'], 'official');
  expect(snapshot['checkpoint_handin'], result['partial']);
}

void main() {
  group('a failure after real work hands in the checkpoint', () {
    test('upstream disconnect or recovery refused (model_error)', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s
            ..usage()
            ..usage();
          _write(s);
          s.fail(
            'responseStreamDisconnected',
            'stream disconnected: agent_recovery_tool_result_unknown at '
                'http://gateway.internal/secret-path',
          );
        },
      );
      final (result, names) = await _ran(fake);
      _expectHandedIn(result, names, 'model_error', calls: 2);
      // The raw error stays in the service log: a hand-in's text is public.
      expect(jsonEncode(result), isNot(contains('gateway.internal')));
      expect(jsonEncode(result), isNot(contains('agent_recovery')));
    });

    test('max_turns, with the notice that came before', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          for (var i = 0; i < 3; i++) {
            s.usage();
          }
          _write(s);
          s.fail(
            'usageLimitExceeded',
            'You’ve hit your usage limit. dify-sf-agent-call-limit',
          );
        },
      );
      final (result, names) = await _ran(fake, maxTurns: 3);
      _expectHandedIn(result, names, 'max_turns', notice: 2, calls: 3);
      expect(names, contains('budget_notice'));
    });

    test('a value of the output in the file is replaced', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s.usage();
          _write(s, json: {..._valid, partialHandinOutput: 'all fine'});
          s.fail('other', 'stream disconnected');
        },
      );
      final (result, names) = await _ran(fake);
      _expectHandedIn(result, names, 'model_error', calls: 1);
    });

    test('Codex dies mid-turn (sandbox_error)', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s.usage();
          _write(s);
          await s.exit(exitCode: 137, output: 'killed\n');
        },
      );
      final (result, names) = await _ran(fake);
      _expectHandedIn(result, names, 'sandbox_error', calls: 1);
    });

    test('timeout: it stops early enough for the gateway to take the files, '
        'with Codex interrupted first', () async {
      checkpointReserveForTests = 4;
      addTearDown(() => checkpointReserveForTests = null);
      final watch = Stopwatch()..start();
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s.usage();
          _write(s); // The turn never ends by itself.
        },
      );
      final (result, names) = await _ran(fake, timeoutSeconds: 5);
      _expectHandedIn(result, names, 'timeout', calls: 1);
      expect(watch.elapsedMilliseconds, lessThan(5000));
      expect(fake.methods, contains('turn/interrupt'));
    });

    test('without the optional output the result is only marked in partial '
        '(a schema that does not declare it)', () async {
      final schema = {
        ..._schema,
        'properties': {...(_schema['properties'] as Map)}
          ..remove(partialHandinOutput),
      };
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s.usage();
          _write(s);
          s.fail('other', 'boom');
        },
      );
      final (result, names) = await _ran(fake, schema: schema);
      expect(names.last, 'succeeded');
      expect((result['partial'] as Map)['handin'], 'checkpoint');
      expect(result['candidate'] as Map, isNot(contains(partialHandinOutput)));
    });
  });

  group('no usable checkpoint: the failure stays what it was', () {
    test('no checkpoint', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s.usage();
          s.fail('other', 'stream disconnected');
        },
      );
      final (result, names) = await _ran(fake);
      expect(names.last, 'failed');
      expect(result['error_type'], 'model_error');
      expect(result['message'], 'Codex: stream disconnected ("other")');
      expect(result, isNot(contains('partial')));
    });

    test('max_turns with no checkpoint', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          for (var i = 0; i < 3; i++) {
            s.usage();
          }
          s.fail(
            'usageLimitExceeded',
            'You’ve hit your usage limit. dify-sf-agent-call-limit',
          );
        },
      );
      final (result, names) = await _ran(fake, maxTurns: 3);
      expect(names.last, 'failed');
      expect(result['error_type'], 'max_turns');
      expect(result['message'], isNot(contains('no hand-in')));
    });

    test('timeout with no checkpoint runs to the limit', () async {
      final watch = Stopwatch()..start();
      final fake = FakeCodexAppServer(turn: (s) async => s.usage());
      final (result, names) = await _ran(fake, timeoutSeconds: 2);
      expect(names.last, 'failed');
      expect(result['error_type'], 'timeout');
      expect(result['message'], 'the run exceeded 2 seconds');
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(2000));
    });

    final bad = <String, void Function(FakeCodexAppServer)>{
      'not JSON': (s) => _write(s, raw: '{"notes": '),
      'not an object': (s) => _write(s, raw: '[1]'),
      'a schema violation': (s) => _write(s, json: {'notes': 1, 'report': 'x'}),
      'a required output missing': (s) => _write(s, json: {'notes': 'n'}),
      'a file that is not there': (s) {
        _write(s, json: {'notes': 'n', 'report': 'out/gone.csv'});
      },
      'a file with another extension': (s) {
        s.sandbox.files['/workspace/out/report.txt'] = [1];
        _write(s, json: {'notes': 'n', 'report': 'out/report.txt'});
      },
      'a file outside the workspace': (s) {
        _write(s, json: {'notes': 'n', 'report': '../etc/passwd'});
      },
      'more than the limit': (s) {
        s.sandbox.files['/workspace/$checkpointFile'] = List.filled(
          checkpointMaxBytes + 1,
          32,
        );
      },
    };
    for (final MapEntry(key: what, value: write) in bad.entries) {
      test(what, () async {
        final fake = FakeCodexAppServer(
          turn: (s) async {
            s.usage();
            write(s);
            s.fail('other', 'stream disconnected');
          },
        );
        final (result, names) = await _ran(fake);
        expect(names.last, 'failed', reason: jsonEncode(result));
        expect(result['error_type'], 'model_error');
        expect(
          result['message'],
          startsWith('Codex: stream disconnected ("other"); no hand-in: '),
        );
      });
    }

    test('a run without declared outputs ignores the file', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          _write(s);
          s.fail('other', 'stream disconnected');
        },
      );
      final (result, names) = await _ran(fake, schema: null);
      expect(names.last, 'failed');
      expect(result['error_type'], 'model_error');
    });

    test('a cancel is a cancel', () async {
      final started = Completer<void>();
      final fake = FakeCodexAppServer(
        turn: (s) async {
          s.usage();
          _write(s);
          started.complete();
        },
      );
      final (h, run, _) = await fake.startRun({
        ...officialCodexOp(outputSchema: _schema),
        'tools': {'shell': true},
      });
      await started.future;
      final (code, _) = await h.post('/v1/runs/$run/cancel', {
        'protocol': protocolName,
        'generation': 1,
      });
      expect(code, 202);
      final status = await h.waitEnded(run);
      expect(status['status'], 'cancelled');
    });
  });

  group('a normal run is unchanged', () {
    test('the final answer wins over a checkpoint; the model neither sees nor '
        'sets the output', () async {
      final fake = FakeCodexAppServer(
        turn: (s) async {
          _write(s);
          s.sandbox.files['/workspace/out/final.csv'] = [65];
          s
            ..usage()
            ..message(
              jsonEncode({
                'notes': 'finished',
                'report': 'out/final.csv',
                partialHandinOutput: 'the model says so',
              }),
              phase: 'final_answer',
            )
            ..complete({'status': 'completed'});
        },
      );
      final (result, names) = await _ran(fake);
      expect(names.last, 'succeeded', reason: jsonEncode(result));
      expect(result['partial'], isNull);
      final candidate = result['candidate'] as Map;
      expect(candidate['notes'], 'finished');
      expect((candidate['report'] as Map)['filename'], 'final.csv');
      expect(candidate, isNot(contains(partialHandinOutput)));
      expect(result['snapshot'] as Map, isNot(contains('checkpoint_handin')));
      final sent = jsonEncode(fake.paramsOf('turn/start')['outputSchema']);
      expect(sent, contains('report'));
      expect(sent, isNot(contains(partialHandinOutput)));
    });

    test('modelFacingSchema of a schema without the output is what it was', () {
      const plain = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        'required': ['a'],
      };
      expect(modelFacingSchema(plain), plain);
      final declared = modelFacingSchema({
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          partialHandinOutput: {'type': 'string'},
        },
        'required': ['a', partialHandinOutput],
      });
      expect(declared, plain);
    });

    test('the reserve', () {
      expect(checkpointReserveSeconds(1), 1);
      expect(checkpointReserveSeconds(30), 3);
      expect(checkpointReserveSeconds(10800), 120);
    });
  });

  group('rounds', () {
    Map<String, Object?> op(
      String execution, {
      int attempt = 0,
      Map<String, Object?>? continuation,
    }) => {
      ...retainOp(
        executionId: execution,
        outputAttempt: attempt,
        continuation: continuation,
      ),
      'output_schema': _schema,
    };

    void localCheckpoint(LocalBox box) {
      Directory('${box.ws.path}/$checkpointDir/1').createSync(recursive: true);
      File('${box.ws.path}/$_reportPath').writeAsStringSync('a,b\n1,2\n');
      File('${box.ws.path}/$checkpointFile')
          .writeAsStringSync(jsonEncode(_valid));
    }

    Future<void> Function(FakeCodexAppServer) failingTurn(
      RetainRig rig, {
      bool checkpoint = true,
      bool rollout = true,
    }) => (s) async {
      final box = rig.box!;
      if (checkpoint) localCheckpoint(box);
      if (rollout) {
        final f = File('${box.local(s.codexHome)}/$rolloutRel');
        if (!f.existsSync()) {
          f
            ..createSync(recursive: true)
            ..writeAsStringSync(sessionMetaLine(const ['report_progress']));
        }
        f.writeAsStringSync('{"type":"turn"}\n', mode: FileMode.append);
      }
      s
        ..usage()
        ..fail('other', 'stream disconnected');
    };

    test('a hand-in keeps the session: the next round resumes it, and its '
        'CODEX_HOME is gone before the result', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: failingTurn(rig)),
        op('E1'),
      );
      final r1 = await rig.result(run1);
      expect(r1['session'], {
        'saved': true,
        'thread_id': thread,
        'turns': 1,
      }, reason: jsonEncode(r1));
      expect((r1['partial'] as Map)['reason'], 'model_error');
      expect(rig.homeRemovedBeforeResult, isNotEmpty);
      expect(rig.homeRemovedBeforeResult, everyElement(isTrue));
      expect(rig.record!.session!.turns, 1);
      await rig.deleteExecution('E1');

      final fake2 = FakeCodexAppServer(turn: codexTurn(rig, answer: '{}'));
      final run2 = await rig.round(fake2, op('E2'));
      await rig.result(run2);
      expect(fake2.methods, contains('thread/resume'));
    });

    test('a hand-in whose rollout cannot be saved changes nothing: the next '
        'round starts a new thread instead of failing', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: failingTurn(rig, rollout: false)),
        op('E1'),
      );
      final r1 = await rig.result(run1);
      expect((r1['partial'] as Map)['reason'], 'model_error');
      expect((r1['session'] as Map)['saved'], isFalse);
      expect(rig.record!.sessionState, SessionState.none);
      await rig.deleteExecution('E1');

      final fake2 = FakeCodexAppServer(turn: codexTurn(rig, answer: '{}'));
      final run2 = await rig.round(fake2, op('E2'));
      await rig.result(run2);
      expect(fake2.methods, contains('thread/start'));
    });

    test('an earlier round\'s checkpoint is cleared: a failure with none of '
        'its own stays a failure', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: failingTurn(rig)),
        op('E1'),
      );
      expect((await rig.result(run1))['partial'], isNotNull);
      await rig.deleteExecution('E1');
      expect(
        File('${rig.nodeWorkspace.path}/$checkpointFile').existsSync(),
        isTrue,
      );

      final run2 = await rig.round(
        FakeCodexAppServer(turn: failingTurn(rig, checkpoint: false)),
        op('E2'),
      );
      final r2 = await rig.result(run2);
      expect(r2['error_type'], 'model_error', reason: jsonEncode(r2));
      expect(
        Directory('${rig.nodeWorkspace.path}/$checkpointDir').existsSync(),
        isFalse,
      );
    });

    test('an output retry of a hand-in keeps the checkpoint and stays marked '
        'as incomplete', () async {
      final rig = await RetainRig.start();
      final run1 = await rig.round(
        FakeCodexAppServer(turn: failingTurn(rig)),
        op('E1'),
      );
      final r1 = await rig.result(run1);
      final partial = r1['partial'];

      final retry = {
        'kind': 'output_retry',
        'snapshot': r1['snapshot'],
        'feedback': [
          {'field': 'report', 'error': 'unavailable'},
        ],
      };
      final fake2 = FakeCodexAppServer(
        turn: (s) async {
          File('${rig.box!.ws.path}/$checkpointDir/r.csv')
              .writeAsStringSync('x');
          s
            ..usage()
            ..message(
              jsonEncode({'notes': 'again', 'report': '$checkpointDir/r.csv'}),
              phase: 'final_answer',
            )
            ..complete({'status': 'completed'});
        },
      );
      final run2 = await rig.round(
        fake2,
        op('E1', attempt: 1, continuation: retry),
      );
      final r2 = await rig.result(run2);
      expect(r2['partial'], partial, reason: jsonEncode(r2));
      final candidate = r2['candidate'] as Map;
      expect(candidate['notes'], 'again');
      expect(candidate[partialHandinOutput], startsWith('model_error: '));
      expect(r2['snapshot'] as Map, contains('checkpoint_handin'));
    });
  });
}
