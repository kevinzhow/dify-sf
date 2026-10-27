/// Disk-backed `/workspace` (docs/agent-v2.md, "Disk workspaces"): per
/// execution a fixed-size ext4 image file in a dedicated host directory,
/// bound to a loop device from an explicit pool by a short-lived helper
/// container, and mounted into the sandbox as a labelled Docker local volume.
///
/// The supervisor itself gets no capability: only the helper (pinned tool
/// image, `SYS_ADMIN` only, no network, no Docker socket, read-only root)
/// sees one image file and one loop device. Every helper operation checks
/// the image file's device and inode against the value the supervisor read
/// from its own copy, and a loop device's owner by `LOOP_GET_STATUS64`
/// device and inode (never the backing file name, which is `/` with
/// single-file bind mounts).
///
/// Leases (`<root>/<sha256 of the execution key>/lease.json`, written
/// atomically) make creation, reuse and release restartable. A device or a
/// volume that is not provably this execution's is never detached, removed
/// or reused.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'docker.dart';
import 'supervisor.dart' show SupervisorConfigError, SupervisorError;

/// Label of disk workspace volumes: the execution key's SHA-256.
const workspaceLabel = 'dify-sf.sandbox.workspace';

/// Label of helper containers: the execution key's SHA-256.
const workspaceHelperLabel = 'dify-sf.sandbox.workspace-helper';

const _mib = 1024 * 1024;

final _loopDevice = RegExp(r'^/dev/loop[0-9]{1,4}$');
final _pinnedImage = RegExp(r'^[^\s@]+@sha256:[a-f0-9]{64}$');
final _hashName = RegExp(r'^[0-9a-f]{64}$');

/// Deployment settings (`SANDBOX_DISK_*`), read at start.
class DiskWorkspaceConfig {
  DiskWorkspaceConfig({
    required this.root,
    required this.hostRoot,
    required this.toolImage,
    required this.devices,
    required this.budgetMb,
    this.minFreeMb = 0,
  }) {
    for (final (name, path) in [
      ('SANDBOX_DISK_ROOT', root),
      ('SANDBOX_DISK_HOST_ROOT', hostRoot),
    ]) {
      if (!path.startsWith('/') ||
          path == '/' ||
          path.endsWith('/') ||
          path
              .split('/')
              .skip(1)
              .any((s) => s.isEmpty || s == '.' || s == '..') ||
          path.contains(RegExp(r'[\u0000-\u001f,:]'))) {
        throw SupervisorConfigError(
          '$name must be an absolute, normalized directory other than /',
        );
      }
    }
    if (!_pinnedImage.hasMatch(toolImage)) {
      throw SupervisorConfigError(
        'SANDBOX_DISK_TOOL_IMAGE must be pinned by digest (name@sha256:<64 hex>)',
      );
    }
    if (devices.isEmpty ||
        devices.any((d) => !_loopDevice.hasMatch(d)) ||
        devices.toSet().length != devices.length) {
      throw SupervisorConfigError(
        'SANDBOX_DISK_LOOP_DEVICES must list distinct /dev/loopN devices',
      );
    }
    if (budgetMb < 1 || minFreeMb < 0) {
      throw SupervisorConfigError(
        'SANDBOX_DISK_BUDGET_MB must be positive, SANDBOX_DISK_MIN_FREE_MB '
        'not negative',
      );
    }
  }

  /// The dedicated directory as the supervisor sees it.
  final String root;

  /// The same directory on the Docker host (bind source of the helper).
  final String hostRoot;

  /// Has `python3`, `mke2fs` and `debugfs`; pinned by digest.
  final String toolImage;

  /// The loop devices this supervisor may bind, in order of preference.
  final List<String> devices;

  /// Sum of the sizes of all workspace images.
  final int budgetMb;

  /// Free space that must remain on the root's filesystem after a new image.
  final int minFreeMb;

