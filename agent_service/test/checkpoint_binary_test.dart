// Checkpoint hand-in (docs/agent-v2.md) with the real Codex binary and a fake
// upstream, no model:
//
//   DIFYSF_CODEX_BIN=/path/to/codex-0.163.0 dart test test/checkpoint_binary_test.dart
//
// The rig is codex_retain_binary_test.dart's: the fake supervisor's sandbox
// runs everything for real in a local directory, `codex app-server` is a
// local process and the scripted gateway is Codex's Responses entry. In each
// run the first model call makes Codex run a command in the workspace (the
// agent's work); then:
// - the upstream stream ends without a response, again and again: Codex's
//   retries run out, the turn fails: with a checkpoint the run hands it in,
//   and the next round resumes the same thread with that work in its history;
//   without one it fails model_error;
// - the gateway refuses the next call (its call limit): max_turns, the same;
// - the model answers: a normal run, whatever the workspace holds.
// DIFYSF_CODEX_EVIDENCE=DIR keeps results, requests and Codex's log there.
// DIFYSF_CHECKPOINT_PROOF=DIR (holding schema.json and checkpoint/, a checkpoint
// made by a workflow's own tool) also runs both failures on that checkpoint with
// that output schema and writes result-<reason>.json next to them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/checkpoint.dart';
import 'package:agent_service/src/harness/codex/official.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart' show officialCodexOp;
import 'support.dart';

final _binary = Platform.environment['DIFYSF_CODEX_BIN'];
final _skip = _binary == null
    ? 'set DIFYSF_CODEX_BIN to the Codex binary'
    : false;

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

/// What the agent's command leaves in the workspace, in the order the contract
/// asks for: the files first, then the JSON by rename.
const _checkpointCommand =
    'mkdir -p $checkpointDir/1 && printf "a,b\\n1,2\\n" > '
    '$checkpointDir/1/report.csv && printf \'%s\' '
    '\'{"notes":"board 3","report":"$checkpointDir/1/report.csv"}\' > '
    '$checkpointFile.part && mv $checkpointFile.part $checkpointFile';

ScriptedCall _exec(String command) => ScriptedCall.responses([
  {
    'type': 'function_call',
    'id': 'fc_work',
    'call_id': 'call_work',
    'name': 'exec_command',
    'arguments': jsonEncode({'cmd': command}),
    'status': 'completed',
  },
]);

Map<String, Object?> _message(String text) => {
  'type': 'message',
  'role': 'assistant',
  'id': 'msg_${text.hashCode}',
  'phase': 'final_answer',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
};

/// An upstream stream that ends without `response.completed` (the EOF of an
/// upstream disconnect), as often as Codex retries.
final _disconnects = [
  for (var i = 0; i < 12; i++)
    ScriptedCall(
      responseEvents: [
        {
          'type': 'response.created',
          'response': {'id': 'resp_cut_$i'},
        },
      ],
    ),
];

class _Rig {
  _Rig._(this.work, this.home, this.ws, this.h, this.sup, this.log);

  final Directory work;
  final Directory home;
  final Directory ws;
  final Harness h;
  final FakeSupervisor sup;
  final IOSink log;
  final List<Process> processes = [];

