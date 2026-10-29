// Real disk-workspace test: Docker on this machine, a free loop device and
// the local images langgenius/dify-agent-local-sandbox:1.17.1 (sandbox and
// peer) and a pinned tool image with python3, mke2fs and debugfs (never
// pulled here).
//
//   AGENT_DISK_IT=1 AGENT_DISK_IT_ROOT=/var/tmp/<you>/diskws-test \
//   AGENT_DISK_IT_DEVICE=/dev/loop13 \
//   AGENT_DISK_IT_TOOL_IMAGE=<name>@sha256:<64 hex> \
//     dart test -j 1 test/disk_workspace_integration_test.dart
//
// The device must be unbound (checked first; the helper also refuses a bound
// one atomically). Everything created is labelled `dify-sf.test=<random>`;
// tearDownAll removes it and releases only this test's binding (by device
// and inode).
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_service/supervisor.dart';
import 'package:agent_service/agent_service.dart';
import 'package:genkit/genkit.dart';
import 'package:test/test.dart';

final env = Platform.environment;
final enabled = env['AGENT_DISK_IT'] == '1';
const sandboxImage =
    'langgenius/dify-agent-local-sandbox@sha256:'
    'f4d404c9dcdf80bd72f65e84c3f2bbd1f3404fd4b363db837176da8aaf771b1d';