  /// Null when `SANDBOX_DISK_ROOT` is not set.
  static DiskWorkspaceConfig? fromEnv(String? Function(String) opt) {
    final root = opt('SANDBOX_DISK_ROOT');
    if (root == null) return null;
    String req(String name) =>
        opt(name) ??
        (throw SupervisorConfigError(
          '$name is required with SANDBOX_DISK_ROOT',
        ));
    int mb(String name, {int? fallback}) {
      final v = opt(name);
      if (v == null && fallback != null) return fallback;
      final n = int.tryParse(v ?? req(name));
      if (n == null) throw SupervisorConfigError('$name must be an integer');
      return n;
    }

    return DiskWorkspaceConfig(
      root: root,
      hostRoot: req('SANDBOX_DISK_HOST_ROOT'),
      toolImage: req('SANDBOX_DISK_TOOL_IMAGE'),
      devices: [
        for (final d in req('SANDBOX_DISK_LOOP_DEVICES').split(','))
          if (d.trim().isNotEmpty) d.trim(),
      ],
      budgetMb: mb('SANDBOX_DISK_BUDGET_MB'),
      minFreeMb: mb('SANDBOX_DISK_MIN_FREE_MB', fallback: 1024),
    );
  }
}

/// What a helper run reported: its exit code and its JSON line (`state`,
/// and `dev`/`ino` of the image file where relevant).
typedef LoopResult = ({int exitCode, Map<String, Object?> out});

/// Runs one loop operation on one image file and one device.
abstract interface class LoopHelper {
  /// [op] is `prepare` (the empty image is checked against the free space,
  /// allocated, formatted and bound), `attach` (bind an existing image;
  /// already bound to it is fine), `detach` (only when bound to this image)
  /// or `check`. [identity] is the image's device and inode as the
  /// supervisor sees it; the helper refuses another file.
  Future<LoopResult> run(
    String hash,
    String op,
    String device,
    ({int dev, int ino}) identity, [
    List<String> args,
  ]);
}

/// The helper's program (python3 -I -c). Exit codes: 0 done, 3 the device is
/// bound to another file, 4 not enough free space, 5 identity refused, 6
/// not a regular image file or not a loop device.
const loopHelperScript = r'''
import errno, fcntl, json, os, stat, struct, subprocess, sys
SET_FD, CLR_FD, GET_STATUS64 = 0x4C00, 0x4C01, 0x4C05
def done(code, state, **kw):
    kw['state'] = state
    print(json.dumps(kw), flush=True)
    sys.exit(code)
op, device, want_dev, want_ino = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
img = os.open('/disk.img', os.O_RDWR)
st = os.fstat(img)
if not stat.S_ISREG(st.st_mode):
    done(6, 'not_a_file')
mine = (st.st_dev, st.st_ino)
if mine != (want_dev, want_ino):
    done(5, 'image_identity', dev=mine[0], ino=mine[1])
d = os.open(device, os.O_RDWR)
ds = os.fstat(d)
if not stat.S_ISBLK(ds.st_mode) or os.major(ds.st_rdev) != 7:
    done(6, 'not_a_loop_device')
def bound():
    buf = bytearray(232)
    try:
        fcntl.ioctl(d, GET_STATUS64, buf)
    except OSError as e:
        if e.errno == errno.ENXIO:
            return None
        raise
    return struct.unpack_from('=QQ', buf)
def attach():
    try:
        fcntl.ioctl(d, SET_FD, img)
    except OSError as e:
        if e.errno == errno.EBUSY:
            done(3, 'busy')
        raise
    if bound() != mine:
        fcntl.ioctl(d, CLR_FD, 0)  # bound by this call: releasing it is safe
        done(5, 'identity_mismatch')
    done(0, 'attached', dev=mine[0], ino=mine[1])
cur = bound()
if op == 'check':
    done(0, 'free' if cur is None else 'own' if cur == mine else 'other')
if op == 'detach':
    if cur is None:
        done(0, 'free')
    if cur != mine:
        done(5, 'other')
    fcntl.ioctl(d, CLR_FD, 0)
    done(0, 'detached')
if op == 'attach':
    if cur == mine:
        done(0, 'attached', dev=mine[0], ino=mine[1])
    if cur is not None:
        done(3, 'busy')
    if st.st_size == 0:
        done(6, 'not_formatted')
    attach()
if op == 'prepare':
    size, min_free, uid, gid = map(int, sys.argv[5:9])
    if cur is not None:
        done(3, 'busy')
    if st.st_size != 0:
        done(5, 'not_empty')
    v = os.statvfs('/disk.img')
    if v.f_bavail * v.f_frsize < size + min_free:
        done(4, 'no_space', available=v.f_bavail * v.f_frsize)
    os.posix_fallocate(img, 0, size)
    def run(*a):
        subprocess.run(list(a), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('mke2fs', '-q', '-t', 'ext4', '-F', '-m', '0', '-E', 'nodiscard,root_owner=%d:%d' % (uid, gid), '/disk.img')
    run('debugfs', '-w', '-R', 'rmdir lost+found', '/disk.img')
    run('debugfs', '-w', '-R', 'set_inode_field / mode 040700', '/disk.img')
    attach()
done(2, 'unknown_op')
''';

