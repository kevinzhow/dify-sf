// `model.transport: websocket` with the real Codex binary (docs/agent-v2.md,
// "Codex over the Responses WebSocket"):
//
//   DIFYSF_CODEX_BIN=/path/to/codex-0.163.0 dart test test/codex_websocket_binary_test.dart
//
// As in codex_retain_binary_test.dart, the fake sandbox runs the commands
// for real on this host and `codex app-server` runs as a local process
// (its output, the JSON log the runtime follows, is the fake job's output).
// The scripted gateway's Codex entry speaks the Responses WebSocket:
//
// - accepted: Codex's warm-up (`generate: false`) and the turn's requests
//   arrive on one socket, each after the warm-up with `previous_response_id`
//   and only the new items; no HTTP POST;
// - 426 to the upgrade: the run ends before its turn, no HTTP POST;
// - the socket dropped mid-turn and the reconnect answered 426: Codex
//   switches to HTTP silently and POSTs the whole conversation, which the
//   gateway refuses (`X-DifySF-Require-Incremental`); the run ends with the
//   fallback error;
// - every request dropped: Codex's stream retries run out, it warns and
//   switches; the same failure.
//
// DIFYSF_CODEX_EVIDENCE=DIR keeps the requests and Codex's log there.
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
final _evidence = Platform.environment['DIFYSF_CODEX_EVIDENCE'];

Map<String, Object?> _message(String text) => {
  'type': 'message',
  'role': 'assistant',
  'id': 'msg_${text.hashCode.toRadixString(16)}',
  'phase': 'final_answer',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
  ],
};

Map<String, Object?> _exec(String callId, String cmd) => {
  'type': 'function_call',
  'id': 'fc_$callId',
  'call_id': callId,
  'name': 'exec_command',
  'arguments': jsonEncode({'cmd': cmd}),
};

/// The agent service with the official runtime, a fake sandbox running
/// Codex locally, and the scripted gateway as Codex's entry.
class _Rig {
  _Rig._(this.h, this.sup, this.work, this.log, this.processes);

  final Harness h;
  final FakeSupervisor sup;
  final Directory work;
  final IOSink log;
  final List<Process> processes;

  ScriptedGateway get gateway => h.gateway;

  static Future<_Rig> start(
    List<ScriptedCall> calls, {
    required CodexWebsocketMode mode,
    int? accepts,
  }) async {
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
                // Its output (stderr merged by the script) is the job's.
                void out(List<int> b) {
                  log.add(b);
                  job.output += utf8.decode(b, allowMalformed: true);
                }

                p.stdout.listen(out);
                p.stderr.listen(out);
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
    h.gateway
      ..codexWebsocket = mode
      ..codexWebsocketAccepts = accepts;
    sup.codexGatewayUrl = '${h.gateway.url.resolve('/inner/agent/codex/v1')}';
    final rig = _Rig._(h, sup, work, log, processes);
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
    if (work.existsSync()) work.deleteSync(recursive: true);
  }

  /// Runs one operation with the WebSocket; returns its result and events.
  Future<(Map<String, Object?>, List<Sse>)> run(String task) async {
    final o = officialCodexOp(effort: 'low', reasoningEfforts: ['low']);
    final run = await h.startOperation({
      ...o,
      'model': {
        ...o['model'] as Map<String, Object?>,
        'transport': 'websocket',
      },
      'task': [
        {'type': 'text', 'text': task},
      ],
      'tools': {'shell': true},
    });
    final status = await h.waitEnded(
      run,
      timeout: const Duration(seconds: 120),
    );
    return (
      (status['result'] as Map).cast<String, Object?>(),
      await h.events(run),
    );
  }

  List<RecordedExchange> get posts => [
    for (final e in gateway.exchanges)
      if (e.method == 'POST' && e.path == codexResponsesPath) e,
  ];

  /// What a test keeps with DIFYSF_CODEX_EVIDENCE.
  Future<void> keep(String name, Map<String, Object?> summary) async {
    final dir = _evidence;
    if (dir == null) return;
    final d = Directory('$dir/$name')..createSync(recursive: true);
    await log.flush();
    File('${work.path}/codex.log').copySync('${d.path}/codex-app-server.log');
    const pretty = JsonEncoder.withIndent(' ');
    File('${d.path}/websocket.json').writeAsStringSync(
      pretty.convert({
        'upgrades': [
          for (final u in gateway.codexWebsocketUpgrades)
            {
              'status': u.status,
              'connection': u.connection,
              'headers': u.headers,
            },
        ],
        'requests': [
          for (final r in gateway.codexWebsocketRequests)
            {
              'connection': r.connection,
              'frame_bytes': r.frameBytes,
              'response_id': r.responseId,
              'error': r.error,
              'body': r.body,
            },
        ],
        'http_posts': [
          for (final e in posts)
            {'status': e.status, 'headers': e.headers, 'body': e.body},
        ],
      }),
    );
    File('${d.path}/summary.json').writeAsStringSync(pretty.convert(summary));
  }
}

