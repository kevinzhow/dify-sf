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
import 'dart:typed_data';

import 'docker.dart';
import 'supervisor.dart' show SupervisorConfigError, SupervisorError;

/// Label of disk workspace volumes: the execution key's SHA-256.
const workspaceLabel = 'dify-sf.sandbox.workspace';

/// Label of helper containers: the execution key's SHA-256.
const workspaceHelperLabel = 'dify-sf.sandbox.workspace-helper';

const _mib = 1024 * 1024;

/// The placeholder image of a pool device, relative to the disk root.
String holdPath(String device) => 'hold/${device.split('/').last}.img';

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
  /// already bound to it is fine), `detach` (only when bound to this image),
  /// `check`, `create` (the pool device's node, gone after a reboot),
  /// `hold` (bind a free device to its placeholder) or `unhold` (clear the
  /// placeholder binding only). [identity] is the image's device and inode
  /// as the supervisor sees it (null for `create`, `hold` and `unhold`); the
  /// helper refuses another file. [hold] is the identity of the device's
  /// placeholder: with it, a device bound to the placeholder counts as free
  /// (`prepare` and `attach` swap it for the image) and `detach` binds the
  /// placeholder again.
  Future<LoopResult> run(
    String hash,
    String op,
    String device,
    ({int dev, int ino})? identity, {
    List<String> args,
    ({int dev, int ino})? hold,
  });
}

