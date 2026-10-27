/// The sandbox supervisor: the only component with access to the container
/// runtime. It accepts exactly two commands, "create the sandbox for
/// execution X" and "remove sandbox Y"; image, network layout, limits, peers
/// and labels come from its own configuration, never from a request.
///
/// Every sandbox gets its own internal bridge network (`Internal`,
/// `com.docker.network.bridge.inhibit_ipv4`, a /28 from
/// `SANDBOX_SUBNET_POOL`), attached to exactly three kinds of endpoint: the
/// sandbox, the configured agent service container(s) and the configured
/// proxy container. Sandboxes therefore share no network with each other, and
/// the host has no address on any of them. The network is removed with the
/// sandbox.
///
/// Image, read-only binds, render nodes, egress and limits come from the
/// executor profile the request names, resolved from the supervisor's own
/// copy of the profile file (`AGENT_EXECUTOR_PROFILES`).
///
/// API (bearer `SANDBOX_SUPERVISOR_KEY`):
///
/// - `POST /v1/sandboxes {"execution_key", "profile"?}` → `{"sandbox_id",
///   "url", "token", "gateway", "created", "profile"}`; idempotent per
///   execution key (a stopped container is replaced, with a new
///   `sandbox_id`). `profile` defaults to `default`; an unknown one is 400,
///   an existing sandbox of the key with another profile 409. `gateway` is
///   the sandbox network's reserved (never assigned) gateway address, for
///   the host-reachability probe.
/// - `DELETE /v1/sandboxes/{sandbox_id}` → `{"sandbox_id", "deleted"}`
///   (force remove with volumes, then its network; containers without the
///   labels are refused).
/// - `GET /v1/sandboxes` → `{"sandboxes": [...]}` (labelled containers only,
///   each with its `profile`).
/// - `GET /v1/profiles` → `{"profiles": {"<name>": {"status", "digest"}}}`,
///   `status` `ok`, `image_missing` or `device_missing`.
/// - `GET /v1/health` → `{"status", "docker"}`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../executor_profiles.dart';
import 'disk_workspace.dart';
import 'docker.dart';

export 'disk_workspace.dart';

/// The shellctl port of the sandbox image.
const shellctlPort = 5004;

/// Label holding the SHA-256 of the execution key (containers and networks).
const executionLabel = 'dify-sf.sandbox.execution';

/// Label holding the sandbox's executor profile (containers). A container
/// without it predates profiles and counts as `default`.
const profileLabel = 'dify-sf.sandbox.profile';

/// shellctl's Landlock defaults (dify-agent-runtime 1.17.1,
/// `internal/landlock/config.go`): read-only (with execute) directories and
/// read-write device files of every job. Setting the variables replaces
/// them, so a sandbox's list starts from these.
const shellctlLandlockRoDefaults = [
  '/usr', '/bin', '/sbin', '/lib', '/lib64', '/etc', '/proc', //
  '/opt/dify-agent-tools', '/opt/homebrew', '/snap',
];
const shellctlLandlockRwDevDefaults = [
  '/dev/null', '/dev/zero', '/dev/urandom', '/dev/random', '/dev/tty', //
];

/// A render node on this host: its group and its device's sysfs directory
/// (what Mesa reads to identify the GPU).
typedef DeviceInfo = ({int group, String sysfs});