void main() {
  final skip = _binary == null
      ? 'set DIFYSF_CODEX_BIN to the Codex binary'
      : false;
  const timeout = Timeout(Duration(minutes: 4));

  test(
    'one socket: the warm-up is full, the turn\'s requests carry '
    'previous_response_id and only the new items; no HTTP',
    () async {
      final rig = await _Rig.start([
        ScriptedCall.responses([_exec('call_1', 'echo hello-from-ws')]),
        ScriptedCall.responses([_message('The command said hello-from-ws.')]),
      ], mode: CodexWebsocketMode.accept);
      final (result, events) = await rig.run(
        'Run `echo hello-from-ws` and tell me what it printed.',
      );
      expect(result['candidate'], {
        'text': 'The command said hello-from-ws.',
      }, reason: jsonEncode(result));
      expect((events.first.data['runtime'] as Map)['transport'], 'websocket');
      final exec = events.lastWhere(
        (e) => e.event == 'tool_call' && e.data['phase'] == 'finished',
      );
      expect(jsonEncode(exec.data['output']), contains('hello-from-ws'));

      final g = rig.gateway;
      // One handshake, with the run token, the beta header and the header
      // that tells the gateway to refuse HTTP model calls.
      expect([for (final u in g.codexWebsocketUpgrades) u.status], [101]);
      final upgrade = g.codexWebsocketUpgrades.single.headers;
      expect(upgrade['authorization'], 'Bearer secret-run-token');
      expect(upgrade['openai-beta'], codexWebsocketBeta);
      expect(upgrade['x-difysf-require-incremental'], 'v1');
      expect(rig.posts, isEmpty, reason: 'nothing over HTTP');

      final reqs = g.codexWebsocketRequests;
      expect([for (final r in reqs) r.connection], [1, 1, 1]);
      final [warmup, first, second] = reqs;
      // The warm-up: the whole prompt, no previous response.
      expect(warmup.warmup, isTrue);
      expect(warmup.previousResponseId, isNull);
      expect(warmup.responseId, 'resp_warmup_1');
      // The turn's first request continues the warm-up with the new items
      // (the task among them).
      expect(first.warmup, isFalse);
      expect(first.previousResponseId, 'resp_warmup_1');
      expect(jsonEncode(first.input), contains('echo hello-from-ws'));
      expect(first.responseId, 'resp_1');
      // The follow-up: previous_response_id and only the tool's output.
      expect(second.previousResponseId, 'resp_1');
      expect(
        [for (final i in second.input) (i as Map)['type']],
        ['function_call_output'],
      );
      expect(jsonEncode(second.input), contains('hello-from-ws'));
      expect(jsonEncode(second.input), isNot(contains('tell me what it')));
      // What the gateway rebuilds stands for the whole conversation.
      final conversation = jsonEncode(second.conversation);
      expect(conversation, contains('tell me what it printed'));
      expect(conversation, contains('"call_id":"call_1"'));

      final summary = {
        for (final (name, r) in [
          ('warmup', warmup),
          ('request_1', first),
          ('request_2', second),
        ])
          name: {
            'previous_response_id': r.previousResponseId,
            'input_items': r.input.length,
            'frame_bytes': r.frameBytes,
            'conversation_items': r.conversation!.length,
            'conversation_bytes': utf8
                .encode(jsonEncode(r.conversation))
                .length,
          },
      };
      print('websocket requests: ${jsonEncode(summary)}');
      await rig.keep('incremental', summary);
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'a 426 to the upgrade ends the run before its turn; nothing over HTTP',
    () async {
      final rig = await _Rig.start([
        ScriptedCall.responses([_message('never')]),
      ], mode: CodexWebsocketMode.upgradeRequired);
      final (result, events) = await rig.run('Say hi.');
      expect(
        [for (final e in events) e.event],
        ['run_started', 'failed'],
        reason: jsonEncode(result),
      );
      expect(result['error_type'], 'model_error');
      expect(
        result['message'],
        'Codex fell back from WebSockets to HTTP: the WebSocket handshake '
        'failed (HTTP error: 426 Upgrade Required); the run ended before its '
        'turn started: no request went over HTTP',
      );
      expect(
        [for (final u in rig.gateway.codexWebsocketUpgrades) u.status],
        [426],
      );
      expect(
        rig
            .gateway
            .codexWebsocketUpgrades
            .single
            .headers['x-difysf-require-incremental'],
        'v1',
      );
      // Give a stray request time to arrive.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(rig.posts, isEmpty, reason: 'no HTTP POST');
      final summary = {'message': result['message'], 'http_posts': 0};
      print('426: ${jsonEncode(summary)}');
      await rig.keep('upgrade-426', summary);
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'the socket dropped mid-turn and the reconnect answered 426: Codex '
    'switches to HTTP; a POST of the whole conversation, if it gets out '
    'before the interrupt, is refused; the run ends with the fallback error',
    () async {
      final rig = await _Rig.start(
        [
          ScriptedCall(drop: true),
          ScriptedCall.responses([_message('never')]),
        ],
        mode: CodexWebsocketMode.accept,
        accepts: 1,
      );
      final (result, events) = await rig.run('Say hi.');
      final g = rig.gateway;
      final posts = rig.posts;
      final summary = {
        'message': result['message'],
        'upgrades': [for (final u in g.codexWebsocketUpgrades) u.status],
        'http_posts': [
          for (final p in posts)
            {
              'status': p.status,
              'bytes': utf8.encode(jsonEncode(p.body)).length,
              'header': p.headers['x-difysf-require-incremental'],
            },
        ],
      };
      print('mid-turn 426: ${jsonEncode(summary)}');
      await rig.keep('reconnect-426', summary);
      expect(events.last.event, 'failed', reason: jsonEncode(result));
      expect(result['error_type'], 'model_error');
      // Seen in Codex's log while the turn runs, or (the gateway's refusal
      // ended it first) when the run reads the rest of the log.
      expect(
        result['message'],
        anyOf(
          'Codex fell back from WebSockets to HTTP: the WebSocket handshake '
              'failed (HTTP error: 426 Upgrade Required); Codex sends the model '
              'request it was making over HTTP right after switching (the '
              'whole conversation, marked X-DifySF-Require-Incremental for the '
              'gateway to refuse); the turn was interrupted',
          'Codex fell back from WebSockets to HTTP: the WebSocket handshake '
              'failed (HTTP error: 426 Upgrade Required); Codex sent the model '
              'request it was making over HTTP (the whole conversation, marked '
              'X-DifySF-Require-Incremental) and the gateway refused it '
              '(incremental_required); the turn ended',
        ),
      );
      expect([for (final u in g.codexWebsocketUpgrades) u.status], [101, 426]);
      // Codex POSTs at once after the 426; the run's interrupt may still
      // beat the request out (its first HTTP client is built then). A POST
      // that got out is the whole conversation, marked, and refused before
      // it counted.
      expect(posts.length, lessThanOrEqualTo(1));
      for (final p in posts) {
        expect(p.headers['x-difysf-require-incremental'], 'v1');
        expect(p.status, 400);
        expect(jsonEncode(p.body), contains('Say hi.'));
        expect((p.body as Map).containsKey('previous_response_id'), isFalse);
      }
      expect(g.codexCalls, 1, reason: 'only the dropped WebSocket call');
    },
    skip: skip,
    timeout: timeout,
  );

  test(
    'every request dropped: Codex\'s stream retries run out, it warns and '
    'switches to HTTP; the run ends with the fallback error',
    () async {
      final rig = await _Rig.start([
        for (var i = 0; i <= codexStreamMaxRetries; i++)
          ScriptedCall(drop: true),
        ScriptedCall.responses([_message('never')]),
      ], mode: CodexWebsocketMode.accept);
      final (result, events) = await rig.run('Say hi.');
      expect(events.last.event, 'failed', reason: jsonEncode(result));
      expect(result['error_type'], 'model_error');
      expect(
        result['message'],
        startsWith(
          'Codex fell back from WebSockets to HTTP: the model request kept '
          'failing on the WebSocket',
        ),
      );
      final posts = rig.posts;
      final summary = {
        'message': result['message'],
        'upgrades': [
          for (final u in rig.gateway.codexWebsocketUpgrades) u.status,
        ],
        'websocket_requests': [
          for (final r in rig.gateway.codexWebsocketRequests)
            {
              'connection': r.connection,
              'warmup': r.warmup,
              'previous_response_id': r.previousResponseId,
              'error': r.error,
            },
        ],
        'model_retry_events': [
          for (final e in events)
            if (e.event == 'model_retry') e.data['message'],
        ],
        'http_posts': [
          for (final p in posts)
            {
              'status': p.status,
              'header': p.headers['x-difysf-require-incremental'],
            },
        ],
      };
      print('stream retries used up: ${jsonEncode(summary)}');
      // Any HTTP request was the marked one, refused.
      for (final p in posts) {
        expect(p.headers['x-difysf-require-incremental'], 'v1');
        expect(p.status, 400);
      }
      await rig.keep('retries-exhausted', summary);
    },
    skip: skip,
    timeout: timeout,
  );
}
