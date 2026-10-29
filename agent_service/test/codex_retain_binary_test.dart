// The retained Codex session with the real Codex binary (docs/agent-v2.md,
// "Codex session retained across rounds"):
//
//   DIFYSF_CODEX_BIN=/path/to/codex-0.163.0 dart test test/codex_retain_binary_test.dart
//
// The agent service runs its official runtime against the fake supervisor's
// retained workspaces, but each fake sandbox runs the commands for real on
// this host: the sandbox layout is a local directory (home and workspace),
// `/opt/codex/codex` is the given binary (its version and sha256 are checked
// as in a sandbox), `codex app-server` runs as a local process, and the
// scripted gateway is Codex's Responses entry. Round 1 starts the thread and
// keeps the session (the rollout copied into the workspace); round 2 is a new
// execution of the node with a fresh CODEX_HOME: the rollout is copied back,
// Codex resumes the thread, and its model request must carry round 1's
// history, the report_progress tool and round 2's reasoning effort.
// DIFYSF_CODEX_EVIDENCE=DIR keeps the requests, records and logs there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/official.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'codex_app_server_fake.dart' show officialCodexOp;
import 'support.dart';

final _binary = Platform.environment['DIFYSF_CODEX_BIN'];

Map<String, Object?> _message(String text) => {
  'type': 'message',
  'role': 'assistant',
  'id': 'msg_${text.hashCode}',
  'phase': 'final_answer',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
};

void main() {
  test(
    'round 1 keeps the session; round 2 resumes it with the real binary',
    () async {
      final work = Directory(newDataDir().resolveSymbolicLinksSync());
      final home = Directory('${work.path}/home')..createSync();
      final ws = Directory('${work.path}/ws')..createSync();
      final log = IOSink(File('${work.path}/codex.log').openWrite());
      final processes = <Process>[];
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
                  processes.add(p);
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
        calls: [
          ScriptedCall.responses([
            _message('Noted. The secret word is PELICAN-7.'),
          ]),
          ScriptedCall.responses([_message('It was PELICAN-7.')]),
        ],
        supervisorUrl: sup.url,
        profiles: profiles,
        codexRuntime: CodexRuntime.official,
        sandboxLayout: SandboxLayout(homeDir: home.path, workspaceDir: ws.path),
      );
      sup.codexGatewayUrl = '${h.gateway.url.resolve('/inner/agent/codex/v1')}';
      addTearDown(() async {
        for (final p in processes) {
          p.kill(ProcessSignal.sigkill);
        }
        await h.close();
        await sup.close();
        await log.close();
        final keep = Platform.environment['DIFYSF_CODEX_EVIDENCE'];
        if (keep != null) {
          Directory(keep).createSync(recursive: true);
          File('${work.path}/codex.log').copySync('$keep/codex-app-server.log');
        }
        work.deleteSync(recursive: true);
      });

      Map<String, Object?> op(String executionId, String effort, String task) {
        final o = officialCodexOp(
          effort: effort,
          reasoningEfforts: ['low', 'medium', 'high'],
        );
        return {
          ...o,
          'operation_id': '$executionId:0:0',
          'execution': {
            ...o['execution'] as Map<String, Object?>,
            'execution_id': executionId,
          },
          'task': [
            {'type': 'text', 'text': task},
          ],
          'tools': {'shell': true, 'report_progress': true},
          'codex_session': {'retain': true},
        };
      }

      Future<Map<String, Object?>> finish(String run) async {
        final status = await h.waitEnded(
          run,
          timeout: const Duration(seconds: 90),
        );
        for (final p in processes) {
          p.kill(ProcessSignal.sigkill);
        }
        processes.clear();
        return (status['result'] as Map).cast<String, Object?>();
      }

      final key = canonicalJson(['T1', 'A1', 'W1', 'N1']);
      final runsDir = Directory('${home.path}/.codex-runs');

      // ---- round 1
      final run1 = await h.startOperation(
        op('E1', 'low', 'Remember the secret word PELICAN-7.'),
      );
      final r1 = await finish(run1);
      expect(r1['candidate'], {
        'text': 'Noted. The secret word is PELICAN-7.',
      }, reason: jsonEncode(r1));
      final s1 = h.service.store.retainedWorkspace(key)!.session!;
      final copy = File('${ws.path}/.dify-sf/codex/${s1.threadId}.jsonl');
      expect(copy.lengthSync(), s1.size);
      expect(s1.rolloutPath, startsWith('sessions/'));
      expect(s1.turns, 1);
      expect(runsDir.listSync(), isEmpty, reason: 'CODEX_HOME removed');
      final (status, _) = await h.delete('/v1/executions/E1', {
        'protocol': protocolName,
        'generation': 1,
      });
      expect(status, 200);

      // ---- round 2: a new execution; a fresh CODEX_HOME
      final run2 = await h.startOperation(
        op('E2', 'high', 'What was the secret word?'),
      );
      final r2 = await finish(run2);
      expect(r2['candidate'], {
        'text': 'It was PELICAN-7.',
      }, reason: jsonEncode(r2));
      // One model call: Codex's replay of round 1's usage is not counted.
      expect((r2['usage'] as Map)['total_tokens'], 120);
      final started = (await h.events(run2)).first.data;
      final runtime = started['runtime'] as Map;
      expect(runtime['session'], {
        'resumed': true,
        'thread_id': s1.threadId,
        'turns_before': 1,
      });
      expect(runtime['reasoning_effort'], 'high');

      final requests = [
        for (final e in h.gateway.exchanges)
          if (e.path == codexResponsesPath) (e.body as Map),
      ];
      expect(requests, hasLength(2));
      final second = requests[1];
      final history = jsonEncode(second['input']);
      expect(history, contains('Remember the secret word PELICAN-7.'));
      expect(history, contains('Noted. The secret word is PELICAN-7.'));
      expect(history, contains('What was the secret word?'));
      expect([
        for (final t in (second['tools'] as List)) (t as Map)['name'],
      ], contains('report_progress'));
      expect((requests[0]['reasoning'] as Map)['effort'], 'low');
      expect((second['reasoning'] as Map)['effort'], 'high');
      final s2 = h.service.store.retainedWorkspace(key)!.session!;
      expect(s2.threadId, s1.threadId);
      expect(s2.turns, 2);
      expect(s2.size, greaterThan(s1.size));
      expect(runsDir.listSync(), isEmpty);

      final keep = Platform.environment['DIFYSF_CODEX_EVIDENCE'];
      if (keep != null) {
        Directory(keep).createSync(recursive: true);
        File('$keep/requests.json').writeAsStringSync(
          const JsonEncoder.withIndent(' ').convert(requests),
        );
        File('$keep/records.json').writeAsStringSync(
          const JsonEncoder.withIndent(' ')
              .convert({'round1': s1.toJson(), 'round2': s2.toJson()}),
        );
        File(
          '$keep/run_started_round2.json',
        ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(started));
        copy.copySync('$keep/rollout-copy.jsonl');
      }
    },
    skip: _binary == null ? 'set DIFYSF_CODEX_BIN to the Codex binary' : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