  static Future<_Rig> start(List<ScriptedCall> calls, {int? callLimit}) async {
    final work = Directory(newDataDir().resolveSymbolicLinksSync());
    final home = Directory('${work.path}/home')..createSync();
    final ws = Directory('${work.path}/ws')..createSync();
    final log = IOSink(File('${work.path}/codex.log').openWrite());
    late _Rig rig;
    Future<(int, String)> local(String script, Map<String, String>? env) =>
        Process.run(
          'bash',
          ['-c', script.replaceAll(officialCodexBinary, _binary!)],
          workingDirectory: ws.path,
          environment: {...Platform.environment, ...?env},
        ).then((r) => (r.exitCode, '${r.stdout}${r.stderr}'));
    final sup = FakeSupervisor(
      key: testSupervisorKey,
      configure: (s) {
        s.onControl = (script) async =>
            script.contains('write_outside_workspace=') ||
                script.contains('reap=ok')
            ? null
            : await local(script, {'HOME': home.path});
        s.onJob = (script) {
          final job = s.jobs.values.lastWhere((j) => j.script == script);
          final cmd = script.replaceAll(officialCodexBinary, _binary!);
          if (script.contains('app-server --listen')) {
            unawaited(
              Process.start(
                'bash',
                ['-c', cmd],
                workingDirectory: ws.path,
                environment: {...Platform.environment, ...?job.env},
              ).then((p) {
                rig.processes.add(p);
                p.stdout.listen(log.add);
                p.stderr.listen(log.add);
              }),
            );
            return FakeJobSpec(running: true);
          }
          final r = Process.runSync(
            'bash',
            ['-c', cmd],
            workingDirectory: ws.path,
            environment: {...Platform.environment, ...?job.env},
          );
          return FakeJobSpec(output: '${r.stdout}', exitCode: r.exitCode);
        };
      },
    );
    final profiles = ExecutorProfiles.parse({
      'version': 1,
      'profiles': {
        'default': {
          'image':
              'dify-sf/sandbox@sha256:'
              '1111111111111111111111111111111111111111111111111111111111111111',
          'mounts': [
            {'source': '/srv/codex', 'target': '/opt/codex'},
          ],
          'workspace': {'backing': 'disk'},
        },
      },
    });
    sup.profiles = {
      for (final p in profiles.profiles.values)
        p.name: {'status': 'ok', 'digest': p.digest},
    };
    await sup.start();
    final h = await Harness.start(
      calls: calls,
      supervisorUrl: sup.url,
      profiles: profiles,
      codexRuntime: CodexRuntime.official,
      sandboxLayout: SandboxLayout(homeDir: home.path, workspaceDir: ws.path),
    );
    h.gateway.codexCallLimit = callLimit;
    sup.codexGatewayUrl = '${h.gateway.url.resolve('/inner/agent/codex/v1')}';
    rig = _Rig._(work, home, ws, h, sup, log);
    addTearDown(rig.close);
    return rig;
  }

  Future<void> close() async {
    for (final p in processes) {
      p.kill(ProcessSignal.sigkill);
    }
    await h.close();
    await sup.close();
    await log.close();
    work.deleteSync(recursive: true);
  }

  Map<String, Object?>? schema;

  Map<String, Object?> op(String execution, String task) {
    final o = officialCodexOp(outputSchema: schema ?? _schema);
    return {
      ...o,
      'operation_id': '$execution:0:0',
      'execution': {
        ...o['execution'] as Map<String, Object?>,
        'execution_id': execution,
      },
      'task': [
        {'type': 'text', 'text': task},
      ],
      'tools': {'shell': true},
      'codex_session': {'retain': true},
    };
  }

  Future<Map<String, Object?>> run(String execution, String task) async {
    final id = await h.startOperation(op(execution, task));
    final status = await h.waitEnded(id, timeout: const Duration(minutes: 3));
    for (final p in processes) {
      p.kill(ProcessSignal.sigkill);
    }
    processes.clear();
    return (status['result'] as Map).cast<String, Object?>();
  }

  List<Map> get requests => [
    for (final e in h.gateway.exchanges)
      if (e.path == codexResponsesPath) (e.body as Map),
  ];

  /// With DIFYSF_CODEX_EVIDENCE: what this test saw.
  void keep(String name, Object? what) {
    final dir = Platform.environment['DIFYSF_CODEX_EVIDENCE'];
    if (dir == null) return;
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(what));
  }
}

const _timeout = Timeout(Duration(minutes: 4));

final _proof = Platform.environment['DIFYSF_CHECKPOINT_PROOF'];