void main() {
  final random = Random.secure();
  final label = List.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  final device = env['AGENT_DISK_IT_DEVICE'] ?? '/dev/loop13';
  final root = '${env['AGENT_DISK_IT_ROOT'] ?? '/var/tmp/diskws-test'}/$label';
  late DockerClient docker;
  late String peer;
  late Directory scratch;
  SandboxSupervisor? supervisor;

  void log(String m) => stderr.writeln('[disk-it] $m');

  bool deviceBound() =>
      Directory('/sys/block/${device.split('/').last}/loop').existsSync();

  SupervisorConfig config() => SupervisorConfig(
    key: 'k',
    agentPeers: [peer],
    labelKey: 'dify-sf.test',
    labelValue: label,
    namePrefix: 'dify-sf-dit-$label-',
    statePath: '${scratch.path}/state.json',
    profiles: ExecutorProfiles.parse({
      'version': 1,
      'profiles': {
        'default': {'image': sandboxImage},
        'modelling': {
          'image': sandboxImage,
          'network': {'egress': 'none'},
          'workspace': {'backing': 'disk'},
          // As tmpfs this would be refused: 256 + 64 >= 192.
          'limits': {'memory_mb': 192, 'home_mb': 64, 'workspace_mb': 256},
        },
        if (env['AGENT_DISK_IT_CODEX_DIR'] != null)
          'reviewer': {
            'image': env['AGENT_DISK_IT_REVIEW_IMAGE']!,
            'mounts': [
              {
                'source': env['AGENT_DISK_IT_CODEX_DIR'],
                'target': '/opt/codex',
              },
            ],
            'network': {'egress': 'none'},
            'limits': {
              'cpus': 1,
              'memory_mb': 768,
              'pids': 256,
              'home_mb': 256,
              'workspace_mb': 128,
              'max_turns_max': 30,
              'timeout_seconds_max': 600,
            },
          },
      },
    }),
    disk: DiskWorkspaceConfig(
      root: root,
      hostRoot: root,
      toolImage: env['AGENT_DISK_IT_TOOL_IMAGE']!,
      devices: [device],
      budgetMb: 1024,
      minFreeMb: 1024,
    ),
  );

  Future<SandboxSupervisor> startSupervisor() async {
    final s = SandboxSupervisor(config(), docker: docker, log: log);
    await s.start(address: '127.0.0.1', port: 0);
    return s;
  }

  Future<(int, String)> sh(String id, String script) =>
      docker.exec(id, ['sh', '-c', script]);

  setUpAll(() async {
    if (!enabled) return;
    docker = DockerClient('/var/run/docker.sock');
    await docker.ping();
    if (deviceBound()) {
      throw StateError('$device is bound to something: not used');
    }
    scratch = Directory.systemTemp.createTempSync('disk-it-');
    Directory(root).createSync(recursive: true);
    expect(Process.runSync('chmod', ['700', root]).exitCode, 0);
    peer = 'dify-sf-dit-$label-peer';
    final id = await docker.createContainer(peer, {
      'Image': sandboxImage,
      'Entrypoint': ['sleep', 'infinity'],
      'Labels': {'dify-sf.test': label},
      'HostConfig': {'Memory': 32 * 1024 * 1024},
    });
    await docker.startContainer(id!);
  });

  tearDownAll(() async {
    if (!enabled) return;
    await supervisor?.stop();
    final d = DockerClient('/var/run/docker.sock');
    // A fresh supervisor's sweep releases leftovers of this test only.
    final cleaner = SandboxSupervisor(config(), docker: d, log: log);
    File('${scratch.path}/state.json').writeAsStringSync('{"sandboxes":{}}');
    await cleaner.sweep();
    for (final c in await d.listContainers(['dify-sf.test=$label'])) {
      await d.removeContainer(c['Id'] as String);
    }
    for (final l in cleaner.disks!.leases()) {
      log('leftover lease ${l.hash} ${l.state}');
    }
    for (final v in await d.listVolumes(['dify-sf.test=$label'])) {
      log('leftover volume ${v['Name']}');
    }
    d.close();
    scratch.deleteSync(recursive: true);
    final dir = Directory(root);
    if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
  });

  test(
    'create, write, ENOSPC at the cap, container replaced with the files '
    'kept, supervisor restart, cleanup leaves nothing',
    skip: enabled ? false : 'set AGENT_DISK_IT=1',
    () async {
      supervisor = await startSupervisor();
      final a = await supervisor!.acquire('exec-1', profileName: 'modelling');
      log('acquired ${a['sandbox_id']} (${a['workspace']})');
      expect(a['workspace'], 'disk');
      expect(a['workspace_kept_from'], isEmpty);
      final first = a['sandbox_id'] as String;
      final lease = supervisor!.disks!.leases().single;
      expect(lease.state, 'ready');
      expect(lease.device, device);
      expect(deviceBound(), isTrue);

      final inspect = (await docker.inspectContainer(first))!;
      final host = inspect['HostConfig'] as Map;
      expect((host['Tmpfs'] as Map).keys, ['/home/dify']);
      expect(host['CapAdd'], isNull);
      final mount = (inspect['Mounts'] as List).cast<Map>().singleWhere(
        (m) => m['Destination'] == '/workspace',
      );
      expect(mount['Type'], 'volume');
      expect(mount['Name'], lease.volume);

      var (code, out) = await sh(
        first,
        'id -u; stat -c "%a %u" /workspace; ls -A /workspace | wc -l; '
        'df -B1M --output=fstype,size /workspace | tail -1; '
        'echo kept > /workspace/keep.txt && sync',
      );
      log('inside: $out');
      expect(code, 0);
      final lines = out.trim().split('\n');
      expect(lines[0], '1000');
      expect(lines[1], '700 1000');
      expect(lines[2], '0'); // no lost+found
      expect(lines[3], contains('ext4'));

      (code, out) = await sh(
        first,
        'dd if=/dev/zero of=/workspace/fill bs=1M count=400 2>&1; '
        'echo "exit=\$?"; ls -l /workspace/fill; rm /workspace/fill',
      );
      log('fill: $out');
      expect(out, contains('No space left on device'));
      expect(out, isNot(contains('exit=0')));

      // The container stops (e.g. a host restart): the next acquire
      // replaces it and keeps the files.
      await docker.send('POST', '/containers/$first/stop', query: {'t': '2'});
      final b = await supervisor!.acquire('exec-1', profileName: 'modelling');
      final second = b['sandbox_id'] as String;
      expect(second, isNot(first));
      expect(b['created'], isTrue);
      expect(b['workspace_kept_from'], [first]);
      (code, out) = await sh(second, 'cat /workspace/keep.txt');
      expect((code, out.trim()), (0, 'kept'));

      // A supervisor restart keeps the known sandbox and its workspace.
      await supervisor!.stop();
      docker = DockerClient('/var/run/docker.sock');
      supervisor = await startSupervisor();
      final c = await supervisor!.acquire('exec-1', profileName: 'modelling');
      expect(c['sandbox_id'], second);
      expect(c['created'], isFalse);
      expect(c['workspace_kept_from'], [first]);

      // Release: sandbox, volume, own loop binding and directory are gone.
      expect(await supervisor!.remove(second), isTrue);
      expect(await docker.inspectContainer(second), isNull);
      expect(await docker.inspectVolume(lease.volume), isNull);
      expect(deviceBound(), isFalse);
      expect(Directory(root).listSync(), isEmpty);
      // Idempotent: a repeated removal of either sandbox finds nothing.
      expect(await supervisor!.remove(second), isFalse);
      expect(await supervisor!.remove(first), isFalse);
    },
  );

  test(
    'retained workflow files survive parking and restart without holding the only slot',
    skip: enabled ? false : 'set AGENT_DISK_IT=1',
    () async {
      final a = await supervisor!.acquire(
        'retained-round-1',
        profileName: 'modelling',
        workspaceKey: 'workflow-A/node-A',
      );
      final first = a['sandbox_id'] as String;
      final workspace = a['workspace'] as Map;
      final hash = workspace['id'] as String;
      final file = File('$root/$hash/workspace.img');
      final identity = await DiskWorkspaces.statIdentity(file.path);
      var result = await sh(
        first,
        "mkdir -p /workspace/.dify-sf/codex && echo history > /workspace/.dify-sf/codex/rollout.jsonl && echo original-model > /workspace/model.blend && sync",
      );
      expect(result.$1, 0);
      await supervisor!.remove(first);
      expect(deviceBound(), isFalse);
      expect(supervisor!.disks!.read(hash)!.state, 'parked');
      expect(file.existsSync(), isTrue);
      final b = await supervisor!.acquire(
        'another-workflow',
        profileName: 'modelling',
      );
      expect(deviceBound(), isTrue);
      await supervisor!.remove(first); // late duplicate from the old round
      expect(deviceBound(), isTrue);
      expect(
        (await sh(
          b['sandbox_id'] as String,
          'test ! -e /workspace/model.blend',
        )).$1,
        0,
      );
      await supervisor!.stop();
      docker = DockerClient('/var/run/docker.sock');
      supervisor = await startSupervisor();
      expect(supervisor!.disks!.read(hash)!.state, 'parked');
      await supervisor!.remove(b['sandbox_id'] as String);
      final second = await supervisor!.acquire(
        'retained-round-2',
        profileName: 'modelling',
        workspaceKey: 'workflow-A/node-A',
      );
      expect(second['workspace'], {
        'retained': true,
        'reused': true,
        'id': hash,
      });
      expect(await DiskWorkspaces.statIdentity(file.path), identity);
      result = await sh(
        second['sandbox_id'] as String,
        'cat /workspace/model.blend /workspace/.dify-sf/codex/rollout.jsonl',
      );
      expect(result.$1, 0);
      expect(result.$2.trim(), 'original-model\nhistory');
      await supervisor!.remove(first);
      expect(deviceBound(), isTrue);
      await supervisor!.remove(second['sandbox_id'] as String);
      final c = await supervisor!.acquire(
        'other-round',
        profileName: 'modelling',
      );
      expect(await supervisor!.releaseWorkspace(hash), isTrue);
      expect(file.existsSync(), isFalse);
      expect(deviceBound(), isTrue);
      expect(
        (await sh(
          c['sandbox_id'] as String,
          'echo still-mounted > /workspace/new.txt',
        )).$1,
        0,
      );
      await supervisor!.remove(c['sandbox_id'] as String);
      expect(deviceBound(), isFalse);
      expect(supervisor!.disks!.leases(), isEmpty);
      log(
        'retained workflow round trip, isolation, restart and final purge passed',
      );
    },
  );

  test(
    'single disk slot: next execution waits, cancellation and timeout leave '
    'no resources, and an image reviewer needs no disk slot',
    skip: enabled && env['AGENT_DISK_IT_CODEX_DIR'] != null
        ? false
        : 'set AGENT_DISK_IT=1 and AGENT_DISK_IT_CODEX_DIR/REVIEW_IMAGE',
    () async {
      final s = supervisor!;
      final url = Uri.parse('http://127.0.0.1:${s.port}');
      final client = SupervisorClient(url, 'k');
      addTearDown(client.close);
      final builder = await client.acquire('builder', profile: 'modelling');
      final lease = s.disks!.leases().single;
      expect(lease.device, device);
      log('single-slot builder acquired; reviewer starts while it is held');

      // Exact old behaviour: one acquire, immediately rejected while the
      // previous execution's asynchronous cleanup still holds the only slot.
      final immediate = SupervisorClient(
        url,
        'k',
        diskSlotWaitTimeout: Duration.zero,
      );
      addTearDown(immediate.close);
      await expectLater(
        immediate.acquire('old-critic', profile: 'modelling'),
        throwsA(
          isA<SandboxFailure>().having(
            (e) => e.supervisorCode,
            'code',
            'disk_pool_busy',
          ),
        ),
      );
      expect(s.disks!.leases().single.hash, lease.hash);

      // No kit, GPU, skill or disk workspace. The existing image is reused;
      // image size does not reserve process memory.
      final review = await client.acquire('light-critic', profile: 'reviewer');
      expect(s.disks!.leases().single.hash, lease.hash);
      final inspect = (await docker.inspectContainer(review.sandboxId))!;
      final host = inspect['HostConfig'] as Map;
      expect(host['Memory'], 768 * 1024 * 1024);
      expect((host['Tmpfs'] as Map).keys, contains('/workspace'));
      expect(host['Devices'], anyOf(isNull, isEmpty));
      final mounts = (inspect['Mounts'] as List).cast<Map>();
      expect(
        mounts.any((m) => m['Destination'] == '/opt/colvalley-3d'),
        isFalse,
      );
      expect(
        mounts.singleWhere((m) => m['Destination'] == '/opt/codex')['RW'],
        isFalse,
      );
      final (code, out) = await sh(review.sandboxId, '''
set -eu
/opt/codex/codex --version
test ! -e /opt/colvalley-3d
/opt/cv3d-venv/bin/python - <<'PY'
from PIL import Image
p='/workspace/image.png'
Image.new('RGB',(96,72),(20,50,80)).save(p)
im=Image.open(p).crop((10,10,40,30))
assert im.size==(30,20) and im.getpixel((0,0))==(20,50,80)
im.save('/workspace/crop.png')
print('image-crop-ok')
PY
''');
      expect(code, 0, reason: out);
      expect(out, contains('codex-cli 0.163.0'));
      expect(out, contains('image-crop-ok'));
      expect(await s.remove(review.sandboxId), isTrue);

      final short = SupervisorClient(
        url,
        'k',
        diskSlotWaitTimeout: const Duration(milliseconds: 600),
        diskSlotRetryInterval: const Duration(milliseconds: 100),
      );
      addTearDown(short.close);
      await expectLater(
        short.acquire('expired', profile: 'modelling'),
        throwsA(
          isA<SandboxFailure>().having(
            (e) => e.supervisorCode,
            'code',
            'disk_pool_busy',
          ),
        ),
      );

      final cancel = CancellationController();
      final waiting = client.acquire(
        'cancelled',
        profile: 'modelling',
        cancel: cancel.token,
      );
      final cancelled = expectLater(
        waiting,
        throwsA(isA<CancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancel.cancel('cancel');
      await cancelled.timeout(const Duration(seconds: 1));
      expect((await s.list()).map((b) => b['sandbox_id']), [builder.sandboxId]);
      expect(s.disks!.leases().single.hash, lease.hash);
      for (final key in ['old-critic', 'expired', 'cancelled']) {
        expect(await docker.inspectNetwork(s.containerName(key)), isNull);
      }

      var finished = false;
      final next = client.acquire('next-builder', profile: 'modelling').then((
        g,
      ) {
        finished = true;
        return g;
      });
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(finished, isFalse);
      log('next execution still waiting; now release the earlier disk slot');
      expect(await s.remove(builder.sandboxId), isTrue);
      final granted = await next.timeout(const Duration(seconds: 30));
      expect(granted.created, isTrue);
      expect(s.disks!.leases().single.device, device);
      expect(s.disks!.leases().single.hash, isNot(lease.hash));
      expect(await s.remove(granted.sandboxId), isTrue);
      expect(await s.list(), isEmpty);
      expect(s.disks!.leases(), isEmpty);
      expect(deviceBound(), isFalse);
      log(
        'single-slot handoff and concurrent lightweight image reviewer passed',
      );
    },
  );
}
