// Real sandbox integration test: Docker on this machine, the local image
// langgenius/dify-agent-local-sandbox:1.17.1 (never pulled here).
//
//   AGENT_SANDBOX_IT=1 dart test -j 1 test/sandbox_integration_test.dart
//
// It creates its own internal networks and containers, all labelled
// `dify-sf.test=<random>`, and removes them in tearDownAll even on failure.
// Nothing else on the host is touched.
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/supervisor.dart';
import 'package:agent_service/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

final enabled = Platform.environment['AGENT_SANDBOX_IT'] == '1';
const supervisorKey = 'it-supervisor-key';

void main() {
  final random = Random.secure();
  final label = List.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  final labelFilter = 'dify-sf.test=$label';
  late DockerClient docker;
  late String network;
  late String inhibitedNetwork;
  late String inhibitedGateway;
  late SandboxSupervisor supervisor;
  late Uri supervisorUrl;
  late ScriptedGateway gateway;
  late Directory dataDir;

  void log(String m) => stderr.writeln('[it] $m');

  Future<(String, String)> createNetwork(
    String name, {
    bool inhibit = false,
  }) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      final subnet = '10.${200 + random.nextInt(50)}.${random.nextInt(256)}';
      try {
        await docker.createNetwork({
          'Name': name,
          'Driver': 'bridge',
          'Internal': true,
          'Labels': {'dify-sf.test': label},
          'IPAM': {
            'Config': [
              {'Subnet': '$subnet.0/24'},
            ],
          },
          if (inhibit)
            'Options': {'com.docker.network.bridge.inhibit_ipv4': 'true'},
        });
        return (name, '$subnet.1');
      } on DockerException catch (e) {
        if (e.status == 0) rethrow;
        // Overlapping subnet: try another.
      }
    }
    throw StateError('no free subnet for $name');
  }

  SupervisorConfig supervisorConfig(String net) => SupervisorConfig(
    key: supervisorKey,
    network: net,
    labelKey: 'dify-sf.test',
    labelValue: label,
    namePrefix: 'dify-sf-it-$label-',
    memoryMb: 512,
    cpus: 1,
    pidsLimit: 128,
    homeMb: 64,
    workspaceMb: 64,
    addressByIp: true,
  );

  setUpAll(() async {
    if (!enabled) return;
    docker = DockerClient('/var/run/docker.sock');
    await docker.ping();
    (network, _) = await createNetwork('dify-sf-it-$label');
    (inhibitedNetwork, inhibitedGateway) = await createNetwork(
      'dify-sf-it-$label-inh',
      inhibit: true,
    );
    supervisor = SandboxSupervisor(supervisorConfig(network), log: log);
    final port = await supervisor.start(address: '127.0.0.1', port: 0);
    supervisorUrl = Uri.parse('http://127.0.0.1:$port');
    gateway = ScriptedGateway(
      serviceKey: testKey,
      files: {
        'f1': {'mime_type': 'text/plain', 'size': 5, 'content': 'hello'},
      },
    );
    await gateway.start();
    dataDir = newDataDir();
  });

  tearDownAll(() async {
    if (!enabled) return;
    try {
      await supervisor.stop();
    } catch (_) {}
    try {
      await gateway.close();
    } catch (_) {}
    final cleanup = DockerClient('/var/run/docker.sock');
    try {
      for (final c in await cleanup.listContainers([labelFilter])) {
        await cleanup.removeContainer(c['Id'] as String);
      }
      for (final n in await cleanup.listNetworks([labelFilter])) {
        await cleanup.removeNetwork(n['Id'] as String);
      }
    } finally {
      cleanup.close();
    }
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    final ps = await Process.run('docker', [
      'ps',
      '-a',
      '--filter',
      'label=$labelFilter',
    ]);
    final nets = await Process.run('docker', [
      'network',
      'ls',
      '--filter',
      'label=$labelFilter',
    ]);
    log(
      'cleanup check: docker ps -a --filter label=$labelFilter\n${ps.stdout}',
    );
    log(
      'cleanup check: docker network ls --filter label=$labelFilter\n${nets.stdout}',
    );
    expect((ps.stdout as String).trim().split('\n'), hasLength(1));
    expect((nets.stdout as String).trim().split('\n'), hasLength(1));
  });

  SandboxManager newManager() => SandboxManager(
    supervisor: SupervisorClient(supervisorUrl, supervisorKey),
    store: RunStore(newDataDir().path)..load(),
    log: log,
  );

  InnerClient inner() => InnerClient(
    baseUrl: gateway.url,
    serviceKey: testKey,
    runToken: runToken,
  );

  OperationRequest request(
    String executionId, {
    List<Map<String, Object?>>? files,
  }) => OperationRequest.parse(
    operation(executionId: executionId, shell: true, files: files ?? []),
  );

  Future<String> run(ShellSession s, String script, {num timeout = 30}) async {
    final out = await s.call(shellRunToolName, {
      'script': script,
      'timeout': timeout,
    });
    if (out is! String) fail('shell_run failed: $out');
    log('shell_run ${script.split('\n').first} ->\n$out');
    return out;
  }

  group('real sandbox', skip: enabled ? false : 'set AGENT_SANDBOX_IT=1', () {
    test('two executions: probes pass; neither reads the other nor the '
        'daemon; files are materialized; stderr is merged', () async {
      final manager = newManager();
      final client = inner();
      addTearDown(() async {
        await manager.release('IT-A');
        await manager.release('IT-B');
        client.close();
        manager.close();
      });
      final a = await manager.open(
        request(
          'IT-A',
          files: [
            {'file_id': 'f1', 'path': 'in/a.txt'},
          ],
        ),
        client,
      );
      final b = await manager.open(request('IT-B'), client);
      expect(a.probed && b.probed, isTrue);
      expect(manager.health, 'isolated');
      expect(a.sandboxId, isNot(b.sandboxId));

      final sa = ShellSession(a, {'GREETING': 'hi-from-env'});
      final sb = ShellSession(b, {});
      final outA = await run(
        sa,
        'echo secret-A > mine.txt; cat in/a.txt; echo; echo \$GREETING; '
        'echo to-stderr >&2; echo HOME=\$HOME',
      );
      expect(outA, contains('hello'));
      expect(outA, contains('hi-from-env'));
      expect(outA, contains('to-stderr'));
      expect(outA, contains('HOME=/home/dify/agent'));

      final ipA = a.grant.url.host;
      final outB = await run(sb, '''
cat /workspace/mine.txt 2>&1; ls -a /workspace
ls /home/dify/.local/share/shellctl/jobs 2>&1; echo jobs_rc=\$?
for d in /proc/[0-9]*; do [ "\$(cat \$d/comm 2>/dev/null)" = shellctl ] && { head -c 20 \$d/environ >/dev/null 2>&1; echo environ_rc=\$?; }; done
echo probe > /home/dify/x 2>&1; echo home_root_rc=\$?
curl -s -o /dev/null -w "peer_no_token=%{http_code}\\n" -m 5 http://$ipA:5004/v1/jobs
''');
      expect(outB, isNot(contains('secret-A')));
      expect(outB, contains('No such file'));
      expect(outB, contains('Permission denied'));
      expect(outB, isNot(contains('jobs_rc=0')));
      expect(outB, contains('environ_rc=1'));
      expect(outB, isNot(contains('home_root_rc=0')));
      expect(outB, contains('peer_no_token=401'));
      expect(await sa.close(), isTrue);
      expect(await sb.close(), isTrue);

      // DELETE path: release removes the containers.
      await manager.release('IT-A');
      expect(await docker.inspectContainer(a.sandboxId), isNull);
    });

    test('direct egress fails; with inhibit_ipv4 the host bridge address is '
        'unreachable too', () async {
      final manager = newManager();
      final client = inner();
      addTearDown(() async {
        await manager.release('IT-N');
        client.close();
        manager.close();
      });
      final sandbox = await manager.open(request('IT-N'), client);
      final s = ShellSession(sandbox, {});
      final out = await run(s, '''
timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>&1; echo tcp_rc=\$?
getent hosts pypi.org; echo dns_rc=\$?
timeout 5 curl -s -m 4 -o /dev/null https://pypi.org; echo curl_rc=\$?
timeout 3 bash -c "exec 3<>/dev/tcp/${sandbox.grant.url.host.replaceFirst(RegExp(r'\.\d+$'), '.1')}/22" 2>&1; echo bridge_rc=\$?
''');
      expect(out, isNot(contains('tcp_rc=0')));
      expect(out, isNot(contains('dns_rc=0')));
      expect(out, isNot(contains('curl_rc=0')));
      log(
        out.contains('bridge_rc=0')
            ? 'OBSERVED: without inhibit_ipv4 the host bridge address is reachable'
            : 'observed: the host bridge address is not reachable',
      );
      expect(await s.close(), isTrue);

      // The same image on an inhibit_ipv4 network (as in compose).
      final inhibited = SandboxSupervisor(
        supervisorConfig(inhibitedNetwork),
        log: log,
      );
      final grant = await inhibited.acquire('IT-INH');
      addTearDown(() => inhibited.remove(grant['sandbox_id'] as String));
      final (code, text) = await docker.exec(grant['sandbox_id'] as String, [
        'bash',
        '-c',
        'timeout 3 bash -c "exec 3<>/dev/tcp/$inhibitedGateway/22" 2>&1; '
            'echo bridge_rc=\$?; timeout 3 bash -c '
            '"exec 3<>/dev/tcp/1.1.1.1/443" 2>&1; echo tcp_rc=\$?',
      ]);
      log('inhibited network: exit $code\n$text');
      expect(text, isNot(contains('bridge_rc=0')));
      expect(text, isNot(contains('tcp_rc=0')));
    });

    test('many processes hit the PID limit; a large file hits the disk '
        'limit; nothing survives the session', () async {
      final manager = newManager();
      final client = inner();
      addTearDown(() async {
        await manager.release('IT-P');
        client.close();
        manager.close();
      });
      final sandbox = await manager.open(request('IT-P'), client);
      final s = ShellSession(sandbox, {});
      final disk = await run(
        s,
        '(head -c 100M /dev/zero > big) 2>&1; echo rc=\$?; stat -c size=%s big; rm -f big',
      );
      expect(disk, contains('No space left on device'));
      final size = int.parse(RegExp(r'size=(\d+)').firstMatch(disk)!.group(1)!);
      expect(size, lessThanOrEqualTo(64 * 1024 * 1024));

      final pids = await run(s, '''
python3 - <<'EOF'
import os, time
n = 0
try:
    while n < 400:
        if os.fork() == 0:
            time.sleep(60)
            os._exit(0)
        n += 1
except OSError as e:
    print("fork failed after", n, e)
EOF
''', timeout: 60);
      final m = RegExp(r'fork failed after (\d+)').firstMatch(pids);
      expect(m, isNotNull, reason: pids);
      expect(int.parse(m!.group(1)!), lessThan(128));

      final stopped = await s.close();
      log('session close after the PID test: reaped=$stopped');
      if (stopped) {
        final left = await sandbox.control('ps -eo comm= | grep -c python3');
        expect(left.output.trim(), '0');
      } else {
        await manager.discard('IT-P', sandbox.sandboxId);
        expect(await docker.inspectContainer(sandbox.sandboxId), isNull);
      }
    });

    test('through the service: cancel kills setsid/nohup grandchildren, a '
        'file output is uploaded, DELETE removes the container', () async {
      gateway.enqueue(
        ScriptedCall.toolCall('c1', 'shell_run', {
          'script':
              'setsid sleep 1001 & nohup sleep 1002 >/dev/null 2>&1 & '
              'sh -c "sleep 1003" & sleep 1000',
          'timeout': 2,
        }),
      );
      gateway.enqueue(
        ScriptedCall(hang: true, chunks: [ScriptedChunk(reasoning: '…')]),
      );
      final service = AgentService(
        serviceKey: testKey,
        dataDir: dataDir.path,
        innerUrl: gateway.url,
        logLevel: LogLevel.warning,
        supervisor: SupervisorClient(supervisorUrl, supervisorKey),
      );
      await service.start(address: '127.0.0.1', port: 0);
      addTearDown(service.stop);
      final h = _Client(service.port);
      addTearDown(h.close);

      final runId = await h.start(operation(executionId: 'IT-E', shell: true));
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (gateway.observations.length < 2) {
        if (DateTime.now().isAfter(deadline)) fail('the model was not called');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final sandbox = service.sandboxes.liveSandbox('IT-E')!;
      final before = await sandbox.control('ps -eo args=');
      log('before cancel:\n${before.output}');
      for (final n in [
        'sleep 1000',
        'sleep 1001',
        'sleep 1002',
        'sleep 1003',
      ]) {
        expect(before.output, contains(n));
      }
      final (cs, _) = await h.post('/v1/runs/$runId/cancel', {
        'protocol': protocolName,
        'generation': 1,
      });
      expect(cs, 202);
      final ended = await h.waitEnded(runId);
      expect(ended['status'], 'cancelled');
      final after = await sandbox.control('ps -eo args=');
      log('after cancel:\n${after.output}');
      expect(after.output, isNot(contains('sleep 100')));

      // A declared file output in the same workspace, read and uploaded.
      gateway.enqueue(
        ScriptedCall.toolCall('c2', 'shell_run', {
          'script': 'mkdir -p out; printf "a,b\\n1,2\\n" > out/r.csv; ln -s /etc/passwd evil.csv',
        }),
      );
      gateway.enqueue(
        ScriptedCall.toolCall('fo', 'final_output', {
          'text': 'done',
          'report': 'evil.csv',
          'table': 'out/r.csv',
        }),
      );
      final schema = {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'report': {'type': 'string', 'x-dify-sf-file': <String, Object?>{}},
          'table': {
            'type': 'string',
            'x-dify-sf-file': {
              'extensions': ['csv'],
            },
          },
        },
      };
      final run2 = await h.start(
        operation(executionId: 'IT-F', shell: true, outputSchema: schema),
      );
      final s2 = await h.waitEnded(run2);
      expect(s2['status'], 'succeeded', reason: jsonEncode(s2));
      final result = s2['result'] as Map;
      final errors = (result['candidate_errors'] as List).cast<Map>();
      expect(errors.single['field'], 'report');
      expect(
        errors.single['error'],
        contains('resolves outside the workspace'),
      );
      final table = (result['candidate'] as Map)['table'] as Map;
      expect(table['filename'], 'r.csv');
      expect(table['mime_type'], 'text/csv');
      expect(table['size'], 8);
      expect(utf8.decode(gateway.uploads[table['upload_id']]!), 'a,b\n1,2\n');

      for (final e in ['IT-E', 'IT-F']) {
        final id = service.sandboxes.sandboxIdOf(e)!;
        final (ds, _) = await h.delete('/v1/executions/$e', {
          'protocol': protocolName,
          'generation': 1,
        });
        expect(ds, 200);
        expect(await docker.inspectContainer(id), isNull);
      }
    });
  });
}

