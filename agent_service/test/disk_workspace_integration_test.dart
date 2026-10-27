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

import 'dart:io';
import 'dart:math';

import 'package:agent_service/supervisor.dart';
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
}
