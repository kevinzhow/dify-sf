import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<(Harness, FakeSupervisor)> startWithSandbox(
  List<ScriptedCall> calls, {
  void Function(FakeShellctl)? configure,
  Map<String, Map<String, Object?>> files = const {},
}) async {
  final sup = FakeSupervisor(key: testSupervisorKey, configure: configure);
  await sup.start();
  final h = await Harness.start(
    calls: calls,
    files: files,
    supervisorUrl: sup.url,
  );
  addTearDown(() async {
    await h.close();
    await sup.close();
  });
  return (h, sup);
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

List<Map> promptMessages(Map<String, Object?> llmRequest) =>
    ((llmRequest['target'] as Map)['prompt_messages'] as List).cast<Map>();

String toolContent(Map<String, Object?> llmRequest) =>
    promptMessages(llmRequest).lastWhere((m) => m['role'] == 'tool')['content']
        as String;

bool isControl(Map<String, Object?> run) => run['mode'] == 'stdio';

const fileSchema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string'},
    'report': {
      'type': 'string',
      'x-dify-sf-file': {
        'extensions': ['.csv'],
      },
    },
  },
  'required': ['text'],
};

void main() {
  for (final stop in ['cancel', 'timeout']) {
    test(
      '$stop ends a run waiting for a disk slot without creating a sandbox',
      () async {
        final (h, sup) = await startWithSandbox([
          ScriptedCall.toolCall('c1', 'shell_run', {'script': 'echo hi'}),
          ScriptedCall.text('done'),
        ]);
        sup.failAcquire = 503;
        sup.failAcquireCode = 'disk_pool_busy';
        final body = operation(shell: true);
        if (stop == 'timeout') (body['limits'] as Map)['timeout_seconds'] = 1;
        final runId = await h.startOperation(body);
        await until(() => sup.acquires.isNotEmpty);
        final clock = Stopwatch()..start();
        if (stop == 'cancel') {
          final (status, _) = await h.post('/v1/runs/$runId/cancel', {
            'protocol': protocolName,
            'generation': 1,
          });
          expect(status, 202);
        }
        final result = await h.waitEnded(
          runId,
          timeout: const Duration(seconds: 3),
        );
        expect(clock.elapsedMilliseconds, lessThan(2500));
        expect(result['status'], stop == 'cancel' ? 'cancelled' : 'failed');
        if (stop == 'timeout') {
          expect((result['result'] as Map)['error_type'], 'timeout');
        }
        final count = sup.acquires.length;
        sup.failAcquire = null;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sup.acquires.length, count);
        expect(sup.created, isEmpty);
      },
    );
  }

  test('first shell use acquires one sandbox, probes it, materializes files '
      'and runs shell_run in pty mode with env and HOME', () async {
    final (h, sup) = await startWithSandbox(
      [
        ScriptedCall.toolCall('c1', 'shell_run', {'script': 'echo hi >&2'}),
        ScriptedCall.toolCall('c2', 'shell_run', {
          'script': 'ls',
          'timeout': 5,
        }),
        ScriptedCall.text('done'),
      ],
      configure: (s) => s.onJob = (script) => FakeJobSpec(output: 'hi\r\n'),
      files: {
        'f1': {'mime_type': 'text/plain', 'size': 5, 'content': 'hello'},
      },
    );
    final (hs, health) = await h.get('/v1/health');
    expect(hs, 200);
    expect(health['sandbox'], 'isolated');

    final runId = await h.startOperation(
      operation(
        shell: true,
        askHuman: false,
        env: {'API_KEY': 'k'},
        files: [
          {'file_id': 'f1', 'path': 'inputs/a.txt'},
        ],
      ),
    );
    final s = await h.waitEnded(runId);
    expect(s['status'], 'succeeded', reason: jsonEncode(s));
    expect(sup.created, ['sbx1']);
    expect(sup.acquires, ['E1']);
    final sb = sup.sandboxOf('E1')!;
    expect(sb.probeRuns, 1);
    expect(utf8.decode(sb.files['/workspace/inputs/a.txt']!), 'hello');

    final runs = sb.userRuns;
    expect(runs, hasLength(2));
    expect(runs.first['mode'], 'pty'); // the PTY merges stderr into output
    expect(runs.first['cwd'], '/workspace');
    expect(runs.first['env'], {'API_KEY': 'k', 'HOME': '/home/dify/agent'});
    expect(runs.first['timeout'], defaultShellTimeoutSeconds);
    expect(runs.first['output_limit'], shellctlOutputLimitBytes);
    expect(runs.last['timeout'], 5);
    // Control commands are stdio with stderr merged (dd reads aside).
    for (final r in sb.runRequests.where(isControl)) {
      final script = r['script'] as String;
      expect(script, startsWith('{\n'));
      expect(script, endsWith('\n} 2>&1'));
      expect(r['env'], {'HOME': '/home/dify/agent'});
    }

    final content = toolContent(h.gateway.llmRequests[1]);
    expect(
      content,
      matches(
        RegExp(
          r'^<metadata>\n\{"job_id":"(job\d+)","status":"exited","done":true,'
          r'"exit_code":0,"output_path":"/home/dify/\.local/share/shellctl/jobs/'
          r'\1/output\.log"\}\n</metadata>\n\n<output>\nhi\r\n\n</output>$',
        ),
      ),
    );
    final request = h.gateway.llmRequests.first;
    final tools = ((request['target'] as Map)['tools'] as List)
        .map((t) => (t as Map)['name'])
        .toList();
    expect(tools, containsAll(shellToolNames));
    expect(
      promptMessages(request).first['content'],
      contains('You can run commands in an isolated shell workspace.'),
    );
    // The run's jobs are deleted and the leftovers reaped at its end.
    expect(sb.reaps, 1);
    expect(sb.jobs.values.where((j) => j.mode == 'pty'), isEmpty);
    final result = s['result'] as Map;
    expect((result['snapshot'] as Map)['workspace_ref'], 'sbx1');
  });

  test('a resume in a new process reuses the sandbox of workspace_ref; files '
      'are not materialized again', () async {
    final (h, sup) = await startWithSandbox(
      [
        ScriptedCall.toolCall('c1', 'shell_run', {'script': 'echo a > a'}),
        ScriptedCall.toolCall('q1', 'ask_human', {'question': 'Go on?'}),
        ScriptedCall.toolCall('c2', 'shell_run', {'script': 'cat a'}),
        ScriptedCall.text('done'),
      ],
      files: {
        'f1': {'size': 1, 'content': 'x'},
      },
    );
    final files = [
      {'file_id': 'f1', 'path': 'f.txt'},
    ];
    final run1 = await h.startOperation(operation(shell: true, files: files));
    final s1 = await h.waitEnded(run1);
    expect(s1['status'], 'paused');
    final paused = (s1['result'] as Map).cast<String, Object?>();
    expect((paused['snapshot'] as Map)['workspace_ref'], 'sbx1');
    final sb = sup.sandboxOf('E1')!;
    final writesBefore = sb.runRequests
        .where((r) => (r['script'] as String).contains('base64 -d'))
        .length;
    sb.files['/workspace/f.txt'] = utf8.encode('changed by the agent');

    await h.restart();
    final run2 = await h.startOperation(
      operation(
        shell: true,
        files: files,
        resumeSequence: 1,
        continuation: answer(paused, {}),
      ),
    );
    final s2 = await h.waitEnded(run2);
    expect(s2['status'], 'succeeded', reason: jsonEncode(s2));
    expect(sup.created, ['sbx1']);
    expect(sup.acquires, ['E1', 'E1']);
    expect(identical(sup.sandboxOf('E1'), sb), isTrue);
    expect(sb.probeRuns, 2, reason: 'a new process probes once');
    expect(
      sb.runRequests
          .where((r) => (r['script'] as String).contains('base64 -d'))
          .length,
      writesBefore,
    );
    expect(utf8.decode(sb.files['/workspace/f.txt']!), 'changed by the agent');
    expect(sb.userRuns, hasLength(2));
    expect(((s2['result'] as Map)['snapshot'] as Map)['workspace_ref'], 'sbx1');
  });

  test('a resume whose sandbox is gone fails with sandbox_error', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'true'}),
      ScriptedCall.toolCall('q1', 'ask_human', {'question': 'Go on?'}),
      ScriptedCall.toolCall('c2', 'shell_run', {'script': 'true'}),
    ]);
    final run1 = await h.startOperation(operation(shell: true));
    final paused = ((await h.waitEnded(run1))['result'] as Map)
        .cast<String, Object?>();
    await sup.sandboxes.remove('sbx1')!.close();
    final run2 = await h.startOperation(
      operation(
        shell: true,
        resumeSequence: 1,
        continuation: answer(paused, {}),
      ),
    );
    final s2 = await h.waitEnded(run2);
    expect(s2['status'], 'failed');
    expect((s2['result'] as Map)['error_type'], 'sandbox_error');
    expect((s2['result'] as Map)['message'], contains('sbx1'));
  });

  test('a resume after the container was replaced keeps a disk workspace: '
      'no sandbox_error, files not materialized again', () async {
    final (h, sup) = await startWithSandbox(
      [
        ScriptedCall.toolCall('c1', 'shell_run', {'script': 'true'}),
        ScriptedCall.toolCall('q1', 'ask_human', {'question': 'Go on?'}),
        ScriptedCall.toolCall('c2', 'shell_run', {'script': 'cat f.txt'}),
        ScriptedCall.text('done'),
      ],
      files: {
        'f1': {'size': 1, 'content': 'x'},
      },
    );
    sup.diskWorkspaces = true;
    final files = [
      {'file_id': 'f1', 'path': 'f.txt'},
    ];
    final run1 = await h.startOperation(operation(shell: true, files: files));
    final paused = ((await h.waitEnded(run1))['result'] as Map)
        .cast<String, Object?>();
    final sb1 = sup.sandboxOf('E1')!;
    sb1.files['/workspace/f.txt'] = utf8.encode('changed by the agent');
    await sup.sandboxes.remove('sbx1')!.close();
    final run2 = await h.startOperation(
      operation(
        shell: true,
        files: files,
        resumeSequence: 1,
        continuation: answer(paused, {}),
      ),
    );
    final s2 = await h.waitEnded(run2);
    expect(s2['status'], 'succeeded', reason: jsonEncode(s2));
    expect(sup.created, ['sbx1', 'sbx2']);
    final sb2 = sup.sandboxOf('E1')!;
    expect(
      sb2.runRequests.where((r) => '${r['script']}'.contains('base64 -d')),
      isEmpty,
    );
    expect(utf8.decode(sb2.files['/workspace/f.txt']!), 'changed by the agent');
    expect(((s2['result'] as Map)['snapshot'] as Map)['workspace_ref'], 'sbx2');
  });

  test('DELETE releases the sandbox; a failed release answers 503 and is '
      'retried', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'true'}),
      ScriptedCall.text('done'),
    ]);
    final runId = await h.startOperation(operation(shell: true));
    expect((await h.waitEnded(runId))['status'], 'succeeded');
    sup.failDelete = 503;
    final body = {'protocol': protocolName, 'generation': 1};
    final (s1, j1) = await h.delete('/v1/executions/E1', body);
    expect(s1, 503);
    expect(j1['error'], 'cleanup_failed');
    expect(sup.sandboxes.keys, ['sbx1']);
    sup.failDelete = null;
    final (s2, _) = await h.delete('/v1/executions/E1', body);
    expect(s2, 200);
    expect(sup.deletes, ['sbx1', 'sbx1']);
    expect(sup.sandboxes, isEmpty);
    expect(h.service.store.execution('E1')?.sandboxId, isNull);
  });

  test('lease expiry cancels the run, terminates its jobs and releases the '
      'sandbox', () async {
    final (h, sup) = await startWithSandbox(
      [
        ScriptedCall.toolCall('c1', 'shell_run', {'script': 'sleep 1000'}),
        ScriptedCall(hang: true, chunks: [ScriptedChunk(reasoning: '…')]),
      ],
      configure: (s) =>
          s.onJob = (_) => FakeJobSpec(output: 'zzz', running: true),
    );
    final runId = await h.startOperation(operation(shell: true));
    await until(() => h.gateway.observations.length == 2);
    final sb = sup.sandboxOf('E1')!;
    expect(sb.runningJobs, hasLength(1));
    final job = sb.runningJobs.single.id;
    await h.post('/v1/executions/E1/lease', {
      'protocol': protocolName,
      'generation': 1,
      'ttl_seconds': 1,
    });
    final ended = await h.waitEnded(runId, timeout: const Duration(seconds: 5));
    expect((ended['result'] as Map)['error_type'], 'cancel_lost');
    expect(sb.terminated, contains(job));
    expect(sb.reaps, 1);
    await until(() => sup.deletes.isNotEmpty);
    expect(sup.deletes, ['sbx1']);
  });

  test('cancel terminates the run\'s jobs and reaps their descendants before '
      'the run ends', () async {
    final (h, sup) = await startWithSandbox(
      [
        ScriptedCall.toolCall('c1', 'shell_run', {
          'script': 'setsid sleep 1000 & sleep 1000',
          'timeout': 1,
        }),
        ScriptedCall(hang: true, chunks: [ScriptedChunk(reasoning: '…')]),
      ],
      configure: (s) =>
          s.onJob = (_) => FakeJobSpec(output: 'started', running: true),
    );
    final runId = await h.startOperation(operation(shell: true));
    await until(() => h.gateway.observations.length == 2);
    final sb = sup.sandboxOf('E1')!;
    final job = sb.runningJobs.single.id;
    final (status, _) = await h.post('/v1/runs/$runId/cancel', {
      'protocol': protocolName,
      'generation': 1,
    });
    expect(status, 202);
    final ended = await h.waitEnded(runId);
    expect(ended['status'], 'cancelled');
    expect(sb.terminated, [job]);
    expect(sb.deleted, contains(job));
    expect(sb.reaps, 1);
    expect(sb.runningJobs, isEmpty);
    expect(sup.deletes, isEmpty, reason: 'the workspace is kept');
  });

  test('a sandbox whose processes cannot be reaped is removed', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': ':(){ :|:& };:'}),
      ScriptedCall.text('done'),
    ], configure: (s) => s.reapSucceeds = false);
    final runId = await h.startOperation(operation(shell: true));
    expect((await h.waitEnded(runId))['status'], 'succeeded');
    expect(sup.deletes, ['sbx1']);
    expect(h.service.store.execution('E1')?.sandboxId, isNull);
  });

  test('a failed probe makes the sandbox unavailable: sandbox_unavailable, '
      'no command runs, the sandbox is removed, health reports it', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'id'}),
    ], configure: (s) => s.probes['direct_internet'] = 'reachable');
    final runId = await h.startOperation(operation(shell: true));
    final s = await h.waitEnded(runId);
    expect(s['status'], 'failed');
    final result = s['result'] as Map;
    expect(result['error_type'], 'sandbox_unavailable');
    expect(result['message'], contains('direct_internet'));
    expect(sup.deletes, ['sbx1']);
    expect(sup.created, ['sbx1']);
    final (_, health) = await h.get('/v1/health');
    expect(health['sandbox'], 'unavailable');
  });

  test('a sandbox that reaches the host is unavailable; the probe targets the '
      'gateway the supervisor reported', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'id'}),
    ], configure: (s) => s.probes['host_reachable'] = 'reachable 10.9.0.1:22');
    sup.gateway = '10.9.0.1';
    final runId = await h.startOperation(operation(shell: true));
    final s = await h.waitEnded(runId);
    expect(s['status'], 'failed');
    final result = s['result'] as Map;
    expect(result['error_type'], 'sandbox_unavailable');
    expect(result['message'], contains('host_reachable'));
    expect(sup.deletes, ['sbx1']);
    final (_, health) = await h.get('/v1/health');
    expect(health['sandbox'], 'unavailable');
    expect(h.gateway.observations, hasLength(1), reason: 'no second turn');
  });

  test('a sandbox with an IPv6 interface is unavailable', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'id'}),
    ], configure: (s) => s.probes['host_ipv6'] = 'reachable');
    final runId = await h.startOperation(operation(shell: true));
    final s = await h.waitEnded(runId);
    expect((s['result'] as Map)['error_type'], 'sandbox_unavailable');
    expect((s['result'] as Map)['message'], contains('host_ipv6'));
    expect(sup.deletes, ['sbx1']);
  });

  test('the probe script carries the reported gateway, Docker\'s bridge '
      'address, the host-gateway names and the ports', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'id'}),
      ScriptedCall.text('done'),
    ]);
    sup.gateway = '10.213.4.17';
    final runId = await h.startOperation(operation(shell: true));
    expect((await h.waitEnded(runId))['status'], 'succeeded');
    final script = sup.sandboxOf('E1')!.lastProbeScript!;
    expect(script, contains("targets='10.213.4.17 172.17.0.1'"));
    expect(script, contains('host.docker.internal gateway.docker.internal'));
    expect(script, contains('for p in ${defaultHostProbePorts.join(' ')};'));
  });

  test('the host probe detects a listening port and nothing else (real bash '
      'against 127.0.0.1)', () async {
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(listener.close);
    listener.listen((s) => s.destroy());
    final closed = await ServerSocket.bind('127.0.0.1', 0);
    final closedPort = closed.port;
    await closed.close();
    Future<Map<String, String>> probe(List<int> ports) async {
      final r = await Process.run('bash', [
        '-c',
        ExecutionSandbox.hostProbeScript(gateway: '127.0.0.1', ports: ports),
      ]);
      return ExecutionSandbox.parseProbes(r.stdout as String);
    }

    expect(
      (await probe([closedPort, listener.port]))['host_reachable'],
      'reachable 127.0.0.1:${listener.port}',
    );
    expect((await probe([closedPort]))['host_reachable'], 'blocked');
  }, skip: Platform.isLinux ? false : 'needs bash and /dev/tcp');

  test('a failing supervisor is sandbox_unavailable', () async {
    final (h, sup) = await startWithSandbox([
      ScriptedCall.toolCall('c1', 'shell_run', {'script': 'id'}),
    ]);
    sup.failAcquire = 503;
    final runId = await h.startOperation(operation(shell: true));
    final s = await h.waitEnded(runId);
    expect((s['result'] as Map)['error_type'], 'sandbox_unavailable');
    expect((s['result'] as Map)['message'], contains('503'));
  });

  group('declared file outputs', () {
    Future<(Harness, FakeSupervisor, Map<String, Object?>)> runWith(
      String path, {
      void Function(FakeShellctl)? configure,
      int uploadStatus = 200,
      bool shell = true,
    }) async {
      final (h, sup) = await startWithSandbox(
        [
          if (shell)
            ScriptedCall.toolCall('c1', 'shell_run', {'script': 'make'}),
          ScriptedCall.toolCall('fo', 'final_output', {
            'text': 'ok',
            'report': path,
          }),
        ],
        configure: (s) {
          s.files['/workspace/out/report.csv'] = utf8.encode('a,b\n1,2\n');
          configure?.call(s);
        },
      );
      h.gateway.uploadStatus = uploadStatus;
      final runId = await h.startOperation(
        operation(shell: shell, askHuman: false, outputSchema: fileSchema),
      );
      return (h, sup, await h.waitEnded(runId));
    }

    test('file outputs nested in objects and arrays are uploaded at any '
        'depth; a bad nested path errors its top-level field', () async {
      const nested = {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'bundle': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'summary': {
                'type': 'string',
                'x-dify-sf-file': {
                  'extensions': ['csv'],
                },
              },
              'pages': {
                'type': 'array',
                'items': {'type': 'string', 'x-dify-sf-file': {}},
              },
            },
          },
          'broken': {
            'type': 'object',
            'properties': {
              'file': {'type': 'string', 'x-dify-sf-file': {}},
            },
          },
        },
        'required': ['text'],
      };
      final (h, _) = await startWithSandbox(
        [
          ScriptedCall.toolCall('c1', 'shell_run', {'script': 'make'}),
          ScriptedCall.toolCall('fo', 'final_output', {
            'text': 'ok',
            'bundle': {
              'title': 'T',
              'summary': 'out/report.csv',
              'pages': ['out/p1.txt', 'out/p2.txt'],
            },
            'broken': {'file': 'out/missing.txt'},
          }),
        ],
        configure: (s) {
          s.files['/workspace/out/report.csv'] = utf8.encode('a,b\n');
          s.files['/workspace/out/p1.txt'] = utf8.encode('one');
          s.files['/workspace/out/p2.txt'] = utf8.encode('two');
        },
      );
      final runId = await h.startOperation(
        operation(shell: true, askHuman: false, outputSchema: nested),
      );
      final s = await h.waitEnded(runId);
      expect(s['status'], 'succeeded', reason: jsonEncode(s));
      final result = s['result'] as Map;
      final bundle = (result['candidate'] as Map)['bundle'] as Map;
      expect(bundle['title'], 'T');
      expect((bundle['summary'] as Map)['filename'], 'report.csv');
      final pages = (bundle['pages'] as List).cast<Map>();
      expect(pages.map((p) => p['filename']), ['p1.txt', 'p2.txt']);
      expect(
        pages.map((p) => utf8.decode(h.gateway.uploads[p['upload_id']]!)),
        ['one', 'two'],
      );
      // The broken field keeps the model's value and gets one error.
      expect((result['candidate'] as Map)['broken'], {
        'file': 'out/missing.txt',
      });
      final errors = (result['candidate_errors'] as List).cast<Map>();
      expect(errors, hasLength(1));
      expect(errors.single['field'], 'broken');
      expect(errors.single['error'], startsWith('broken.file: '));
    });

    test('a workspace file is uploaded and replaced by its upload', () async {
      final (h, sup, s) = await runWith('out/report.csv');
      expect(s['status'], 'succeeded', reason: jsonEncode(s));
      final result = s['result'] as Map;
      expect(result['candidate_errors'], isEmpty);
      final report = (result['candidate'] as Map)['report'] as Map;
      expect(report['filename'], 'report.csv');
      expect(report['mime_type'], 'text/csv');
      expect(report['size'], 8);
      expect(
        utf8.decode(h.gateway.uploads[report['upload_id']]!),
        'a,b\n1,2\n',
      );
      final request = h.gateway.requests.singleWhere(
        (r) => r.path == '/inner/agent/files/upload-request',
      );
      expect(request.body, {
        'filename': 'report.csv',
        'mime_type': 'text/csv',
        'size': 8,
      });
      final tool =
          ((h.gateway.llmRequests.first['target'] as Map)['tools'] as List)
              .cast<Map>()
              .singleWhere((t) => t['name'] == 'final_output');
      final param =
          ((tool['parameters'] as Map)['properties'] as Map)['report'];
      expect(param, {
        'type': 'string',
        'description':
            'Path of a file in the shell workspace, relative to the workspace.',
      });
      expect(sup.deletes, isEmpty);
    });

    for (final (path, error) in [
      ('../etc/passwd.csv', 'leaves the workspace'),
      ('/etc/passwd.csv', 'outside the workspace'),
      ('link.csv', 'resolves outside the workspace'),
      ('missing.csv', 'does not exist'),
      ('out/report.txt', 'extension must be one of csv'),
    ]) {
      test('$path is a candidate error, not an upload', () async {
        final (h, _, s) = await runWith(
          path,
          configure: (fs) {
            fs.files['/etc/passwd.csv'] = utf8.encode('root');
            fs.symlinks['/workspace/link.csv'] = '/etc/passwd.csv';
            fs.files['/workspace/out/report.txt'] = utf8.encode('x');
          },
        );
        expect(s['status'], 'succeeded');
        final result = s['result'] as Map;
        final errors = (result['candidate_errors'] as List).cast<Map>();
        expect(errors.single['field'], 'report');
        expect(errors.single['error'], contains(error));
        expect((result['candidate'] as Map)['report'], path);
        expect(h.gateway.uploads, isEmpty);
      });
    }

    test('a failed upload fails the run with file_error and keeps the '
        'workspace', () async {
      final (h, sup, s) = await runWith('out/report.csv', uploadStatus: 500);
      expect(s['status'], 'failed');
      expect((s['result'] as Map)['error_type'], 'file_error');
      expect(sup.deletes, isEmpty);
      expect(sup.sandboxOf('E1')!.files, contains('/workspace/out/report.csv'));
      expect(h.service.store.execution('E1')?.sandboxId, 'sbx1');
    });

    test('without the shell a file output is a candidate error', () async {
      final (_, sup, s) = await runWith('out/report.csv', shell: false);
      final errors = ((s['result'] as Map)['candidate_errors'] as List)
          .cast<Map>();
      expect(errors.single['error'], contains('tools.shell is false'));
      expect(sup.acquires, isEmpty);
    });
  });

  group('shell tools over shellctl', () {
    late FakeShellctl fake;
    late ShellSession session;

    setUp(() async {
      fake = FakeShellctl(token: 't');
      await fake.start();
      final sandbox = ExecutionSandbox(
        executionId: 'E1',
        grant: SandboxGrant('sbx', fake.url, 't', created: true),
      );
      session = ShellSession(sandbox, {'K': 'v'});
    });
    tearDown(() => fake.close());

    test('output within the window is shown as head and tail with Dify\'s '
        'marker and the log path', () async {
      final big = '${'a' * 6000}${'b' * 6000}';
      fake.onJob = (_) => FakeJobSpec(output: big);
      final text = await session.call(shellRunToolName, {'script': 'x'});
      final output = (text as String).split('<output>\n')[1];
      final lines = output.split('\n');
      expect(lines[0], 'a' * 4096);
      expect(
        lines[1],
        '... (truncated in middle because the max output size is limited to '
        '8192 bytes) ...',
      );
      expect(lines[2], 'b' * 4096);
      expect(lines[3], startsWith('(check the /home/dify/.local/share/'));
      expect(text, contains('"output_path":"/home/dify/'));
    });

    test('a truncated window fetches the tail; the next wait continues after '
        'it', () async {
      final big = List.generate(40000, (i) => '${i % 10}').join();
      fake.onJob = (_) => FakeJobSpec(output: big, running: true);
      final text = await session.call(shellRunToolName, {'script': 'x'});
      expect(text as String, contains('"done":false'));
      expect(text, contains(big.substring(big.length - 4096)));
      final job = fake.runningJobs.single;
      job.output += 'END';
      final next = await session.call(shellWaitToolName, {'job_id': job.id});
      expect((next as String).split('<output>\n')[1], 'END\n</output>');
    });

    test('input, interrupt and errors', () async {
      fake.onJob = (_) => FakeJobSpec(output: 'Name? ', running: true);
      await session.call(shellRunToolName, {'script': 'read n'});
      final id = fake.runningJobs.single.id;
      final answered = await session.call(shellInputToolName, {
        'job_id': id,
        'text': 'Ada\n',
      });
      expect(answered as String, endsWith('<output>\ngot: Ada\n\n</output>'));
      final interrupted = await session.call(shellInterruptToolName, {
        'job_id': id,
      });
      expect(interrupted as String, contains('"status":"terminated"'));
      expect(
        interrupted,
        endsWith('<output>\nJob was interrupted.\n</output>'),
      );

      expect(await session.call(shellWaitToolName, {'job_id': 'nope'}), {
        'error': 'Unknown shell job id for this session: nope.',
        'job_id': 'nope',
      });
      expect(
        await session.call(shellRunToolName, {'script': 'x', 'timeout': 301}),
        {'error': 'timeout must be > 0 and <= 300 seconds'},
      );
      fake.jobs.remove(id);
      expect(await session.call(shellWaitToolName, {'job_id': id}), {
        'error': 'job_not_found: job_not_found (404): Job $id not found',
        'job_id': id,
      });
    });

    test('close terminates running jobs, deletes them and reaps', () async {
      fake.onJob = (_) => FakeJobSpec(running: true);
      await session.call(shellRunToolName, {'script': 'sleep 9'});
      final id = fake.runningJobs.single.id;
      expect(await session.close(), isTrue);
      expect(fake.terminated, [id]);
      expect(fake.deleted, contains(id));
      expect(fake.reaps, 1);
    });

    test('UTF-8 safe head and tail', () {
      expect(utf8Prefix('aé', 2), 'a');
      expect(utf8Suffix('éa', 2), 'a');
      expect(utf8Prefix('abc', 10), 'abc');
    });
  });

  test('reserved environment names are refused at the sandbox layer too', () {
    final sandbox = ExecutionSandbox(
      executionId: 'E1',
      grant: SandboxGrant(
        'sbx',
        Uri.parse('http://127.0.0.1:1'),
        't',
        created: false,
      ),
    );
    for (final name in ['HOME', 'path', 'SHELLCTL_AUTH_TOKEN', 'https_proxy']) {
      expect(
        () => sandbox.jobEnv({name: 'x'}),
        throwsA(
          isA<SandboxFailure>().having(
            (e) => e.errorType,
            'errorType',
            'sandbox_error',
          ),
        ),
      );
    }
    expect(sandbox.jobEnv({'A': '1'}), {'A': '1', 'HOME': '/home/dify/agent'});
  });

  test('files[] paths must stay in the workspace', () async {
    final h = await Harness.start();
    addTearDown(h.close);
    for (final path in ['../x', '/etc/x', '', 'a/../../b']) {
      final (status, json) = await h.post(
        '/v1/operations',
        operation(
          files: [
            {'file_id': 'f', 'path': path},
          ],
        ),
      );
      expect(status, 400, reason: path);
      expect(json['error'], 'invalid_request');
    }
    expect(normalizeWorkspacePath('/workspace/a/./b'), 'a/b');
  });
}