/// [LoopHelper] as a short-lived container through the Docker API.
class DockerLoopHelper implements LoopHelper {
  DockerLoopHelper(
    this.docker,
    this.config, {
    required this.labelKey,
    required this.labelValue,
    required this.namePrefix,
    this.timeout = const Duration(minutes: 3),
  });

  final DockerClient docker;
  final DiskWorkspaceConfig config;
  final String labelKey;
  final String labelValue;
  final String namePrefix;
  final Duration timeout;

  String name(String hash) => '${namePrefix}wsh-${hash.substring(0, 24)}';

  Map<String, Object?> payload(
    String hash,
    String op,
    String device,
    ({int dev, int ino}) identity,
    List<String> args,
  ) => {
    'Image': config.toolImage,
    'User': '0:0',
    'Entrypoint': ['python3', '-I', '-c', loopHelperScript],
    'Cmd': [op, device, '${identity.dev}', '${identity.ino}', ...args],
    'Labels': {labelKey: labelValue, workspaceHelperLabel: hash},
    'NetworkDisabled': true,
    'HostConfig': {
      'NetworkMode': 'none',
      'Memory': 128 * _mib,
      'MemorySwap': 128 * _mib,
      'NanoCpus': 1000000000,
      'PidsLimit': 32,
      'ReadonlyRootfs': true,
      'CapDrop': ['ALL'],
      'CapAdd': ['SYS_ADMIN'],
      'SecurityOpt': ['no-new-privileges:true'],
      'Privileged': false,
      'IpcMode': 'private',
      'Devices': [
        {
          'PathOnHost': device,
          'PathInContainer': device,
          'CgroupPermissions': 'rw',
        },
      ],
      'Mounts': [
        {
          'Type': 'bind',
          'Source': '${config.hostRoot}/$hash/workspace.img',
          'Target': '/disk.img',
          'ReadOnly': false,
          'BindOptions': {'Propagation': 'rprivate'},
        },
      ],
      'RestartPolicy': {'Name': 'no'},
      'LogConfig': {
        'Type': 'json-file',
        'Config': {'max-size': '1m', 'max-file': '1'},
      },
    },
  };

