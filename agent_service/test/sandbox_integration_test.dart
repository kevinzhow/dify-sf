// Real sandbox integration test: Docker on this machine, the local images
// langgenius/dify-agent-local-sandbox:1.17.1, dart:3.13 and ubuntu/squid
// (never pulled here).
//
//   AGENT_SANDBOX_IT=1 dart test -j 1 test/sandbox_integration_test.dart
//
// Every sandbox gets its own internal inhibit_ipv4 network from the
// supervisor, so this process (on the host) cannot reach any sandbox. A relay
// container (test/it_relay.dart, published on 127.0.0.1) plays the agent
// service peer and forwards the test's shellctl requests; a Squid container
// with the repository's configuration plays the proxy peer. The sandbox pool
// is AGENT_SANDBOX_IT_POOL (default 10.213.0.0/16); the relay's own network is
// a free /28 of AGENT_SANDBOX_IT_RELAY_POOL (default 10.214.0.0/16).
//
// Everything it creates is labelled `dify-sf.test=<random>` and removed in
// tearDownAll, also on failure. Nothing else on the host is touched.
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/supervisor.dart';
import 'package:agent_service/testing.dart';
import 'package:http/io_client.dart';
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
  final pool = Ipv4Net.tryParse(
    Platform.environment['AGENT_SANDBOX_IT_POOL'] ?? '10.213.0.0/16',
  )!;
  final relayPool = Ipv4Net.tryParse(
    Platform.environment['AGENT_SANDBOX_IT_RELAY_POOL'] ?? '10.214.0.0/16',
  )!;
  final repo = Directory.current.parent.path;
  late DockerClient docker;
  late String relayNetwork;
  late String relayName;
  late String relayId;
  late String proxyName;
  late String proxyId;
  late int relayPort;
  late SandboxSupervisor supervisor;
  late Uri supervisorUrl;
  late ScriptedGateway gateway;
  late Directory dataDir;

  void log(String m) => stderr.writeln('[it] $m');

  /// A free /28 of [range]: overlapping no existing network.
  Future<Ipv4Net> freeSubnet(Ipv4Net range) async {
    final used = [
      for (final n in await docker.listNetworks())
        for (final c in ((n['IPAM'] as Map?)?['Config'] as List?) ?? const [])
          ?Ipv4Net.tryParse('${(c as Map)['Subnet']}'),
    ];
    for (var i = 0; i < range.size ~/ 16; i++) {
      final candidate = range.subnet(i, 28);
      if (!used.any(candidate.overlaps)) return candidate;
    }
    throw StateError('no free /28 in $range');
  }

  Future<String> createNetwork(
    String name,
    Ipv4Net subnet, {
    required bool internal,
  }) => docker.createNetwork({
    'Name': name,
    'Driver': 'bridge',
    'Internal': internal,
    'Labels': {'dify-sf.test': label},
    'IPAM': {
      'Config': [
        {'Subnet': '$subnet', 'Gateway': subnet.host(1)},
      ],
    },
  });

  /// Creates and starts a labelled helper container; returns its ID.
  Future<String> helper(String name, Map<String, Object?> payload) async {
    final id = await docker.createContainer(name, {
      ...payload,
      'Labels': {'dify-sf.test': label},
    });
    if (id == null) throw StateError('container $name exists');
    await docker.startContainer(id);
    return id;
  }

  SupervisorConfig supervisorConfig() => SupervisorConfig(
    key: supervisorKey,
    agentPeers: [relayName],
    proxyPeer: proxyName,
    subnetPool: '$pool',
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

  /// shellctl requests go through the relay.
  IOClient viaRelay() =>
      IOClient(HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$relayPort');

  setUpAll(() async {
    if (!enabled) return;
    docker = DockerClient('/var/run/docker.sock');
    await docker.ping();
    relayNetwork = 'dify-sf-it-$label-relay';
    await createNetwork(
      relayNetwork,
      await freeSubnet(relayPool),
      internal: false,
    );
    relayName = 'dify-sf-it-$label-relay';
    relayId = await helper(relayName, {
      'Image': 'dart:3.13',
      'Cmd': ['dart', '/relay/it_relay.dart', '8080', '$pool'],
      'ExposedPorts': {'8080/tcp': <String, Object?>{}},
      'HostConfig': {
        'NetworkMode': relayNetwork,
        'Binds': [
          '${Directory.current.path}/test/it_relay.dart:/relay/it_relay.dart:ro',
        ],
        'PortBindings': {
          '8080/tcp': [
            {'HostIp': '127.0.0.1', 'HostPort': ''},
          ],
        },
        'Memory': 256 * 1024 * 1024,
        'MemorySwap': 256 * 1024 * 1024,
        'CapDrop': ['ALL'],
        'SecurityOpt': ['no-new-privileges:true'],
      },
    });
    proxyName = 'dify-sf-it-$label-proxy';
    proxyId = await helper(proxyName, {
      'Image': 'ubuntu/squid:latest',
      'HostConfig': {
        'NetworkMode': relayNetwork,
        'Binds': [
          '$repo/docker/agent_sandbox_proxy/squid.conf:/etc/squid/squid.conf:ro',
          '$repo/docker/agent_sandbox_proxy/allowlist.txt:/etc/squid/allowlist.txt:ro',
        ],
        'Memory': 128 * 1024 * 1024,
        'MemorySwap': 128 * 1024 * 1024,
      },
    });
    final relay = (await docker.inspectContainer(relayId))!;
    final ports = (relay['NetworkSettings'] as Map)['Ports'] as Map;
    relayPort = int.parse(
      ((ports['8080/tcp'] as List).first as Map)['HostPort'] as String,
    );
    final ready = HttpClient();
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      try {
        final r = await (await ready.get(
          '127.0.0.1',
          relayPort,
          '/ready',
        )).close();
        await r.drain<void>();
        if (r.statusCode == 200) break;
      } on IOException {
        // Not up yet.
      }
      if (DateTime.now().isAfter(deadline)) throw StateError('relay not up');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    ready.close();
    supervisor = SandboxSupervisor(supervisorConfig(), log: log);
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
        final id = n['Id'] as String;
        final inspect = await cleanup.inspectNetwork(id);
        for (final c in ((inspect?['Containers'] as Map?) ?? const {}).keys) {
          await cleanup.disconnectNetwork(id, c as String);
        }
        await cleanup.removeNetwork(id);
      }
    } finally {
      cleanup.close();
    }
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    final checks = <String, List<String>>{
      'ps': ['ps', '-a', '--filter', 'label=$labelFilter'],
      'network': ['network', 'ls', '--filter', 'label=$labelFilter'],
      'volume': ['volume', 'ls', '--filter', 'label=$labelFilter'],
    };
    for (final MapEntry(:key, :value) in checks.entries) {
      final r = await Process.run('docker', value);
      log('cleanup check: docker ${value.join(' ')}\n${r.stdout}');
      expect(
        (r.stdout as String).trim().split('\n'),
        hasLength(1),
        reason: key,
      );
    }
  });

  SandboxManager newManager() => SandboxManager(
    supervisor: SupervisorClient(supervisorUrl, supervisorKey),
    store: RunStore(newDataDir().path)..load(),
    shellctlHttpClient: viaRelay,
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
curl -sS -o /dev/null -w "peer=%{http_code}\\n" -m 5 --noproxy '*' http://$ipA:5004/v1/jobs 2>&1; echo peer_rc=\$?
timeout 5 bash -c "exec 3<>/dev/tcp/$ipA/5004" 2>&1; echo peer_tcp_rc=\$?
curl -sS -o /dev/null -w "via_proxy=%{http_code}\\n" -m 10 http://$ipA:5004/v1/jobs 2>&1
echo "proxy=\$HTTP_PROXY"
''');
      expect(outB, isNot(contains('secret-A')));
      expect(outB, contains('No such file'));
      expect(outB, contains('Permission denied'));
      expect(outB, isNot(contains('jobs_rc=0')));
      expect(outB, contains('environ_rc=1'));
      expect(outB, isNot(contains('home_root_rc=0')));
      // Not even a connection: the sandboxes share no network.
      expect(outB, contains('peer=000'));
      expect(outB, matches(RegExp(r'peer_rc=(7|28)\b')));
      expect(outB, isNot(contains('peer_tcp_rc=0')));
      // The proxy, attached to both networks, refuses private destinations.
      expect(outB, contains('via_proxy=403'));
      final subnetB = b.grant.gateway!.replaceFirst(RegExp(r'\.\d+$'), '');
      expect(outB, contains('proxy=http://$subnetB.'));
      expect(a.grant.gateway, isNot(b.grant.gateway));
      for (final (key, sandbox) in [('IT-A', a), ('IT-B', b)]) {
        final net = (await docker.inspectNetwork(
          supervisor.containerName(key),
        ))!;
        expect(net['Internal'], isTrue);
        expect((net['Options'] as Map)[inhibitIpv4Option], 'true');
        expect((net['Labels'] as Map)['dify-sf.test'], label);
        expect(((net['Containers'] as Map?) ?? const {}).keys.toSet(), {
          sandbox.sandboxId,
          relayId,
          proxyId,
        }, reason: 'only the sandbox, the agent peer and the proxy');
      }
      expect(await sa.close(), isTrue);
      expect(await sb.close(), isTrue);

      // DELETE path: release removes the container and its network.
      await manager.release('IT-A');
      expect(await docker.inspectContainer(a.sandboxId), isNull);
      expect(
        await docker.inspectNetwork(supervisor.containerName('IT-A')),
        isNull,
      );
    });

    test('direct egress fails; the host is unreachable: the probes pass on '
        'the sandbox network, and catch a network where the host has an '
        'address', () async {
      final manager = newManager();
      final client = inner();
      addTearDown(() async {
        await manager.release('IT-N');
        client.close();
        manager.close();
      });
      final sandbox = await manager.open(request('IT-N'), client);
      expect(sandbox.probed, isTrue);
      expect(manager.health, 'isolated');
      final gw = sandbox.grant.gateway!;
      final s = ShellSession(sandbox, {});
      final out = await run(s, '''
timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>&1; echo tcp_rc=\$?
getent hosts pypi.org; echo dns_rc=\$?
timeout 5 curl -s -m 4 --noproxy '*' -o /dev/null https://pypi.org; echo curl_rc=\$?
for p in 22 80 5432; do timeout 3 bash -c "exec 3<>/dev/tcp/$gw/\$p" 2>&1; echo gw_\${p}_rc=\$?; done
timeout 3 bash -c "exec 3<>/dev/tcp/172.17.0.1/22" 2>&1; echo docker0_rc=\$?
cat /proc/net/if_inet6; echo if_inet6_done
''');
      expect(out, isNot(contains('tcp_rc=0')));
      expect(out, isNot(contains('dns_rc=0')));
      expect(out, isNot(contains('curl_rc=0')));
      expect(out, isNot(contains(RegExp(r'gw_\d+_rc=0'))));
      expect(out, isNot(contains('docker0_rc=0')));
      expect(
        out.split('if_inet6_done').first,
        isNot(contains('eth0')),
        reason: 'no IPv6 on the sandbox interface',
      );
      expect(await s.close(), isTrue);

      // The same image on an internal network *without* inhibit_ipv4, where
      // the host owns the gateway address: a listener there is found.
      final subnet = await freeSubnet(relayPool);
      final plain = 'dify-sf-it-$label-plain';
      await createNetwork(plain, subnet, internal: true);
      final listener = await ServerSocket.bind(subnet.host(1), 0);
      addTearDown(listener.close);
      listener.listen((c) => c.destroy());
      final payload = supervisor.createPayload(
        'IT-H',
        'tok',
        network: plain,
        subnet: subnet,
      );
      final id = await helper('dify-sf-it-$label-plain-sbx', payload);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (((await docker.inspectContainer(id))!['State']
              as Map)['Running'] !=
          true) {
        if (DateTime.now().isAfter(deadline)) fail('helper did not start');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final (code, text) = await docker.exec(id, [
        'bash',
        '-c',
        ExecutionSandbox.hostProbeScript(
          gateway: subnet.host(1),
          ports: [22, listener.port],
        ),
      ]);
      log('probe on a network where the host has an address: $code\n$text');
      final seen = ExecutionSandbox.parseProbes(text);
      expect(
        seen['host_reachable'],
        contains('${subnet.host(1)}:${listener.port}'),
      );
      await docker.removeContainer(id);
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
time.sleep(1)  # let shellctl finish starting the job before the PIDs run out
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
        shellctlHttpClient: viaRelay,
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
        expect(
          await docker.inspectNetwork(supervisor.containerName(e)),
          isNull,
        );
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