/// Reads a host character device with `stat` and `/sys/dev/char`; null
/// when it does not exist or is not a character device.
DeviceInfo? statDevice(String path) {
  try {
    final r = Process.runSync('stat', ['-L', '-c', '%F|%g|%t|%T', '--', path]);
    if (r.exitCode != 0) return null;
    final f = (r.stdout as String).trim().split('|');
    if (f.length != 4 || f[0] != 'character special file') return null;
    final group = int.tryParse(f[1]);
    final major = int.tryParse(f[2], radix: 16);
    final minor = int.tryParse(f[3], radix: 16);
    if (group == null || major == null || minor == null) return null;
    final sysfs = Link('/sys/dev/char/$major:$minor/device')
        .resolveSymbolicLinksSync();
    return (group: group, sysfs: sysfs);
  } on ProcessException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// Prefix length of every sandbox network.
const sandboxSubnetPrefix = 28;

/// Host numbers inside a sandbox subnet: the reserved gateway (never
/// assigned: the bridge has no IPv4 address), the proxy and the sandbox.
/// Agent service containers get dynamic addresses from the upper half
/// (`IPRange`), so they never take a fixed one.
const gatewayHost = 1, proxyHost = 2, sandboxHost = 3;

/// The network option that leaves the bridge (the host side) without an
/// IPv4 address.
const inhibitIpv4Option = 'com.docker.network.bridge.inhibit_ipv4';

class SupervisorConfigError implements Exception {
  SupervisorConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An IPv4 network `address/prefix`.
class Ipv4Net {
  Ipv4Net(int address, this.prefix)
    : base = address & _mask(prefix),
      assert(prefix >= 0 && prefix <= 32);

  final int base;
  final int prefix;

  static int _mask(int prefix) =>
      prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;

  int get size => 1 << (32 - prefix);
  int get last => base + size - 1;

  /// Parses `a.b.c.d/n`; null for anything else (e.g. IPv6).
  static Ipv4Net? tryParse(String text) {
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$')
        .firstMatch(text.trim());
    if (m == null) return null;
    var address = 0;
    for (var i = 1; i <= 4; i++) {
      final octet = int.parse(m.group(i)!);
      if (octet > 255) return null;
      address = (address << 8) | octet;
    }
    final prefix = int.parse(m.group(5)!);
    if (prefix > 32) return null;
    return Ipv4Net(address, prefix);
  }

  static String format(int address) =>
      [for (var shift = 24; shift >= 0; shift -= 8) (address >> shift) & 0xff]
          .join('.');

  /// The address of host number [n] in this network.
  String host(int n) => format(base + n);

  bool overlaps(Ipv4Net other) => base <= other.last && other.base <= last;
  bool containsNet(Ipv4Net other) => base <= other.base && other.last <= last;

  /// The [index]th sub-network of length [subPrefix].
  Ipv4Net subnet(int index, int subPrefix) =>
      Ipv4Net(base + index * (1 << (32 - subPrefix)), subPrefix);

  @override
  bool operator ==(Object other) =>
      other is Ipv4Net && other.base == base && other.prefix == prefix;
  @override
  int get hashCode => Object.hash(base, prefix);
  @override
  String toString() => '${format(base)}/$prefix';
}

/// The ranges the sandbox proxy refuses as destinations
/// (docker/agent_sandbox_proxy/squid.conf); a sandbox pool must lie inside
/// one of them so that the proxy cannot be used to reach another sandbox.
final proxyRefusedRanges = [
  for (final r in ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'])
    Ipv4Net.tryParse(r)!,
  Ipv4Net.tryParse('100.64.0.0/10')!,
];

/// Everything a sandbox is made of. Only the environment of the supervisor
/// process sets these.
class SupervisorConfig {
  SupervisorConfig({
    required this.key,
    required this.agentPeers,
    this.proxyPeer,
    this.proxyPort = 3128,
    this.codexGateway = false,
    this.composeProject,
    String subnetPool = '10.213.0.0/16',
    this.image = 'langgenius/dify-agent-local-sandbox:1.17.1',
    this.dockerSocket = '/var/run/docker.sock',
    this.port = 5060,
    this.labelKey = 'dify-sf.agent-sandbox',
    this.labelValue = '1',
    this.namePrefix = 'dify-sf-sandbox-',
    this.memoryMb = 1024,
    this.cpus = 1.0,
    this.pidsLimit = 256,
    this.homeMb = 256,
    this.workspaceMb = 512,
    this.uid = 1000,
    this.gid = 1000,
    this.noProxy = 'localhost,127.0.0.1',
    this.addressByIp = false,
    this.statePath,
    this.startTimeout = const Duration(seconds: 60),
    ExecutorProfiles? profiles,
    this.device = statDevice,
    this.disk,
  }) : subnetPool = _pool(subnetPool),
       profiles = profiles ?? ExecutorProfiles.implicit() {
    if (agentPeers.isEmpty) {
      throw SupervisorConfigError('at least one agent peer is required');
    }
    if (codexGateway && proxyPeer == null) {
      throw SupervisorConfigError('the Codex gateway requires a proxy peer');
    }
    for (final p in this.profiles.profiles.values) {
      final l = limitsOf(p);
      final diskBacked = p.workspaceBacking == WorkspaceBacking.disk;
      // tmpfs pages are charged to the container's memory limit; a disk
      // workspace is not.
      final tmpfsMb = l.homeMb + (diskBacked ? 0 : l.workspaceMb);
      if (tmpfsMb >= l.memoryMb) {
        throw SupervisorConfigError(
          diskBacked
              ? 'profile ${p.name}: home_mb (${l.homeMb}) must be below '
                    'memory_mb (${l.memoryMb})'
              : 'profile ${p.name}: home_mb + workspace_mb (${l.homeMb} + '
                    '${l.workspaceMb}) must be below memory_mb (${l.memoryMb})',
        );
      }
      if (diskBacked && disk == null) {
        throw SupervisorConfigError(
          'profile ${p.name} has a disk workspace: SANDBOX_DISK_ROOT and the '
          'other SANDBOX_DISK_* settings are required',
        );
      }
      if (diskBacked && l.workspaceMb > disk!.budgetMb) {
        throw SupervisorConfigError(
          'profile ${p.name}: workspace_mb (${l.workspaceMb}) exceeds '
          'SANDBOX_DISK_BUDGET_MB (${disk!.budgetMb})',
        );
      }
    }
  }

  static Ipv4Net _pool(String text) {
    final pool = Ipv4Net.tryParse(text);
    if (pool == null || pool.prefix > sandboxSubnetPrefix) {
      throw SupervisorConfigError(
        'SANDBOX_SUBNET_POOL must be an IPv4 network of /$sandboxSubnetPrefix '
        'or larger, e.g. 10.213.0.0/16',
      );
    }
    if (!proxyRefusedRanges.any((r) => r.containsNet(pool))) {
      throw SupervisorConfigError(
        'SANDBOX_SUBNET_POOL must lie inside 10.0.0.0/8, 172.16.0.0/12, '
        '192.168.0.0/16 or 100.64.0.0/10 (destinations the proxy refuses)',
      );
    }
    return pool;
  }

  final String key;

  /// The agent service container(s) attached to every sandbox network:
  /// container names, or compose service names when [composeProject] is set.
  final List<String> agentPeers;

  /// The proxy container attached to every sandbox network (same naming as
  /// [agentPeers]); sandboxes get `HTTP(S)_PROXY=http://<its address on the
  /// sandbox network>:[proxyPort]`. Without it sandboxes have no egress.
  final String? proxyPeer;
  final int proxyPort;

  /// The configured peer is a dedicated Responses reverse proxy, rather
  /// than a general HTTP proxy. Only explicit allowlist profiles receive it.
  final bool codexGateway;

  /// Peers are compose services of this project (labels
  /// `com.docker.compose.project` and `com.docker.compose.service`).
  final String? composeProject;

  /// Split into one /28 per sandbox.
  final Ipv4Net subnetPool;
  final String image;
  final String dockerSocket;
  final int port;
  final String labelKey;
  final String labelValue;
  final String namePrefix;
  final int memoryMb;
  final double cpus;
  final int pidsLimit;
  final int homeMb;
  final int workspaceMb;
  final int uid;
  final int gid;
  final String noProxy;

  /// Sandbox URLs use the container's IP on its network instead of its name
  /// (for a caller outside Docker's DNS, e.g. the integration test).
  final bool addressByIp;

  /// Where known sandboxes are recorded; without it, they are kept in memory
  /// only and a restart removes every labelled container.
  final String? statePath;
  final Duration startTimeout;

  /// The executor profiles (`AGENT_EXECUTOR_PROFILES`); without a file, the
  /// implicit `default` with [image] and the limits above.
  final ExecutorProfiles profiles;

  /// Resolves a profile device on this host (default: [statDevice]).
  final DeviceInfo? Function(String path) device;

  /// Disk workspaces (`SANDBOX_DISK_*`); required by profiles with
  /// `workspace.backing: disk`.
  final DiskWorkspaceConfig? disk;

  /// The image of [profile]: its pinned image, or [image] for the implicit
  /// `default`.
  String imageOf(ExecutorProfile profile) => profile.image ?? image;

  /// The limits of [profile], missing values from this configuration.
  ({double cpus, int memoryMb, int pids, int homeMb, int workspaceMb}) limitsOf(
    ExecutorProfile profile,
  ) {
    final l = profile.limits;
    return (
      cpus: l.cpus ?? cpus,
      memoryMb: l.memoryMb ?? memoryMb,
      pids: l.pids ?? pidsLimit,
      homeMb: l.homeMb ?? homeMb,
      workspaceMb: l.workspaceMb ?? workspaceMb,
    );
  }

  String get label => '$labelKey=$labelValue';

  /// The filters selecting this supervisor's sandboxes and their networks:
  /// its label and the execution label (never the label alone, which other
  /// objects may carry, e.g. a compose project labelled the same way).
  List<String> get sandboxFilters => [label, executionLabel];

  /// Reads `SANDBOX_*` and `DOCKER_SOCKET` (see README.md).
  static SupervisorConfig fromEnv(Map<String, String> env) {
    String? opt(String name) {
      final v = env[name]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    String req(String name) =>
        opt(name) ?? (throw SupervisorConfigError('$name is required'));

    int intOf(String name, int fallback, {int min = 1, int max = 1 << 31}) {
      final v = opt(name);
      if (v == null) return fallback;
      final n = int.tryParse(v);
      if (n == null || n < min || n > max) {
        throw SupervisorConfigError('$name must be an integer in $min..$max');
      }
      return n;
    }

    for (final gone in ['SANDBOX_NETWORK', 'SANDBOX_PROXY_URL']) {
      if (opt(gone) != null) {
        throw SupervisorConfigError(
          '$gone is no longer used: every sandbox gets its own network '
          '(SANDBOX_SUBNET_POOL, SANDBOX_AGENT_PEERS, SANDBOX_PROXY_PEER)',
        );
      }
    }
    final label = opt('SANDBOX_LABEL') ?? 'dify-sf.agent-sandbox=1';
    final eq = label.indexOf('=');
    if (eq <= 0 || eq == label.length - 1) {
      throw SupervisorConfigError('SANDBOX_LABEL must be key=value');
    }
    final cpus = double.tryParse(opt('SANDBOX_CPUS') ?? '1');
    if (cpus == null || cpus <= 0) {
      throw SupervisorConfigError('SANDBOX_CPUS must be a positive number');
    }
    final address = opt('SANDBOX_ADDRESS') ?? 'name';
    if (address != 'name' && address != 'ip') {
      throw SupervisorConfigError('SANDBOX_ADDRESS must be name or ip');
    }
    final agents = [
      for (final p in req('SANDBOX_AGENT_PEERS').split(','))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    final disk = DiskWorkspaceConfig.fromEnv(opt);
    final ExecutorProfiles profiles;
    try {
      profiles = ExecutorProfiles.load(
        opt('AGENT_EXECUTOR_PROFILES'),
        forbiddenSources: [
          opt('DOCKER_SOCKET') ?? '/var/run/docker.sock',
          ?opt('SANDBOX_STATE_FILE'),
          ?disk?.root,
          ?disk?.hostRoot,
        ],
      );
    } on ProfileLoadError catch (e) {
      throw SupervisorConfigError(e.toString());
    }
    final config = SupervisorConfig(
      key: req('SANDBOX_SUPERVISOR_KEY'),
      agentPeers: agents,
      proxyPeer: opt('SANDBOX_PROXY_PEER'),
      proxyPort: intOf('SANDBOX_PROXY_PORT', 3128, max: 65535),
      codexGateway: opt('SANDBOX_CODEX_GATEWAY') == 'true',
      composeProject: opt('SANDBOX_COMPOSE_PROJECT'),
      subnetPool: opt('SANDBOX_SUBNET_POOL') ?? '10.213.0.0/16',
      image:
          opt('SANDBOX_IMAGE') ?? 'langgenius/dify-agent-local-sandbox:1.17.1',
      dockerSocket: opt('DOCKER_SOCKET') ?? '/var/run/docker.sock',
      port: intOf('SANDBOX_SUPERVISOR_PORT', 5060, min: 0, max: 65535),
      labelKey: label.substring(0, eq),
      labelValue: label.substring(eq + 1),
      namePrefix: opt('SANDBOX_NAME_PREFIX') ?? 'dify-sf-sandbox-',
      memoryMb: intOf('SANDBOX_MEMORY_MB', 1024, min: 64),
      cpus: cpus,
      pidsLimit: intOf('SANDBOX_PIDS_LIMIT', 256, min: 16),
      homeMb: intOf('SANDBOX_HOME_MB', 256),
      workspaceMb: intOf('SANDBOX_WORKSPACE_MB', 512),
      uid: intOf('SANDBOX_UID', 1000, min: 0),
      gid: intOf('SANDBOX_GID', 1000, min: 0),
      noProxy: opt('SANDBOX_NO_PROXY') ?? 'localhost,127.0.0.1',
      addressByIp: address == 'ip',
      statePath: opt('SANDBOX_STATE_FILE'),
      startTimeout: Duration(seconds: intOf('SANDBOX_START_TIMEOUT', 60)),
      profiles: profiles,
      disk: disk,
    );
    if (config.homeMb + config.workspaceMb >= config.memoryMb) {
      // tmpfs pages are charged to the container's memory limit.
      throw SupervisorConfigError(
        'SANDBOX_HOME_MB + SANDBOX_WORKSPACE_MB must be below SANDBOX_MEMORY_MB',
      );
    }
    return config;
  }
}

/// A request error answered as `{"error", "message"}`.
class SupervisorError implements Exception {
  SupervisorError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => 'SupervisorError($status $code: $message)';
}

class SandboxSupervisor {
  SandboxSupervisor(
    this.config, {
    DockerClient? docker,
    this.log,
    DiskWorkspaces Function(DockerClient docker)? disks,
  }) : docker = docker ?? DockerClient(config.dockerSocket) {
    final d = config.disk;
    if (disks != null) {
      this.disks = disks(this.docker);
    } else if (d != null) {
      this.disks = DiskWorkspaces(
        d,
        docker: this.docker,
        helper: DockerLoopHelper(
          this.docker,
          d,
          labelKey: config.labelKey,
          labelValue: config.labelValue,
          namePrefix: config.namePrefix,
        ),
        labelKey: config.labelKey,
        labelValue: config.labelValue,
        namePrefix: config.namePrefix,
        uid: config.uid,
        gid: config.gid,
        log: log,
      );
    }
  }

  final SupervisorConfig config;
  final DockerClient docker;
  final void Function(String message)? log;

  /// Disk workspaces; null without `SANDBOX_DISK_*`.
  DiskWorkspaces? disks;

  final Random _random = Random.secure();

  /// Known sandboxes: container ID → execution key hash.
  final Map<String, String> _known = {};
  final Map<String, Future<void>> _locks = {};
  HttpServer? _server;

  int get port => _server!.port;
  Set<String> get knownIds => Set.unmodifiable(_known.keys);

  static String hashKey(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  /// The name of the execution's container and of its network.
  String containerName(String executionKey) =>
      '${config.namePrefix}${hashKey(executionKey).substring(0, 24)}';

  Map<String, String> _labels(String hash, {String? profile}) => {
    config.labelKey: config.labelValue,
    executionLabel: hash,
    profileLabel: ?profile,
  };

  /// The profile recorded on a container (`default` when it has none).
  static String profileOf(Map<String, Object?> inspectOrSummary) {
    final labels =
        (inspectOrSummary['Config'] as Map?)?['Labels'] ??
        inspectOrSummary['Labels'];
    final p = labels is Map ? labels[profileLabel] : null;
    return p is String && p.isNotEmpty ? p : defaultProfileName;
  }

  ExecutorProfile _profile(String name) =>
      config.profiles[name] ??
      (throw SupervisorError(
        400,
        'unknown_profile',
        'no executor profile $name in this supervisor\'s profile file',
      ));

  /// The network create payload: internal, no IPv4 address on the bridge,
  /// one /28, labelled like the sandbox.
  Map<String, Object?> networkPayload(
    String name,
    String hash,
    Ipv4Net subnet,
  ) => {
    'Name': name,
    'Driver': 'bridge',
    'Internal': true,
    'Attachable': false,
    'EnableIPv6': false,
    'IPAM': {
      'Driver': 'default',
      'Config': [
        {
          'Subnet': '$subnet',
          'IPRange': '${subnet.subnet(1, subnet.prefix + 1)}',
          'Gateway': subnet.host(gatewayHost),
        },
      ],
    },
    'Options': {inhibitIpv4Option: 'true'},
    'Labels': _labels(hash),
  };

  /// The Landlock variables of a sandbox (see [createPayload]).
  static Map<String, String> landlockEnv(
    List<String> renderNodes,
    Iterable<String> sysfsDirs,
  ) => {
    'SHELLCTL_LANDLOCK_RO_PATHS': [
      ...shellctlLandlockRoDefaults,
      '/opt',
      if (renderNodes.isNotEmpty) ...['/dev/dri', '/sys/dev/char'],
      ...{...sysfsDirs},
    ].join(','),
    'SHELLCTL_LANDLOCK_RW_DEV_PATHS': [
      ...shellctlLandlockRwDevDefaults,
      ...renderNodes,
    ].join(','),
  };

  /// The container create payload: everything but the token and the
  /// network is fixed by the configuration and the [profile]: its image,
  /// limits, read-only binds under /opt, render nodes (with their host
  /// groups as supplementary groups, from [devices]) and whether the proxy
  /// is used.
  ///
  /// shellctl confines every job with Landlock. Its variables are set in the
  /// daemon's environment, which jobs inherit (a node cannot set
  /// `SHELLCTL_*`): the defaults plus `/opt` (profile images and binds put
  /// their tools there; the base image's `/opt` is empty), and for render
  /// nodes `/dev/dri`, `/sys/dev/char` and each GPU's sysfs directory
  /// read-only and the nodes read-write (see [landlockEnv]).
  Map<String, Object?> createPayload(
    String executionKey,
    String token, {
    required String network,
    required Ipv4Net subnet,
    ExecutorProfile? profile,
    Map<String, DeviceInfo> devices = const {},
    String? workspaceVolume,
  }) {
    final c = config;
    final p = profile ?? c.profiles[defaultProfileName]!;
    final limits = c.limitsOf(p);
    String tmpfs(int mb) =>
        'rw,exec,nosuid,nodev,size=${mb}m,mode=0700,uid=${c.uid},gid=${c.gid}';
    final proxy = c.proxyPeer == null || p.egress == Egress.none
        ? null
        : 'http://${subnet.host(proxyHost)}:${c.proxyPort}';
    final groups = <String>{for (final d in p.devices) '${devices[d]?.group}'}
        .toList();
    final landlock = landlockEnv(p.devices, [
      for (final d in p.devices) ?devices[d]?.sysfs,
    ]);
    return {
      'Image': c.imageOf(p),
      'Env': [
        'SHELLCTL_AUTH_TOKEN=$token',
        for (final e in landlock.entries) '${e.key}=${e.value}',
        if (proxy != null) ...[
          'HTTP_PROXY=$proxy',
          'HTTPS_PROXY=$proxy',
          'http_proxy=$proxy',
          'https_proxy=$proxy',
          'NO_PROXY=${c.noProxy}',
          'no_proxy=${c.noProxy}',
        ],
      ],
      'Labels': _labels(hashKey(executionKey), profile: p.name),
      'Healthcheck': {
        'Test': [
          'CMD',
          'curl',
          '-fsS',
          'http://127.0.0.1:$shellctlPort/healthz',
        ],
        'Interval': 30 * 1000000000,
        'Timeout': 5 * 1000000000,
        'Retries': 3,
        'StartPeriod': c.startTimeout.inSeconds * 1000000000,
        'StartInterval': 500000000,
      },
      'HostConfig': {
        'NetworkMode': network,
        'Memory': limits.memoryMb * 1024 * 1024,
        'MemorySwap': limits.memoryMb * 1024 * 1024,
        'NanoCpus': (limits.cpus * 1e9).round(),
        'PidsLimit': limits.pids,
        'ReadonlyRootfs': true,
        'Tmpfs': {
          '/home/dify': tmpfs(limits.homeMb),
          if (workspaceVolume == null)
            '/workspace': tmpfs(limits.workspaceMb),
        },
        'CapDrop': ['ALL'],
        'SecurityOpt': ['no-new-privileges:true'],
        'Privileged': false,
        'Binds': <String>[],
        'Mounts': [
          for (final m in p.mounts)
            {
              'Type': 'bind',
              'Source': m.source,
              'Target': m.target,
              'ReadOnly': true,
              'BindOptions': {'Propagation': 'rprivate'},
            },
          if (workspaceVolume != null)
            {
              'Type': 'volume',
              'Source': workspaceVolume,
              'Target': '/workspace',
              'VolumeOptions': {'NoCopy': true},
            },
        ],
        if (p.devices.isNotEmpty) ...{
          'Devices': [
            for (final d in p.devices)
              {
                'PathOnHost': d,
                'PathInContainer': d,
                'CgroupPermissions': 'rw',
              },
          ],
          'GroupAdd': groups,
        },
        'IpcMode': 'private',
        'Sysctls': {
          'net.ipv6.conf.all.disable_ipv6': '1',
          'net.ipv6.conf.default.disable_ipv6': '1',
        },
        'RestartPolicy': {'Name': 'no'},
        'LogConfig': {
          'Type': 'json-file',
          'Config': {'max-size': '1m', 'max-file': '1'},
        },
      },
      'NetworkingConfig': {
        'EndpointsConfig': {
          network: {
            'IPAMConfig': {'IPv4Address': subnet.host(sandboxHost)},
          },
        },
      },
    };
  }

  // ---- lifecycle ----------------------------------------------------------

  Future<int> start({Object address = '0.0.0.0', int? port}) async {
    disks?.checkRoot();
    _loadState();
    await sweep();
    final server = _server = await HttpServer.bind(
      address,
      port ?? config.port,
    );
    server.listen((r) => unawaited(_handle(r)));
    log?.call('sandbox supervisor listening on port ${server.port}');
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    docker.close();
  }

  /// Removes every labelled container this supervisor does not know of (with
  /// its network), every labelled sandbox network no known container uses,
  /// and forgets known containers that no longer exist. Objects without both
  /// labels are never listed, so never touched.
  Future<List<String>> sweep() async {
    final removed = <String>[];
    final removedHashes = <String>{};
    final present = <String>{};
    final keptNetworks = <String>{};
    for (final c in await docker.listContainers(config.sandboxFilters)) {
      final id = c['Id'] as String;
      final network = (c['HostConfig'] as Map?)?['NetworkMode'] as String?;
      present.add(id);
      if (_known.containsKey(id)) {
        if (network != null) keptNetworks.add(network);
        continue;
      }
      await docker.removeContainer(id);
      removed.add(id);
      final hash = (c['Labels'] as Map?)?[executionLabel];
      if (hash is String) removedHashes.add(hash);
      log?.call('sweep removed unknown sandbox $id');
    }
    await disks?.sweep(removedHashes);
    for (final n in await docker.listNetworks(config.sandboxFilters)) {
      final name = n['Name'] as String;
      if (keptNetworks.contains(name) || keptNetworks.contains(n['Id'])) {
        continue;
      }
      await _removeNetwork(name);
      log?.call('sweep removed unused sandbox network $name');
    }
    final before = _known.length;
    _known.removeWhere((id, _) => !present.contains(id));
    if (_known.length != before || removed.isNotEmpty) _saveState();
    return removed;
  }

  void _loadState() {
    final path = config.statePath;
    if (path == null) return;
    final f = File(path);
    if (!f.existsSync()) return;
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is Map && decoded['sandboxes'] is Map) {
      (decoded['sandboxes'] as Map).forEach((k, v) {
        if (k is String && v is String) _known[k] = v;
      });
    }
  }

  void _saveState() {
    final path = config.statePath;
    if (path == null) return;
    final tmp = File('$path.tmp');
    tmp.parent.createSync(recursive: true);
    tmp.writeAsStringSync(jsonEncode({'sandboxes': _known}), flush: true);
    tmp.renameSync(path);
  }

  Future<T> _locked<T>(String key, Future<T> Function() body) async {
    final previous = _locks[key] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[key] = done.future;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
      if (identical(_locks[key], done.future)) _locks.remove(key);
    }
  }

  bool _labelled(Map<String, Object?> inspect) {
    final labels = (inspect['Config'] as Map?)?['Labels'] ?? inspect['Labels'];
    return labels is Map &&
        labels[config.labelKey] == config.labelValue &&
        labels[executionLabel] is String;
  }

  String _newToken() {
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ---- peers --------------------------------------------------------------

  /// Container IDs of one configured peer: by compose labels when a compose
  /// project is configured, else by container name. Sandboxes never count.
  Future<List<String>> _resolvePeer(String ref) async {
    final project = config.composeProject;
    if (project != null) {
      final found = await docker.listContainers([
        'com.docker.compose.project=$project',
        'com.docker.compose.service=$ref',
      ], runningOnly: true);
      return [
        for (final c in found)
          if ((c['Labels'] as Map?)?[executionLabel] == null) c['Id'] as String,
      ];
    }
    final inspect = await docker.inspectContainer(ref);
    if (inspect == null || _labelled(inspect)) return const [];
    if ((inspect['State'] as Map?)?['Running'] != true) return const [];
    return [inspect['Id'] as String];
  }

  /// The proxy (null when none is configured or [withProxy] is false: a
  /// profile with `egress: none`) and the agent containers.
  Future<({String? proxy, List<String> agents})> _peers({
    bool withProxy = true,
  }) async {
    String? proxy;
    final ref = withProxy ? config.proxyPeer : null;
    if (ref != null) {
      final ids = await _resolvePeer(ref);
      if (ids.length != 1) {
        throw SupervisorError(
          503,
          'peer_unavailable',
          'the proxy peer $ref resolves to ${ids.length} running containers',
        );
      }
      proxy = ids.single;
    }
    final agents = <String>[];
    for (final a in config.agentPeers) {
      final ids = await _resolvePeer(a);
      if (ids.isEmpty) {
        throw SupervisorError(
          503,
          'peer_unavailable',
          'the agent peer $a has no running container',
        );
      }
      agents.addAll(ids.where((id) => !agents.contains(id)));
    }
    return (proxy: proxy, agents: agents);
  }

  /// Connects the peers missing from [network] (e.g. after a peer container
  /// was recreated): the proxy at its fixed address, agents anywhere.
  Future<void> _attachPeers(
    String network,
    Ipv4Net subnet,
    ({String? proxy, List<String> agents}) peers,
  ) async {
    final inspect = await docker.inspectNetwork(network);
    if (inspect == null) {
      throw SupervisorError(503, 'sandbox_start_failed', 'network vanished');
    }
    final attached = ((inspect['Containers'] as Map?) ?? const {}).keys.toSet();
    final proxy = peers.proxy;
    if (proxy != null && !attached.contains(proxy)) {
      await docker.connectNetwork(network, proxy, ipv4: subnet.host(proxyHost));
    }
    for (final a in peers.agents) {
      if (!attached.contains(a)) await docker.connectNetwork(network, a);
    }
  }

  // ---- networks -----------------------------------------------------------

  /// The IPv4 subnets of every Docker network on the host.
  Future<List<Ipv4Net>> _usedSubnets() async => [
    for (final n in await docker.listNetworks())
      for (final c in ((n['IPAM'] as Map?)?['Config'] as List?) ?? const [])
        if (c is Map && c['Subnet'] is String)
          ?Ipv4Net.tryParse(c['Subnet'] as String),
  ];

  /// Creates the execution's network on the first /28 of the pool that
  /// overlaps no existing network. Allocations are serialized; a subnet
  /// Docker still refuses (e.g. taken concurrently by another process) is
  /// skipped. A leftover labelled network of the same name is replaced.
  Future<Ipv4Net> _createNetwork(String name, String hash) =>
      _locked('\u0000subnets', () async {
        final existing = await docker.inspectNetwork(name);
        if (existing != null) {
          if (!_labelled(existing)) {
            throw SupervisorError(
              409,
              'name_conflict',
              'a network named $name exists and is not a sandbox network',
            );
          }
          await _removeNetwork(name);
        }
        final used = await _usedSubnets();
        final pool = config.subnetPool;
        final count = pool.size ~/ (1 << (32 - sandboxSubnetPrefix));
        for (var i = 0; i < count; i++) {
          final candidate = pool.subnet(i, sandboxSubnetPrefix);
          if (used.any(candidate.overlaps)) continue;
          try {
            await docker.createNetwork(networkPayload(name, hash, candidate));
            return candidate;
          } on DockerException catch (e) {
            if (e.status == 0 || !e.message.toLowerCase().contains('overlap')) {
              rethrow;
            }
            used.add(candidate);
          }
        }
        throw SupervisorError(
          503,
          'subnet_pool_exhausted',
          'no free /$sandboxSubnetPrefix in $pool',
        );
      });

  /// The subnet of a sandbox network, from its IPAM configuration.
  static Ipv4Net? _subnetOf(Map<String, Object?> network) {
    for (final c
        in ((network['IPAM'] as Map?)?['Config'] as List?) ?? const []) {
      final subnet = c is Map ? Ipv4Net.tryParse('${c['Subnet']}') : null;
      if (subnet != null) return subnet;
    }
    return null;
  }

  /// Disconnects every endpoint still attached (the peers) and removes a
  /// labelled sandbox network; false when it is absent. Unlabelled networks
  /// are never touched.
  Future<bool> _removeNetwork(String network) async {
    final inspect = await docker.inspectNetwork(network);
    if (inspect == null) return false;
    if (!_labelled(inspect)) return false;
    final id = inspect['Id'] as String;
    for (final c in ((inspect['Containers'] as Map?) ?? const {}).keys) {
      await docker.disconnectNetwork(id, c as String);
    }
    return docker.removeNetwork(id);
  }

  // ---- sandboxes ----------------------------------------------------------

  /// The status of [profile] on this host: `ok`, `image_missing` (its
  /// image is not present; nothing is pulled) or `device_missing` (a render
  /// node does not exist).
  Future<String> profileStatus(ExecutorProfile profile) async {
    if (await docker.inspectImage(config.imageOf(profile)) == null) {
      return 'image_missing';
    }
    final disk = config.disk;
    if (profile.workspaceBacking == WorkspaceBacking.disk &&
        disk != null &&
        await docker.inspectImage(disk.toolImage) == null) {
      return 'image_missing';
    }
    for (final d in profile.devices) {
      if (config.device(d) == null) return 'device_missing';
    }
    return 'ok';
  }

  /// Creates (or returns) the sandbox of [executionKey] with [profileName].
  Future<Map<String, Object?>> acquire(
    String executionKey, {
    String profileName = defaultProfileName,
  }) => _locked(hashKey(executionKey), () async {
    final profile = _profile(profileName);
    final withProxy = profile.egress == Egress.allowlist;
    final name = containerName(executionKey);
    final hash = hashKey(executionKey);
    final disks = profile.workspaceBacking == WorkspaceBacking.disk
        ? this.disks
        : null;
    for (var attempt = 0; attempt < 3; attempt++) {
      final existing = await docker.inspectContainer(name);
      if (existing != null) {
        if (!_labelled(existing)) {
          throw SupervisorError(
            409,
            'name_conflict',
            'a container named $name exists and is not a sandbox',
          );
        }
        final had = profileOf(existing);
        if (had != profile.name) {
          throw SupervisorError(
            409,
            'profile_conflict',
            'the sandbox of this execution has profile $had, not '
                '${profile.name}',
          );
        }
        final id = existing['Id'] as String;
        final state = existing['State'] as Map?;
        final network = await docker.inspectNetwork(name);
        final subnet = network == null ? null : _subnetOf(network);
        if (state?['Running'] == true &&
            (state?['Health'] as Map?)?['Status'] != 'unhealthy' &&
            network != null &&
            subnet != null &&
            _labelled(network)) {
          _known[id] = hash;
          _saveState();
          await _attachPeers(name, subnet, await _peers(withProxy: withProxy));
          final ready = await _waitHealthy(id);
          await disks?.addSandbox(hash, id);
          return _describe(
            ready,
            subnet,
            created: false,
            keptFrom: disks?.keptFrom(hash, id),
          );
        }
        // Stopped (its tmpfs workspace is gone; a disk workspace stays),
        // unhealthy or without its network: replace it.
        log?.call('replacing stopped sandbox $id');
        await _removeSandbox(id, name);
      }
      final peers = await _peers(withProxy: withProxy);
      switch (await profileStatus(profile)) {
        case 'ok':
          break;
        case final status:
          throw SupervisorError(
            503,
            status,
            status == 'image_missing'
                ? 'the image of profile ${profile.name} is not on this host'
                : 'a device of profile ${profile.name} is not on this host',
          );
      }
      final devices = {for (final d in profile.devices) d: config.device(d)!};
      // Before the network: a busy pool or budget answers without leftovers.
      final workspace = await disks?.ensure(
        hash,
        config.limitsOf(profile).workspaceMb,
      );
      final Ipv4Net subnet;
      try {
        subnet = await _createNetwork(name, hash);
      } catch (_) {
        if (workspace?.fresh == true) await _releaseDisk(hash);
        rethrow;
      }
      String? id;
      try {
        if (peers.proxy case final proxy?) {
          await docker.connectNetwork(
            name,
            proxy,
            ipv4: subnet.host(proxyHost),
          );
        }
        final token = _newToken();
        id = await docker.createContainer(
          name,
          createPayload(
            executionKey,
            token,
            network: name,
            subnet: subnet,
            profile: profile,
            devices: devices,
            workspaceVolume: workspace?.volume,
          ),
        );
        if (id == null) {
          // Created concurrently: inspect again.
          await _removeNetwork(name);
          continue;
        }
        _known[id] = hash;
        _saveState();
        await disks?.addSandbox(hash, id);
        for (final a in peers.agents) {
          await docker.connectNetwork(name, a);
        }
        await docker.startContainer(id);
        final ready = await _waitHealthy(id);
        log?.call('created sandbox $id on $subnet');
        return _describe(
          ready,
          subnet,
          created: true,
          keptFrom: workspace?.keptFrom,
        );
      } catch (e) {
        if (id != null) {
          await docker.removeContainer(id).catchError((_) => false);
          _known.remove(id);
          _saveState();
        }
        await _removeNetwork(name).catchError((_) => false);
        // A new disk workspace goes with the failed sandbox; a kept one
        // stays for the execution.
        if (workspace?.fresh == true) await _releaseDisk(hash);
        rethrow;
      }
    }
    throw SupervisorError(503, 'sandbox_conflict', 'could not create $name');
  });

  Future<Map<String, Object?>> _waitHealthy(String id) async {
    final deadline = DateTime.now().add(config.startTimeout);
    while (true) {
      final inspect = await docker.inspectContainer(id);
      if (inspect == null) {
        throw SupervisorError(503, 'sandbox_start_failed', 'sandbox vanished');
      }
      final state = (inspect['State'] as Map?) ?? const {};
      final health = (state['Health'] as Map?)?['Status'];
      if (state['Running'] == true && health == 'healthy') return inspect;
      if (state['Running'] != true && state['Status'] != 'created') {
        throw SupervisorError(
          503,
          'sandbox_start_failed',
          'sandbox exited (${state['Status']}, exit ${state['ExitCode']})',
        );
      }
      if (health == 'unhealthy' || DateTime.now().isAfter(deadline)) {
        throw SupervisorError(
          503,
          'sandbox_start_failed',
          'shellctl /healthz did not become ready',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Releases a disk workspace on a failure path (logged, never thrown).
  Future<void> _releaseDisk(String hash) async {
    try {
      await disks?.release(hash);
    } catch (e) {
      log?.call('disk workspace $hash not released: $e');
    }
  }

  /// [keptFrom]: a disk workspace, with the earlier sandboxes whose files it
  /// keeps (`workspace_kept_from`).
  Map<String, Object?> _describe(
    Map<String, Object?> inspect,
    Ipv4Net subnet, {
    required bool created,
    List<String>? keptFrom,
  }) {
    final id = inspect['Id'] as String;
    final env = ((inspect['Config'] as Map?)?['Env'] as List?) ?? const [];
    const prefix = 'SHELLCTL_AUTH_TOKEN=';
    final token = env
        .whereType<String>()
        .firstWhere((e) => e.startsWith(prefix), orElse: () => prefix)
        .substring(prefix.length);
    final name = (inspect['Name'] as String? ?? '').replaceFirst('/', '');
    final String host;
    if (config.addressByIp) {
      final networks =
          ((inspect['NetworkSettings'] as Map?)?['Networks'] as Map?) ??
          const {};
      final ip = (networks[name] as Map?)?['IPAddress'];
      if (ip is! String || ip.isEmpty) {
        throw SupervisorError(503, 'sandbox_start_failed', 'sandbox has no IP');
      }
      host = ip;
    } else {
      host = name;
    }
    return {
      'sandbox_id': id,
      'url': 'http://$host:$shellctlPort',
      'token': token,
      'gateway': subnet.host(gatewayHost),
      'created': created,
      'profile': profileOf(inspect),
      if (keptFrom != null) ...{
        'workspace': 'disk',
        'workspace_kept_from': keptFrom,
      },
      if (config.codexGateway &&
          config.profiles[profileOf(inspect)]?.egress == Egress.allowlist)
        'codex_gateway_url':
            'http://${subnet.host(proxyHost)}:${config.proxyPort}/inner/agent/codex/v1',
    };
  }

  /// Removes the container, then its network (peers disconnected first).
  Future<bool> _removeSandbox(String id, String network) async {
    final removed = await docker.removeContainer(id);
    _known.remove(id);
    _saveState();
    await _removeNetwork(network);
    return removed;
  }

  /// Force-removes a labelled container and its network; false when the
  /// container does not exist.
  Future<bool> remove(String sandboxId) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(sandboxId)) {
      throw SupervisorError(400, 'invalid_request', 'invalid sandbox_id');
    }
    final inspect = await docker.inspectContainer(sandboxId);
    if (inspect == null) {
      if (_known.remove(sandboxId) != null) _saveState();
      // Its container is gone; its disk workspace goes unless another
      // sandbox of the execution uses it (a retried or late removal).
      final lease = disks?.leaseOfSandbox(sandboxId);
      if (lease != null) {
        await _locked(lease.hash, () async {
          final users = await docker.listContainers([
            ...config.sandboxFilters,
            '$executionLabel=${lease.hash}',
          ]);
          if (users.isEmpty) await disks!.release(lease.hash);
        });
      }
      return false;
    }
    if (!_labelled(inspect)) {
      throw SupervisorError(404, 'not_found', 'no sandbox $sandboxId');
    }
    final id = inspect['Id'] as String;
    final hash = ((inspect['Config'] as Map?)?['Labels'] as Map)[executionLabel]
        as String;
    final network =
        (inspect['HostConfig'] as Map?)?['NetworkMode'] as String? ??
        (inspect['Name'] as String? ?? '').replaceFirst('/', '');
    return _locked(hash, () async {
      final removed = await _removeSandbox(id, network);
      log?.call('removed sandbox $id and its network');
      await disks?.release(hash);
      return removed;
    });
  }

  Future<List<Map<String, Object?>>> list() async => [
    for (final c in await docker.listContainers(config.sandboxFilters))
      {
        'sandbox_id': c['Id'],
        'name': ((c['Names'] as List?)?.firstOrNull as String?)?.replaceFirst(
          '/',
          '',
        ),
        'state': c['State'],
        'execution_sha256': (c['Labels'] as Map?)?[executionLabel],
        'profile': profileOf(c),
        'known': _known.containsKey(c['Id']),
      },
  ];

  // ---- HTTP ---------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final header = request.headers.value(HttpHeaders.authorizationHeader);
      if (header == null || !_equals(header, 'Bearer ${config.key}')) {
        throw SupervisorError(401, 'unauthorized', 'missing or invalid key');
      }
      final segments = request.uri.pathSegments;
      switch ((request.method, segments)) {
        case ('GET', ['v1', 'health']):
          var dockerOk = true;
          try {
            await docker.ping();
          } on DockerException {
            dockerOk = false;
          }
          return _json(response, dockerOk ? 200 : 503, {
            'status': dockerOk ? 'ok' : 'degraded',
            'docker': dockerOk ? 'ok' : 'unreachable',
          });
        case ('GET', ['v1', 'profiles']):
          return _json(response, 200, {
            'profiles': {
              for (final p in config.profiles.profiles.values)
                p.name: {'status': await profileStatus(p), 'digest': p.digest},
            },
          });
        case ('POST', ['v1', 'sandboxes']):
          final body = await _body(request);
          final extra = body.keys
              .where((k) => k != 'execution_key' && k != 'profile')
              .toList();
          if (extra.isNotEmpty) {
            throw SupervisorError(
              400,
              'invalid_request',
              'only execution_key and profile may be given; got '
                  '${extra.join(', ')}',
            );
          }
          final profile = body['profile'] ?? defaultProfileName;
          if (profile is! String || profile.isEmpty) {
            throw SupervisorError(
              400,
              'invalid_request',
              'profile must be a profile name',
            );
          }
          final key = body['execution_key'];
          if (key is! String || key.isEmpty || key.length > 512) {
            throw SupervisorError(
              400,
              'invalid_request',
              'execution_key must be a string of 1..512 characters',
            );
          }
          final sandbox = await acquire(key, profileName: profile);
          return _json(
            response,
            sandbox['created'] == true ? 201 : 200,
            sandbox,
          );
        case ('GET', ['v1', 'sandboxes']):
          return _json(response, 200, {'sandboxes': await list()});
        case ('DELETE', ['v1', 'sandboxes', final id]):
          final deleted = await remove(id);
          return _json(response, 200, {'sandbox_id': id, 'deleted': deleted});
        default:
          throw SupervisorError(404, 'not_found', 'no such route');
      }
    } on SupervisorError catch (e) {
      _json(response, e.status, {'error': e.code, 'message': e.message});
    } on DockerException catch (e) {
      log?.call('docker error: $e');
      _json(response, 502, {'error': 'docker_error', 'message': e.message});
    } catch (e, st) {
      log?.call('supervisor request failed: $e\n$st');
      _json(response, 500, {'error': 'internal', 'message': 'internal error'});
    }
  }

  static bool _equals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    if (x.length != y.length) return false;
    var diff = 0;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  static Future<Map<String, Object?>> _body(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > 64 * 1024) {
        throw SupervisorError(413, 'body_too_large', 'body exceeds 64 KiB');
      }
    }
    try {
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Answered below.
    }
    throw SupervisorError(400, 'invalid_json', 'body must be a JSON object');
  }

  static void _json(HttpResponse response, int status, Object body) {
    try {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      unawaited(response.close().then((_) {}, onError: (_) {}));
    } catch (_) {
      // The client went away.
    }
  }
}