  @override
  Future<LoopResult> run(
    String hash,
    String op,
    String device,
    ({int dev, int ino}) identity, [
    List<String> args = const [],
  ]) async {
    final n = name(hash);
    final old = await docker.inspectContainer(n);
    if (old != null) {
      final labels = (old['Config'] as Map?)?['Labels'];
      if (labels is! Map ||
          labels[labelKey] != labelValue ||
          labels[workspaceHelperLabel] != hash) {
        throw SupervisorError(
          409,
          'name_conflict',
          'a container named $n exists and is not a workspace helper',
        );
      }
      await docker.removeContainer(old['Id'] as String);
    }
    final id = await docker.createContainer(
      n,
      payload(hash, op, device, identity, args),
    );
    if (id == null) {
      throw SupervisorError(503, 'disk_workspace_failed', 'helper $n exists');
    }
    try {
      await docker.startContainer(id);
      final deadline = DateTime.now().add(timeout);
      int? exitCode;
      while (exitCode == null) {
        final state = (await docker.inspectContainer(id))?['State'] as Map?;
        if (state == null) break;
        if (state['Running'] != true && state['Status'] != 'created') {
          exitCode = state['ExitCode'] as int?;
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw SupervisorError(
            503,
            'disk_workspace_failed',
            'the workspace helper ($op) did not finish',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final text = await docker.logs(id);
      Map<String, Object?>? out;
      for (final line in const LineSplitter().convert(text).reversed) {
        try {
          final j = jsonDecode(line);
          if (j is Map && j['state'] is String) {
            out = j.cast<String, Object?>();
            break;
          }
        } on FormatException {
          continue;
        }
      }
      if (out == null) {
        final tail = text.length > 600
            ? text.substring(text.length - 600)
            : text;
        throw SupervisorError(
          503,
          'disk_workspace_failed',
          'the workspace helper ($op) failed (exit $exitCode): $tail',
        );
      }
      return (exitCode: exitCode ?? -1, out: out);
    } finally {
      await docker.removeContainer(id).catchError((_) => false);
    }
  }
}

/// The durable record of one execution's disk workspace.
class DiskLease {
  DiskLease({
    required this.hash,
    required this.state,
    required this.sizeMb,
    required this.device,
    required this.volume,
    required this.bootId,
    this.dev,
    this.ino,
    this.attached = false,
    List<String>? sandboxIds,
  }) : sandboxIds = sandboxIds ?? [];

  final String hash;

  /// `preparing`, `ready`, `releasing` or `conflict` (kept for an operator:
  /// never reused, detached or removed automatically).
  String state;
  final int sizeMb;
  String device;
  final String volume;

  /// Boot of the last attach (loop bindings do not survive a reboot).
  String bootId;

  /// The image file's identity, read before the first helper run.
  int? dev;
  int? ino;

  /// The helper reported the image bound to [device] in boot [bootId].
  bool attached;

  /// Sandboxes that used this workspace, oldest first (at most 16).
  final List<String> sandboxIds;

  Map<String, Object?> toJson() => {
    'version': 1,
    'execution_sha256': hash,
    'state': state,
    'size_mb': sizeMb,
    'device': device,
    'volume': volume,
    'boot_id': bootId,
    'dev': dev,
    'ino': ino,
    'attached': attached,
    'sandbox_ids': sandboxIds,
  };

  static DiskLease? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    try {
      return DiskLease(
        hash: j['execution_sha256'] as String,
        state: j['state'] as String,
        sizeMb: j['size_mb'] as int,
        device: j['device'] as String,
        volume: j['volume'] as String,
        bootId: j['boot_id'] as String,
        dev: j['dev'] as int?,
        ino: j['ino'] as int?,
        attached: j['attached'] == true,
        sandboxIds: [...(j['sandbox_ids'] as List).cast<String>()],
      );
    } on TypeError {
      return null;
    }
  }
}

/// What a sandbox mounts: the volume, and the earlier sandboxes whose
/// workspace it keeps (empty for a new workspace).
typedef DiskGrant = ({String volume, List<String> keptFrom, bool fresh});

/// The disk workspaces of one supervisor. All operations are serialized.
class DiskWorkspaces {
  DiskWorkspaces(
    this.config, {
    required this.docker,
    required this.helper,
    required this.labelKey,
    required this.labelValue,
    required this.namePrefix,
    this.uid = 1000,
    this.gid = 1000,
    this.log,
    Future<int?> Function(String path)? freeBytes,
    String Function()? bootId,
    Future<({int dev, int ino})?> Function(String path)? fileIdentity,
  }) : freeBytes = freeBytes ?? dfAvailable,
       bootId = bootId ?? readBootId,
       fileIdentity = fileIdentity ?? statIdentity;

  final DiskWorkspaceConfig config;
  final DockerClient docker;
  final LoopHelper helper;
  final String labelKey;
  final String labelValue;
  final String namePrefix;
  final int uid;
  final int gid;
  final void Function(String)? log;
  final Future<int?> Function(String path) freeBytes;
  final String Function() bootId;
  final Future<({int dev, int ino})?> Function(String path) fileIdentity;

  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static Future<int?> dfAvailable(String path) async {
    try {
      final r = await Process.run('df', ['-B1', '--output=avail', path]);
      if (r.exitCode != 0) return null;
      return int.tryParse((r.stdout as String).trim().split('\n').last.trim());
    } on ProcessException {
      return null;
    }
  }

  static String readBootId() =>
      File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();

  static Future<({int dev, int ino})?> statIdentity(String path) async {
    try {
      final r = await Process.run('stat', ['-c', '%d %i', '--', path]);
      if (r.exitCode != 0) return null;
      final f = (r.stdout as String).trim().split(' ');
      final dev = int.tryParse(f.first);
      final ino = int.tryParse(f.last);
      return dev == null || ino == null || f.length != 2
          ? null
          : (dev: dev, ino: ino);
    } on ProcessException {
      return null;
    }
  }

  static Future<void> _chmod(String mode, String path) async {
    final r = await Process.run('chmod', [mode, '--', path]);
    if (r.exitCode != 0) {
      throw SupervisorError(
        503,
        'disk_workspace_failed',
        'chmod $mode $path failed: ${r.stderr}',
      );
    }
  }

  String volumeName(String hash) => '${namePrefix}ws-${hash.substring(0, 24)}';

  Directory _dir(String hash) => Directory('${config.root}/$hash');
  File _leaseFile(String hash) => File('${config.root}/$hash/lease.json');
  File _image(String hash) => File('${config.root}/$hash/workspace.img');

  /// The root must exist (created by the deployment, never here).
  void checkRoot() {
    if (!Directory(config.root).existsSync()) {
      throw SupervisorConfigError(
        'SANDBOX_DISK_ROOT ${config.root} does not exist',
      );
    }
  }

  DiskLease? read(String hash) {
    final f = _leaseFile(hash);
    if (!f.existsSync()) return null;
    try {
      final lease = DiskLease.fromJson(jsonDecode(f.readAsStringSync()));
      if (lease != null && lease.hash == hash) return lease;
    } on FormatException {
      // Below.
    }
    // Unreadable: kept as it is for an operator.
    return DiskLease(
      hash: hash,
      state: 'conflict',
      sizeMb: 0,
      device: '',
      volume: volumeName(hash),
      bootId: '',
    );
  }

  void _write(DiskLease lease) {
    final f = _leaseFile(lease.hash);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(lease.toJson()), flush: true);
    tmp.renameSync(f.path);
  }

  /// Every lease directory under the root (directories without a lease are
  /// counted with their image's size and never touched).
  List<DiskLease> _all() {
    final out = <DiskLease>[];
    final root = Directory(config.root);
    if (!root.existsSync()) return out;
    for (final e in root.listSync(followLinks: false)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is! Directory || !_hashName.hasMatch(name)) continue;
      final lease = read(name);
      if (lease != null) {
        out.add(lease);
        continue;
      }
      final image = _image(name);
      out.add(
        DiskLease(
          hash: name,
          state: 'conflict',
          sizeMb: image.existsSync()
              ? (image.lengthSync() + _mib - 1) ~/ _mib
              : 0,
          device: '',
          volume: volumeName(name),
          bootId: '',
        ),
      );
    }
    return out;
  }