/// A small HTTP client of the agent service.
class _Client {
  _Client(this.port);
  final int port;
  final HttpClient _http = HttpClient();

  void close() => _http.close(force: true);

  Future<(int, Map<String, Object?>)> _send(
    String method,
    String path, [
    Object? body,
  ]) async {
    final r = await _http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    r.headers
      ..set('Authorization', 'Bearer $testKey')
      ..set('X-Agent-Run-Token', runToken)
      ..contentType = ContentType.json;
    if (body != null) r.write(jsonEncode(body));
    final res = await r.close();
    final text = await utf8.decodeStream(res);
    return (
      res.statusCode,
      text.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(text) as Map).cast<String, Object?>(),
    );
  }

  Future<(int, Map<String, Object?>)> post(String path, Object body) =>
      _send('POST', path, body);
  Future<(int, Map<String, Object?>)> delete(String path, Object body) =>
      _send('DELETE', path, body);

  Future<String> start(Map<String, Object?> op) async {
    final (s, j) = await post('/v1/operations', op);
    if (s != 202) throw StateError('$s ${jsonEncode(j)}');
    return j['run_id'] as String;
  }

  Future<Map<String, Object?>> waitEnded(String runId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (true) {
      final (_, j) = await _send('GET', '/v1/runs/$runId');
      if (j['status'] != 'running') return j;
      if (DateTime.now().isAfter(deadline)) throw StateError('run did not end');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