void main() {
  for (final reason in const ['model_error', 'max_turns']) {
    test(
      'a checkpoint from a workflow\'s own tool ($reason)',
      () async {
        final copy =
            'mkdir -p .dify-sf && cp -a ${shellQuote('$_proof/checkpoint')} '
            '$checkpointDir';
        final rig = await _Rig.start([
          _exec(copy),
          if (reason == 'model_error') ..._disconnects,
        ], callLimit: reason == 'max_turns' ? 1 : null);
        rig.schema = (jsonDecode(
          File('$_proof/schema.json').readAsStringSync(),
        ) as Map).cast<String, Object?>();
        final r = await rig.run('E1', 'Build the model.');
        File('$_proof/result-$reason.json')
            .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(r));
        expect(
          (r['partial'] as Map?)?['reason'],
          reason,
          reason: jsonEncode(r),
        );
        expect(r['candidate_errors'], isEmpty);
      },
      skip: _binary == null || _proof == null
          ? 'set DIFYSF_CODEX_BIN and DIFYSF_CHECKPOINT_PROOF'
          : false,
      timeout: _timeout,
    );
  }

  test(
    'a disconnect mid-round hands in the checkpoint; the next round resumes '
    'the thread',
    () async {
      final rig = await _Rig.start([
        _exec(_checkpointCommand),
        ..._disconnects,
      ]);
      final r1 = await rig.run('E1', 'Build the model.');
      rig.keep('disconnect-round1', r1);
      expect(r1['partial'], {
        'reason': 'model_error',
        'notice_call_index': null,
        'handin': 'checkpoint',
        'call_index': greaterThanOrEqualTo(1),
      }, reason: jsonEncode(r1));
      expect(r1['candidate_errors'], isEmpty);
      final candidate = r1['candidate'] as Map;
      expect(candidate['notes'], 'board 3');
      expect((candidate['report'] as Map)['filename'], 'report.csv');
      expect(candidate[partialHandinOutput], startsWith('model_error: '));
      expect((r1['session'] as Map)['saved'], isTrue, reason: jsonEncode(r1));
      expect(
        Directory('${rig.home.path}/.codex-runs').listSync(),
        isEmpty,
        reason: 'CODEX_HOME removed',
      );
      final calls = rig.requests.length;
      final (status, _) = await rig.h.delete('/v1/executions/E1', {
        'protocol': protocolName,
        'generation': 1,
      });
      expect(status, 200);

      // Round 2: the reviewer sent it back. Codex resumes the failed turn's
      // thread.
      File('${rig.ws.path}/r2.csv').writeAsStringSync('r,2\n');
      rig.h.gateway
        ..clearCalls()
        ..enqueue(
          ScriptedCall.responses([
            _message(
              jsonEncode({
                'notes': 'finished after review',
                'report': 'r2.csv',
              }),
            ),
          ]),
        );
      final r2 = await rig.run('E2', 'The reviewer says: fix the roof.');
      rig.keep('disconnect-round2', r2);
      final history = jsonEncode(rig.requests[calls]['input']);
      expect(history, contains('Build the model.'));
      expect(history, contains('call_work'));
      expect(history, contains('The reviewer says: fix the roof.'));
      expect(
        File('${rig.ws.path}/$checkpointFile').existsSync(),
        isFalse,
        reason: 'the new round cleared the earlier checkpoint',
      );
      expect(r2['partial'], isNull, reason: jsonEncode(r2));
      expect((r2['candidate'] as Map)['notes'], 'finished after review');
    },
    skip: _skip,
    timeout: _timeout,
  );

  test(
    'the gateway\'s call limit (max_turns) hands in the checkpoint',
    () async {
      final rig = await _Rig.start([_exec(_checkpointCommand)], callLimit: 1);
      final r = await rig.run('E1', 'Build the model.');
      rig.keep('max-turns', r);
      expect(
        (r['partial'] as Map)['reason'],
        'max_turns',
        reason: jsonEncode(r),
      );
      expect((r['candidate'] as Map)['notes'], 'board 3');
      expect(
        (r['candidate'] as Map)[partialHandinOutput],
        startsWith('max_turns: '),
      );
    },
    skip: _skip,
    timeout: _timeout,
  );

  test(
    'no checkpoint: a disconnect stays model_error',
    () async {
      final rig = await _Rig.start([_exec('echo work'), ..._disconnects]);
      final r = await rig.run('E1', 'Build the model.');
      rig.keep('no-checkpoint', r);
      expect(r['error_type'], 'model_error', reason: jsonEncode(r));
      expect(r, isNot(contains('partial')));
      expect(r, isNot(contains('candidate')));
    },
    skip: _skip,
    timeout: _timeout,
  );

  test(
    'a normal run with a checkpoint on disk is unchanged',
    () async {
      final rig = await _Rig.start([
        _exec(_checkpointCommand),
        ScriptedCall.responses([
          _message(
            jsonEncode({
              'notes': 'finished',
              'report': '$checkpointDir/1/report.csv',
            }),
          ),
        ]),
      ]);
      final r = await rig.run('E1', 'Build the model.');
      rig.keep('normal', r);
      expect(r['partial'], isNull, reason: jsonEncode(r));
      expect(r['candidate_errors'], isEmpty);
      final candidate = r['candidate'] as Map;
      expect(candidate['notes'], 'finished');
      expect(candidate, isNot(contains(partialHandinOutput)));
      final sent = jsonEncode(rig.requests.first['text']);
      expect(sent, contains('report'));
      expect(sent, isNot(contains(partialHandinOutput)));
    },
    skip: _skip,
    timeout: _timeout,
  );
}