  /// All leases (for listing and tests).
  List<DiskLease> leases() => _all();

  /// The lease that names [sandboxId] among its sandboxes.
  DiskLease? leaseOfSandbox(String sandboxId) =>
      _all().where((l) => l.sandboxIds.contains(sandboxId)).firstOrNull;

  Map<String, String> _volumeLabels(String hash) => {
    labelKey: labelValue,
    workspaceLabel: hash,
  };

  bool _ownVolume(Map<String, Object?> v, String hash) {
    final labels = v['Labels'];
    return labels is Map &&
        labels[labelKey] == labelValue &&
        labels[workspaceLabel] == hash;
  }

  static SupervisorError _error(String code, String message) =>
      SupervisorError(503, code, message);

  /// The execution's workspace volume: reused (after re-verifying the
  /// image's binding) or created. Throws [SupervisorError] 503
  /// `disk_budget_exceeded`, `disk_space_low`, `disk_pool_busy`,
  /// `disk_workspace_conflict` or `disk_workspace_failed`.
  Future<DiskGrant> ensure(String hash, int sizeMb) => _serial(() async {
    var lease = read(hash);
    if (lease != null &&
        (lease.state == 'preparing' || lease.state == 'releasing')) {
      // Left by an interrupted creation or release: finish the release.
      await _release(lease);
      lease = read(hash);
    }
    if (lease != null && lease.state == 'conflict') {
      throw _error(
        'disk_workspace_conflict',
        'the disk workspace of this execution needs an operator (lease in '
            'conflict)',
      );
    }
    if (lease == null) return _create(hash, sizeMb);
    return _reuse(lease);
  });