/// The helper's program (python3 -I -c). Exit codes: 0 done, 3 the device is
/// bound to another file, 4 not enough free space, 5 identity refused, 6
/// not a regular image file or not a loop device, 7 a cleared binding did
/// not go away within 5 s.
///
/// `LOOP_CLR_FD` only marks a binding: it goes with the device's last close
/// (another opener, e.g. udev probing, delays it; this helper must not keep
/// the device open meanwhile). A swap therefore clears, closes and re-opens
/// until the old binding is gone, then binds; for that moment (about 2 ms
/// in our measurement) the device is free. A new binding by someone else
/// makes the swap answer `busy` with `lost_hold` (and `formatted` when
/// `prepare` already wrote the image: the next device needs `attach`).
const loopHelperScript = r'''
import errno, fcntl, json, os, stat, struct, subprocess, sys, time
SET_FD, CLR_FD, GET_STATUS64, CTL_ADD = 0x4C00, 0x4C01, 0x4C05, 0x4C80
def done(code, state, **kw):
    kw['state'] = state
    print(json.dumps(kw), flush=True)
    sys.exit(code)
op, device, want_dev, want_ino = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
if op == 'create':
    c = os.open('/dev/loop-control', os.O_RDWR)
    try:
        fcntl.ioctl(c, CTL_ADD, int(device[len('/dev/loop'):]))
    except OSError as e:
        if e.errno == errno.EEXIST:
            done(0, 'exists')
        raise
    done(0, 'created')
def regular(path, flags, want, refused):
    f = os.open(path, flags)
    st = os.fstat(f)
    if not stat.S_ISREG(st.st_mode):
        done(6, 'not_a_file')
    if (st.st_dev, st.st_ino) != want:
        done(5, refused, dev=st.st_dev, ino=st.st_ino)
    return f, st
hold = held = None
if os.environ.get('HOLD'):
    held = tuple(map(int, os.environ['HOLD'].split(':')))
    hold, _ = regular('/hold.img', os.O_RDONLY, held, 'hold_identity')
img = mine = st = None
if op in ('prepare', 'attach', 'detach') or (op == 'check' and want_ino):
    img, st = regular('/disk.img', os.O_RDWR, (want_dev, want_ino), 'image_identity')
    mine = (want_dev, want_ino)
elif op in ('hold', 'unhold') and hold is None:
    done(2, 'no_hold')
d = os.open(device, os.O_RDWR)
ds = os.fstat(d)
if not stat.S_ISBLK(ds.st_mode) or os.major(ds.st_rdev) != 7:
    done(6, 'not_a_loop_device')
def status():
    buf = bytearray(232)
    try:
        fcntl.ioctl(d, GET_STATUS64, buf)
    except OSError as e:
        if e.errno == errno.ENXIO:
            return None
        raise
    return buf
def bound():
    b = status()
    return None if b is None else struct.unpack_from('=QQ', b)
def holder():
    b = status()
    return '' if b is None else bytes(b[56:120]).split(b'\0')[0].decode('utf-8', 'replace')
def reopen():
    # False while the device runs down (its last opener has not closed).
    global d
    try:
        d = os.open(device, os.O_RDWR)
        return True
    except OSError as e:
        if e.errno == errno.ENXIO:
            return False
        raise
def wait(pause=True):
    # Lets a binding that is going away go: this helper must not hold the
    # device open meanwhile (its own open would be the last one).
    global d
    os.close(d)
    for _ in range(250):
        if pause:
            time.sleep(0.02)
        pause = True
        if reopen():
            return
    done(7, 'clear_timeout')
def clear():
    # True once the device is free; False when another binder holds it.
    old = bound()
    fcntl.ioctl(d, CLR_FD, 0)
    for i in range(250):
        wait(pause=i > 0)  # usually our close was the last: no pause
        now = bound()
        if now is None:
            return True
        if now != old:
            return False
    done(7, 'clear_timeout')
def bind(f, want):
    # True when f is bound and verified; False when another binder holds it.
    for _ in range(250):
        try:
            fcntl.ioctl(d, SET_FD, f)
            break
        except OSError as e:
            if e.errno != errno.EBUSY:
                raise
        if bound() is not None:
            return False
        wait()  # still running down
    else:
        done(7, 'clear_timeout')
    if bound() != want:
        clear()  # bound by this call: releasing it is safe
        if f is not hold:
            rehold()
        done(5, 'identity_mismatch')
    return True
def rehold():
    return hold is not None and bind(hold, held)
def take():
    cur = bound()
    if cur is not None and cur != held:
        done(3, 'busy', holder=holder(), formatted=op == 'prepare')
    if (cur is not None and not clear()) or not bind(img, mine):
        done(3, 'busy', holder=holder(), lost_hold=cur is not None, formatted=op == 'prepare')
    done(0, 'attached', dev=mine[0], ino=mine[1])
cur = bound()
free = cur is None or (held is not None and cur == held)
if op == 'check':
    done(0, 'free' if cur is None else 'held' if cur == held else 'own' if cur == mine else 'other', holder=holder())
if op == 'hold':
    if cur == held:
        done(0, 'held')
    if cur is None and bind(hold, held):
        done(0, 'held')
    done(3, 'other', holder=holder())
if op == 'unhold':
    if cur == held and not clear():
        done(0, 'other', holder=holder())
    done(0, 'free' if cur is None or cur == held else 'other')
if op == 'detach':
    if free:
        done(0, 'free', held=cur is not None or rehold())
    if cur != mine:
        done(5, 'other')
    done(0, 'detached', held=clear() and rehold())
if op == 'attach':
    if cur == mine:
        done(0, 'attached', dev=mine[0], ino=mine[1])
    if not free:
        done(3, 'busy', holder=holder())
    if st.st_size == 0:
        done(6, 'not_formatted')
    take()
if op == 'prepare':
    size, min_free, uid, gid = map(int, sys.argv[5:9])
    if not free:
        done(3, 'busy', holder=holder())
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
    take()
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

  String name(String hash) =>
      '${namePrefix}wsh-${hash.length > 24 ? hash.substring(0, 24) : hash}';

  Map<String, Object?> payload(
    String hash,
    String op,
    String device,
    ({int dev, int ino})? identity,
    List<String> args, {
    ({int dev, int ino})? hold,
  }) => {
    'Image': config.toolImage,
    'User': '0:0',
    'Entrypoint': ['python3', '-I', '-c', loopHelperScript],
    'Cmd': [
      op,
      device,
      '${identity?.dev ?? 0}',
      '${identity?.ino ?? 0}',
      ...args,
    ],
    'Env': [if (hold != null) 'HOLD=${hold.dev}:${hold.ino}'],
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
      // Only `create` sees /dev/loop-control, and then no pool device.
      'Devices': [
        {
          'PathOnHost': op == 'create' ? '/dev/loop-control' : device,
          'PathInContainer': op == 'create' ? '/dev/loop-control' : device,
          'CgroupPermissions': 'rw',
        },
      ],
      'Mounts': [
        if (identity != null && op != 'create')
          {
            'Type': 'bind',
            'Source': '${config.hostRoot}/$hash/workspace.img',
            'Target': '/disk.img',
            'ReadOnly': false,
            'BindOptions': {'Propagation': 'rprivate'},
          },
        if (hold != null && op != 'create')
          {
            'Type': 'bind',
            'Source': '${config.hostRoot}/${holdPath(device)}',
            'Target': '/hold.img',
            'ReadOnly': true,
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
    ({int dev, int ino})? identity, {
    List<String> args = const [],
    ({int dev, int ino})? hold,
  }) async {
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
      payload(hash, op, device, identity, args, hold: hold),
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
    this.retained = false,
    this.profile,
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

  /// Retained until the owning workflow terminates; parked leases hold no slot.
  final bool retained;
  final String? profile;

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
    'retained': retained,
    'profile': profile,
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
        retained: j['retained'] == true,
        profile: j['profile'] as String?,
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

  /// Helper name key of a pool device's own operations (no workspace).
  static String _poolKey(String device) => 'pool-${device.split('/').last}';

  /// The identity of [device]'s placeholder image, created on first use: a
  /// pool device that holds no workspace stays bound to it, so `losetup
  /// -f`, snapd or udisks never find it free. 4 KiB of zeros, 0644 (the
  /// helper's root has no `CAP_DAC_OVERRIDE` and binds it read-only).
  Future<({int dev, int ino})> _hold(String device) async {
    final dir = Directory('${config.root}/hold');
    if (!dir.existsSync()) {
      dir.createSync();
      await _chmod('700', dir.path);
    }
    final f = File('${config.root}/${holdPath(device)}');
    if (!f.existsSync()) {
      final tmp = File('${f.path}.tmp');
      tmp.writeAsBytesSync(Uint8List(4096), flush: true);
      await _chmod('644', tmp.path);
      tmp.renameSync(f.path);
    }
    final id = await fileIdentity(f.path);
    if (id == null) {
      throw _error(
        'disk_workspace_failed',
        'cannot stat the placeholder image of $device',
      );
    }
    return id;
  }

  /// Pool devices created (or found) by this process: a held device cannot
  /// be removed, so once is enough until the next start.
  final Set<String> _created = {};

  /// Makes sure [device] exists (its node is gone after a reboot) and
  /// returns its placeholder's identity. A failed creation is logged; the
  /// helper run that needs the device then fails on its own.
  Future<({int dev, int ino})> _device(String device) async {
    if (!_created.contains(device)) {
      try {
        final c = await helper.run(_poolKey(device), 'create', device, null);
        if (c.exitCode == 0) {
          _created.add(device);
        } else {
          log?.call(
            'pool device $device could not be created: ${jsonEncode(c.out)}',
          );
        }
      } catch (e) {
        log?.call('pool device $device could not be created: $e');
      }
    }
    return _hold(device);
  }

  /// ` (<backing file>)` of another binder, when the kernel has its name.
  static String _holder(LoopResult r) {
    final h = r.out['holder'];
    return h is String && h.isNotEmpty ? ' ($h)' : '';
  }

  /// Logs a detach that could not bind the placeholder again.
  void _logHold(String device, LoopResult r) {
    if (r.out['held'] == false) {
      log?.call('pool device $device is free and not held (taken meanwhile?)');
    }
  }

  /// Binds every pool device that holds no workspace to its placeholder,
  /// creating the device first (its node is gone after a reboot). A device
  /// bound to something else is logged with its backing file and left alone.
  Future<void> holdPool() => _serial(_holdPool);

  Future<void> _holdPool() async {
    final taken = {
      for (final l in _all())
        if (l.state != 'parked') l.device,
    };
    for (final d in config.devices) {
      if (taken.contains(d)) continue;
      try {
        final hold = await _device(d);
        if (!_created.contains(d)) continue;
        final r = await helper.run(_poolKey(d), 'hold', d, null, hold: hold);
        if (r.exitCode == 0 && r.out['state'] == 'held') continue;
        log?.call(
          'pool device $d is not held: bound to '
          '${r.out['holder'] ?? 'another file'} (${r.out['state']})',
        );
      } catch (e) {
        log?.call('pool device $d is not held: $e');
      }
    }
  }

  /// Each pool device's binding: `held` (idle, bound to its placeholder),
  /// `free`, `other` (with `holder`, the backing file another binder gave)
  /// or `error`; plus the execution SHA-256 of a lease that holds it.
  Future<Map<String, Map<String, Object?>>> poolStatus() => _serial(() async {
    final leases = {
      for (final l in _all())
        if (l.state != 'parked') l.device: l.hash,
    };
    return {
      for (final d in config.devices)
        d: await () async {
          try {
            final r = await helper.run(
              _poolKey(d),
              'check',
              d,
              null,
              hold: await _device(d),
            );
            return {...r.out, 'lease': ?leases[d]};
          } catch (e) {
            return {'state': 'error', 'message': '$e', 'lease': ?leases[d]};
          }
        }(),
    };
  });

  /// Clears the placeholder bindings of the pool devices that hold no
  /// workspace (an operator removing devices from the pool; tests).
  Future<void> unholdPool() => _serial(() async {
    final taken = {
      for (final l in _all())
        if (l.state != 'parked') l.device,
    };
    for (final d in config.devices) {
      if (taken.contains(d)) continue;
      final r = await helper.run(
        _poolKey(d),
        'unhold',
        d,
        null,
        hold: await _device(d),
      );
      if (r.out['state'] != 'free') {
        log?.call('pool device $d left alone: ${jsonEncode(r.out)}');
      }
    }
  });

  /// Images are writable by the unprivileged sandbox user through a volume,
  /// so their host directory must be private to this supervisor. Deployment
  /// creates it; a misconfigured or linked directory is never repaired here.
  void checkRoot() {
    if (FileSystemEntity.typeSync(config.root, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileStat.statSync(config.root).mode & 0xfff != 0x1c0) {
      throw SupervisorConfigError(
        'SANDBOX_DISK_ROOT must be a real directory with mode 0700',
      );
    }
    try {
      final owner = Process.runSync('stat', ['-c', '%u', '--', config.root]);
      final effective = Process.runSync('id', ['-u']);
      final uid = int.tryParse((effective.stdout as String).trim());
      if (owner.exitCode == 0 &&
          effective.exitCode == 0 &&
          uid != null &&
          int.tryParse((owner.stdout as String).trim()) == uid) {
        return;
      }
    } on ProcessException {
      // Unable to verify the owner: fail closed before Docker calls.
    }
    throw SupervisorConfigError(
      'SANDBOX_DISK_ROOT must be owned by the supervisor user',
    );
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
  Future<DiskGrant> ensure(
    String hash,
    int sizeMb, {
    bool retained = false,
    String? profile,
  }) => _serial(() async {
    var lease = read(hash);
    if (lease != null &&
        (lease.retained != retained || lease.profile != profile)) {
      throw _error(
        'disk_workspace_conflict',
        'workspace profile or retention does not match',
      );
    }
    if (lease?.state == 'parking') {
      await _park(lease!);
      lease = read(hash);
    }
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
    if (lease == null) {
      return _create(hash, sizeMb, retained: retained, profile: profile);
    }
    return _reuse(lease);
  });

  Future<DiskGrant> _create(
    String hash,
    int sizeMb, {
    required bool retained,
    String? profile,
  }) async {
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
    final taken = {
      for (final l in all)
        if (l.state != 'parked') l.device,
    };
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
      retained: retained,
      profile: profile,
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
      // Once the helper wrote the image (and then lost the device in its
      // swap), the next device attaches it instead of preparing again.
      var formatted = false;
      for (var i = 0; ; i++) {
        final r = await helper.run(
          hash,
          formatted ? 'attach' : 'prepare',
          lease.device,
          id,
          args: [
            if (!formatted) ...[
              '${sizeMb * _mib}',
              '${config.minFreeMb * _mib}',
              '$uid',
              '$gid',
            ],
          ],
          hold: await _device(lease.device),
        );
        final state = r.out['state'];
        if (r.exitCode == 0 && state == 'attached') break;
        if (r.out['formatted'] == true) formatted = true;
        if (r.out['lost_hold'] == true) {
          log?.call(
            'pool device ${lease.device} was taken while swapping its '
            'placeholder${_holder(r)}',
          );
        }
        if (state == 'busy' && i + 1 < candidates.length) {
          lease.device = candidates[i + 1];
          _write(lease);
          continue;
        }
        throw switch (state) {
          'busy' => _error(
            'disk_pool_busy',
            'loop device ${lease.device} is in use by something else'
                '${_holder(r)}',
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
    if (lease.state == 'parked') {
      final taken = {
        for (final l in _all())
          if (l.hash != hash && l.state != 'parked') l.device,
      };
      final available = config.devices
          .where((d) => !taken.contains(d))
          .toList();
      if (available.isEmpty) {
        throw _error(
          'disk_pool_busy',
          'no disk slot is free for this workspace',
        );
      }
      lease.device = available.first;
      lease.state = 'attaching';
      lease.attached = false;
      _write(lease);
    }
    var r = await helper.run(
      hash,
      'attach',
      lease.device,
      id,
      hold: await _device(lease.device),
    );
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
      final taken = {
        for (final l in _all())
          if (l.state != 'parked') l.device,
      };
      for (final d in config.devices) {
        if (taken.contains(d)) continue;
        r = await helper.run(hash, 'attach', d, id, hold: await _device(d));
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
      ..attached = true
      ..state = 'ready';
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

  /// Unmount and detach a retained workspace while keeping its bounded image.
  Future<bool> park(String hash) => _serial(() async {
    final lease = read(hash);
    if (lease == null) return false;
    return _park(lease);
  });

  Future<bool> _park(DiskLease lease) async {
    if (!lease.retained) {
      throw _error('disk_workspace_conflict', 'workspace is not retained');
    }
    if (lease.state == 'conflict') {
      throw _error('disk_workspace_conflict', 'workspace needs an operator');
    }
    if (lease.state == 'parked') return true;
    final image = _image(lease.hash);
    final id = await fileIdentity(image.path);
    if (id == null || id.dev != lease.dev || id.ino != lease.ino) {
      lease.state = 'conflict';
      _write(lease);
      throw _error(
        'disk_workspace_conflict',
        'workspace image identity changed',
      );
    }
    lease.state = 'parking';
    _write(lease);
    final volume = await docker.inspectVolume(lease.volume);
    if (volume != null) {
      if (!_ownVolume(volume, lease.hash)) {
        throw _error(
          'disk_workspace_conflict',
          'workspace volume owner changed',
        );
      }
      await _removeVolume(lease);
    }
    final r = await helper.run(
      lease.hash,
      'detach',
      lease.device,
      id,
      hold: await _device(lease.device),
    );
    _logHold(lease.device, r);
    final state = r.out['state'];
    if (r.exitCode != 0 || (state != 'detached' && state != 'free')) {
      if (state == 'other' || state == 'image_identity') {
        lease.state = 'conflict';
        _write(lease);
      }
      throw _error(
        'disk_workspace_failed',
        'could not detach retained workspace',
      );
    }
    lease
      ..attached = false
      ..state = 'parked';
    _write(lease);
    return true;
  }

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
    final image = _image(hash);
    final hasIdentity = lease.dev != null && lease.ino != null;
    if ((lease.dev == null) != (lease.ino == null) ||
        (lease.attached && !hasIdentity) ||
        (hasIdentity && !image.existsSync())) {
      // An unlink does not detach an open loop device. Keep its lease and
      // volume so an operator can recover the recorded identity, including
      // when attachment finished just before a crash persisted the flag.
      lease.state = 'conflict';
      _write(lease);
      log?.call(
        'disk workspace $hash: image or identity is missing; '
        'volume and lease kept in conflict',
      );
      return false;
    }
    final wasParked =
        lease.state == 'parked' ||
        (lease.state == 'releasing' && !lease.attached);
    lease.state = 'releasing';
    _write(lease);
    final v = await docker.inspectVolume(lease.volume);
    if (v != null && _ownVolume(v, hash)) await _removeVolume(lease);
    if (!wasParked &&
        image.existsSync() &&
        lease.dev != null &&
        lease.ino != null) {
      final id = (dev: lease.dev!, ino: lease.ino!);
      final r = await helper.run(
        hash,
        'detach',
        lease.device,
        id,
        hold: await _device(lease.device),
      );
      _logHold(lease.device, r);
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
  /// removed ([removedHashes]), removes own volumes without a lease and
  /// holds the idle pool devices ([holdPool]). The pool devices are created
  /// first, before any lease needs one. Ready workspaces without a
  /// sandbox stay (a paused execution).
  Future<void> sweep(Set<String> removedHashes) => _serial(() async {
    for (final c in await docker.listContainers([
      '$labelKey=$labelValue',
      workspaceHelperLabel,
    ])) {
      await docker.removeContainer(c['Id'] as String);
      log?.call('sweep removed workspace helper ${c['Id']}');
    }
    // Before any lease is released, parked or reused: after a reboot the
    // pool's device nodes may not exist yet.
    for (final d in config.devices) {
      await _device(d).catchError((Object e) {
        log?.call('pool device $d: $e');
        return (dev: 0, ino: 0);
      });
    }
    final leased = <String>{};
    for (final lease in _all()) {
      leased.add(lease.hash);
      if (lease.retained &&
          (lease.state == 'parking' ||
              (lease.state == 'ready' && removedHashes.contains(lease.hash)))) {
        try {
          await _park(lease);
        } catch (e) {
          log?.call('sweep: retained workspace could not park: $e');
        }
        continue;
      }
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
    await _holdPool();
  });
}