  Future<DiskGrant> _create(String hash, int sizeMb) async {
    final all = _all();
    final used = all.fold<int>(0, (a, l) => a + l.sizeMb);
    if (used + sizeMb > config.budgetMb) {
      throw _error(
        'disk_budget_exceeded',
        'disk workspaces use $used of ${config.budgetMb} MiB; $sizeMb more '
            'do not fit',
      );
    }
    final free = await freeBytes(config.root);
    if (free == null || free < (sizeMb + config.minFreeMb) * _mib) {
      throw _error(
        'disk_space_low',
        'the disk workspace root has ${free == null ? 'unknown' : '${free ~/ _mib} MiB'} '
            'free; $sizeMb MiB plus ${config.minFreeMb} MiB reserve are needed',
      );
    }
    final taken = {for (final l in all) l.device};
    final candidates = [
      for (final d in config.devices)
        if (!taken.contains(d)) d,
    ];
    if (candidates.isEmpty) {
      throw _error(
        'disk_pool_busy',
        'every loop device of the pool holds another execution\'s workspace',
      );
    }
    final dir = _dir(hash);
    if (dir.existsSync()) {
      throw _error(
        'disk_workspace_conflict',
        'the workspace directory of this execution exists without a lease',
      );
    }
    dir.createSync();
    // The directory protects the image on the host; the image itself must
    // be writable by the helper's root, which has no CAP_DAC_OVERRIDE and
    // sees only this file.
    await _chmod('700', dir.path);
    final lease = DiskLease(
      hash: hash,
      state: 'preparing',
      sizeMb: sizeMb,
      device: candidates.first,
      volume: volumeName(hash),
      bootId: bootId(),
    );
    _write(lease);
    try {
      _image(hash).createSync(exclusive: true);
      await _chmod('666', _image(hash).path);
      final id = await fileIdentity(_image(hash).path);
      if (id == null) {
        throw _error('disk_workspace_failed', 'cannot stat the image file');
      }
      lease
        ..dev = id.dev
        ..ino = id.ino;
      _write(lease);
      for (var i = 0; ; i++) {
        final r = await helper.run(hash, 'prepare', lease.device, id, [
          '${sizeMb * _mib}',
          '${config.minFreeMb * _mib}',
          '$uid',
          '$gid',
        ]);
        final state = r.out['state'];
        if (r.exitCode == 0 && state == 'attached') break;
        if (state == 'busy' && i + 1 < candidates.length) {
          lease.device = candidates[i + 1];
          _write(lease);
          continue;
        }
        throw switch (state) {
          'busy' => _error(
            'disk_pool_busy',
            'loop device ${lease.device} is in use by something else',
          ),
          'no_space' => _error(
            'disk_space_low',
            'not enough free space for the workspace image',
          ),
          _ => _error(
            'disk_workspace_failed',
            'preparing the workspace failed: ${jsonEncode(r.out)}',
          ),
        };
      }
      lease.attached = true;
      _write(lease);
      await _ensureVolume(lease);
      lease.state = 'ready';
      _write(lease);
      log?.call('disk workspace $hash ready on ${lease.device}');
      return (volume: lease.volume, keptFrom: const <String>[], fresh: true);
    } catch (_) {
      await _release(lease).catchError((Object e) {
        log?.call('disk workspace $hash: rollback failed: $e');
        return false;
      });
      rethrow;
    }
  }

  Future<DiskGrant> _reuse(DiskLease lease) async {
    final hash = lease.hash;
    final id = await fileIdentity(_image(hash).path);
    if (id == null || id.dev != lease.dev || id.ino != lease.ino) {
      lease.state = 'conflict';
      _write(lease);
      throw _error(
        'disk_workspace_conflict',
        'the workspace image of this execution is missing or was replaced',
      );
    }
    final boot = bootId();
    var r = await helper.run(hash, 'attach', lease.device, id);
    if (r.out['state'] == 'busy') {
      if (lease.bootId == boot && lease.attached) {
        // Bound to another file while this lease held it: stop.
        lease.state = 'conflict';
        _write(lease);
        throw _error(
          'disk_workspace_conflict',
          'loop device ${lease.device} no longer holds this workspace',
        );
      }
      // Bindings did not survive a reboot and the device was reused: take
      // another free one of the pool.
      final taken = {for (final l in _all()) l.device};
      for (final d in config.devices) {
        if (taken.contains(d)) continue;
        r = await helper.run(hash, 'attach', d, id);
        if (r.out['state'] != 'busy') {
          lease.device = d;
          break;
        }
      }
    }
    if (r.exitCode != 0 || r.out['state'] != 'attached') {
      throw r.out['state'] == 'busy'
          ? _error(
              'disk_pool_busy',
              'no loop device of the pool is free for this workspace',
            )
          : _error(
              'disk_workspace_failed',
              'attaching the workspace failed: ${jsonEncode(r.out)}',
            );
    }
    lease
      ..bootId = boot
      ..attached = true;
    _write(lease);
    await _ensureVolume(lease);
    return (
      volume: lease.volume,
      keptFrom: List<String>.unmodifiable(lease.sandboxIds),
      fresh: false,
    );
  }

  /// Creates the volume on the lease's device; an own volume on another
  /// device (stale after a reboot) is replaced when unused.
  Future<void> _ensureVolume(DiskLease lease) async {
    final v = await docker.inspectVolume(lease.volume);
    if (v != null) {
      if (!_ownVolume(v, lease.hash)) {
        throw SupervisorError(
          409,
          'name_conflict',
          'a volume named ${lease.volume} exists and is not this workspace\'s',
        );
      }
      final opts = (v['Options'] as Map?) ?? const {};
      if (opts['device'] == lease.device && opts['type'] == 'ext4') return;
      await _removeVolume(lease);
    }
    await docker.createVolume({
      'Name': lease.volume,
      'Driver': 'local',
      'DriverOpts': {
        'type': 'ext4',
        'device': lease.device,
        'o': 'rw,nosuid,nodev',
      },
      'Labels': _volumeLabels(lease.hash),
    });
  }

  Future<void> _removeVolume(DiskLease lease) async {
    final users = await docker.listContainers(const [], volume: lease.volume);
    if (users.isNotEmpty) {
      throw _error(
        'disk_volume_in_use',
        'the workspace volume ${lease.volume} is still used by '
            '${users.length} container(s)',
      );
    }
    await docker.removeVolume(lease.volume);
  }

  /// Records [sandboxId] as a user of the execution's workspace.
  Future<void> addSandbox(String hash, String sandboxId) => _serial(() async {
    final lease = read(hash);
    if (lease == null || lease.sandboxIds.contains(sandboxId)) return;
    lease.sandboxIds.add(sandboxId);
    if (lease.sandboxIds.length > 16) lease.sandboxIds.removeAt(0);
    _write(lease);
  });

  /// The sandboxes before [sandboxId] whose workspace it keeps.
  List<String> keptFrom(String hash, String sandboxId) => [
    for (final id in read(hash)?.sandboxIds ?? const <String>[])
      if (id != sandboxId) id,
  ];

  /// Releases the execution's workspace (no sandbox may use it any more).
  /// True when nothing is left; false when there was nothing or the lease
  /// is kept in `conflict`.
  Future<bool> release(String hash) => _serial(() async {
    final lease = read(hash);
    return lease == null ? false : _release(lease);
  });

  /// Volume, then loop binding (only when it is this image's), then the
  /// image, the lease and the directory.
  Future<bool> _release(DiskLease lease) async {
    final hash = lease.hash;
    if (lease.state == 'conflict') {
      log?.call('disk workspace $hash is in conflict; left for an operator');
      return false;
    }
    lease.state = 'releasing';
    _write(lease);
    final v = await docker.inspectVolume(lease.volume);
    if (v != null && _ownVolume(v, hash)) await _removeVolume(lease);
    final image = _image(hash);
    if (image.existsSync() && lease.dev != null && lease.ino != null) {
      final id = (dev: lease.dev!, ino: lease.ino!);
      final r = await helper.run(hash, 'detach', lease.device, id);
      final state = r.out['state'];
      if (state == 'other' || state == 'image_identity') {
        if (state == 'image_identity' ||
            (lease.attached && lease.bootId == bootId())) {
          lease.state = 'conflict';
          _write(lease);
          log?.call(
            'disk workspace $hash: ${lease.device} or the image is not this '
            'workspace\'s ($state); nothing detached, lease kept in conflict',
          );
          return false;
        }
        // Never bound in this boot: nothing of this image is attached.
      } else if (r.exitCode != 0 || (state != 'detached' && state != 'free')) {
        throw _error(
          'disk_workspace_failed',
          'detaching the workspace failed: ${jsonEncode(r.out)}',
        );
      }
    }
    if (image.existsSync()) image.deleteSync();
    final tmp = File('${_leaseFile(hash).path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
    _leaseFile(hash).deleteSync();
    try {
      _dir(hash).deleteSync();
    } on FileSystemException catch (e) {
      log?.call('disk workspace $hash: directory kept: ${e.message}');
    }
    log?.call('disk workspace $hash released');
    return true;
  }

  /// At start: removes leftover helpers, finishes interrupted creations
  /// and releases, releases the workspaces of the sandboxes the sweep
  /// removed ([removedHashes]) and removes own volumes without a lease.
  /// Ready workspaces without a sandbox stay (a paused execution).
  Future<void> sweep(Set<String> removedHashes) => _serial(() async {
    for (final c in await docker.listContainers([
      '$labelKey=$labelValue',
      workspaceHelperLabel,
    ])) {
      await docker.removeContainer(c['Id'] as String);
      log?.call('sweep removed workspace helper ${c['Id']}');
    }
    final leased = <String>{};
    for (final lease in _all()) {
      leased.add(lease.hash);
      final interrupted =
          lease.state == 'preparing' || lease.state == 'releasing';
      if (!interrupted &&
          !(lease.state == 'ready' && removedHashes.contains(lease.hash))) {
        continue;
      }
      try {
        await _release(lease);
      } catch (e) {
        log?.call('sweep: disk workspace ${lease.hash} not released: $e');
      }
    }
    for (final v in await docker.listVolumes([
      '$labelKey=$labelValue',
      workspaceLabel,
    ])) {
      final hash = (v['Labels'] as Map?)?[workspaceLabel];
      if (hash is! String || leased.contains(hash)) continue;
      final name = v['Name'] as String;
      final users = await docker.listContainers(const [], volume: name);
      if (users.isEmpty) {
        await docker.removeVolume(name);
        log?.call('sweep removed workspace volume $name without a lease');
      }
    }
  });
}
