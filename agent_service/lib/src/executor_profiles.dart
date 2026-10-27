/// Executor profiles (docs/agent-v2.md, "Executor profiles"): named sandbox
/// environments defined by the administrator in one JSON file, read at start
/// by the agent service and by the sandbox supervisor. A request only names
/// a profile; images, mounts, devices, network rules, limits and environment
/// come from this file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'protocol.dart'
    show
        ApiError,
        OperationRequest,
        canonicalJson,
        isReservedEnvName,
        profileNamePattern;

/// The profile used when a request names none.
const defaultProfileName = 'default';

/// The file read when `AGENT_EXECUTOR_PROFILES` is not set.
const defaultProfilesPath = '/etc/dify-sf/executor-profiles.json';

/// `timeout_seconds_max` of a profile that sets none (the service's default
/// run timeout).
const defaultTimeoutSecondsMax = 1800;

/// Largest `timeout_seconds_max` a profile may set (24 hours).
const maxTimeoutSecondsMax = 86400;

/// `name[:tag]@sha256:<64 hex>`, optionally with a registry host.
final _pinnedImage = RegExp(
  r'^(?:[a-z0-9.-]+(?::[0-9]+)?/)?[a-z0-9]+(?:[._-][a-z0-9]+)*'
  r'(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?'
  r'@sha256:[a-f0-9]{64}$',
);

final _renderNode = RegExp(r'^/dev/dri/renderD[0-9]{1,3}$');
final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Host paths a mount source may never be, contain or lie inside, whatever
/// the deployment: the container runtime's sockets and state, kernel
/// interfaces, and device nodes (devices go through `devices` only).
const builtinForbiddenSources = [
  '/var/run/docker.sock',
  '/run/docker.sock',
  '/var/run/docker',
  '/run/docker',
  '/var/lib/docker',
  '/var/lib/containerd',
  '/run/containerd',
  '/var/run/containerd',
  '/proc',
  '/sys',
  '/dev',
];

/// The profile file does not validate; the process must not start.
class ProfileLoadError implements Exception {
  ProfileLoadError(this.message);
  final String message;
  @override
  String toString() => 'executor profiles: $message';
}

enum Egress { none, allowlist }

class ProfileMount {
  const ProfileMount(this.source, this.target);
  final String source;
  final String target;
}

/// Limits of a profile; null fields take the supervisor's defaults.
class ProfileLimits {
  const ProfileLimits({
    this.cpus,
    this.memoryMb,
    this.pids,
    this.workspaceMb,
    this.homeMb,
    this.timeoutSecondsMax = defaultTimeoutSecondsMax,
  });
  final double? cpus;
  final int? memoryMb;
  final int? pids;
  final int? workspaceMb;
  final int? homeMb;
  final int timeoutSecondsMax;
}

class ExecutorProfile {
  ExecutorProfile({
    required this.name,
    required this.description,
    required this.image,
    required this.digest,
    this.mounts = const [],
    this.egress = Egress.allowlist,
    this.devices = const [],
    this.limits = const ProfileLimits(),
    this.env = const {},
  });

  final String name;
  final String description;

  /// Null only for the implicit `default` (no profile file): the
  /// supervisor's `SANDBOX_IMAGE`.
  final String? image;

  /// SHA-256 of the profile's canonical JSON definition; the agent service
  /// compares it with the supervisor's copy.
  final String digest;
  final List<ProfileMount> mounts;
  final Egress egress;
  final List<String> devices;
  final ProfileLimits limits;
  final Map<String, String> env;

  int get timeoutSecondsMax => limits.timeoutSecondsMax;
}

class ExecutorProfiles {
  ExecutorProfiles._(this.profiles, this.path);

  /// Profiles by name, `default` first.
  final Map<String, ExecutorProfile> profiles;

  /// The file they were read from; null for the implicit `default`.
  final String? path;

  /// No profile file: one profile, `default`, with today's image, limits and
  /// network.
  factory ExecutorProfiles.implicit() => ExecutorProfiles._({
    defaultProfileName: ExecutorProfile(
      name: defaultProfileName,
      description: "Dify's shell sandbox",
      image: null,
      digest: _digest(const <String, Object?>{}),
    ),
  }, null);

  ExecutorProfile? operator [](String name) => profiles[name];

  Iterable<String> get names => profiles.keys;

  /// Reads [path]. A missing file at the default path means the implicit
  /// `default`; a file named explicitly must exist. Throws
  /// [ProfileLoadError] for anything that does not validate.
  static ExecutorProfiles load(
    String? path, {
    Iterable<String> forbiddenSources = const [],
  }) {
    final explicit = path != null && path.isNotEmpty;
    final file = File(explicit ? path : defaultProfilesPath);
    if (!file.existsSync()) {
      if (explicit) throw ProfileLoadError('${file.path} does not exist');
      return ExecutorProfiles.implicit();
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw ProfileLoadError('${file.path} is not JSON: ${e.message}');
    } on FileSystemException catch (e) {
      throw ProfileLoadError('${file.path} cannot be read: ${e.message}');
    }
    return parse(
      json,
      path: file.path,
      forbiddenSources: [file.path, ...forbiddenSources],
    );
  }

  /// Validates a decoded profile file.
  static ExecutorProfiles parse(
    Object? json, {
    String? path,
    Iterable<String> forbiddenSources = const [],
  }) {
    final forbidden = [
      ...builtinForbiddenSources,
      for (final f in forbiddenSources)
        if (f.isNotEmpty) _normalizeLoose(f),
    ];
    final root = _obj(json, 'the file');
    _onlyKeys(root, const {'version', 'profiles'}, 'the file');
    if (root['version'] != 1) {
      throw ProfileLoadError('"version" must be 1');
    }
    final raw = _obj(root['profiles'], '"profiles"');
    if (!raw.containsKey(defaultProfileName)) {
      throw ProfileLoadError('"profiles" must define "$defaultProfileName"');
    }
    final names = [
      defaultProfileName,
      ...raw.keys.where((k) => k != 'default'),
    ];
    final profiles = <String, ExecutorProfile>{};
    for (final name in names) {
      if (!profileNamePattern.hasMatch(name)) {
        throw ProfileLoadError(
          'profile name "$name" must match ${profileNamePattern.pattern}',
        );
      }
      profiles[name] = _profile(name, raw[name], forbidden);
    }
    return ExecutorProfiles._(profiles, path);
  }

  static ExecutorProfile _profile(
    String name,
    Object? json,
    List<String> forbidden,
  ) {
    final where = 'profile "$name"';
    final p = _obj(json, where);
    _onlyKeys(p, const {
      'description',
      'image',
      'mounts',
      'network',
      'devices',
      'limits',
      'env',
    }, where);
    final description = p['description'] ?? '';
    if (description is! String || description.length > 200) {
      throw ProfileLoadError(
        '$where: "description" must be a string of at most 200 characters',
      );
    }
    final image = p['image'];
    if (image is! String || !_pinnedImage.hasMatch(image)) {
      throw ProfileLoadError(
        '$where: "image" must be pinned by digest (name@sha256:<64 hex>); '
        'got ${jsonEncode(image)}',
      );
    }

    final mounts = <ProfileMount>[];
    final rawMounts = p['mounts'] ?? const [];
    if (rawMounts is! List) {
      throw ProfileLoadError('$where: "mounts" must be a list');
    }
    for (var i = 0; i < rawMounts.length; i++) {
      final m = _obj(rawMounts[i], '$where mounts[$i]');
      _onlyKeys(m, const {'source', 'target'}, '$where mounts[$i]');
      final source = _absolutePath(m['source'], '$where mounts[$i].source');
      final target = _absolutePath(m['target'], '$where mounts[$i].target');
      if (source == '/') {
        throw ProfileLoadError('$where mounts[$i]: the source must not be /');
      }
      for (final f in forbidden) {
        if (_related(source, f)) {
          throw ProfileLoadError(
            '$where mounts[$i]: the source $source must not be, contain or '
            'lie inside $f',
          );
        }
      }
      if (!target.startsWith('/opt/')) {
        throw ProfileLoadError(
          '$where mounts[$i]: the target $target must lie under /opt',
        );
      }
      for (final other in mounts) {
        if (_related(target, other.target)) {
          throw ProfileLoadError(
            '$where mounts[$i]: the target $target overlaps ${other.target}',
          );
        }
      }
      mounts.add(ProfileMount(source, target));
    }

    var egress = Egress.allowlist;
    if (p['network'] != null) {
      final n = _obj(p['network'], '$where network');
      _onlyKeys(n, const {'egress'}, '$where network');
      egress = switch (n['egress'] ?? 'allowlist') {
        'none' => Egress.none,
        'allowlist' => Egress.allowlist,
        final other => throw ProfileLoadError(
          '$where: network.egress must be "none" or "allowlist"; got ${jsonEncode(other)}',
        ),
      };
    }

    final devices = <String>[];
    final rawDevices = p['devices'] ?? const [];
    if (rawDevices is! List) {
      throw ProfileLoadError('$where: "devices" must be a list');
    }
    for (final d in rawDevices) {
      if (d is! String || !_renderNode.hasMatch(d)) {
        throw ProfileLoadError(
          '$where: devices may only be DRI render nodes (/dev/dri/renderD*); '
          'got ${jsonEncode(d)}',
        );
      }
      if (devices.contains(d)) {
        throw ProfileLoadError('$where: device $d repeats');
      }
      devices.add(d);
    }

    var limits = const ProfileLimits();
    if (p['limits'] != null) {
      final l = _obj(p['limits'], '$where limits');
      _onlyKeys(l, const {
        'cpus',
        'memory_mb',
        'pids',
        'workspace_mb',
        'home_mb',
        'timeout_seconds_max',
      }, '$where limits');
      final cpus = l['cpus'];
      if (cpus != null && (cpus is! num || cpus <= 0 || cpus > 256)) {
        throw ProfileLoadError(
          '$where: limits.cpus must be a number in (0, 256]',
        );
      }
      int? integer(String key, int min, int max) {
        final v = l[key];
        if (v == null) return null;
        if (v is! int || v < min || v > max) {
          throw ProfileLoadError(
            '$where: limits.$key must be an integer in $min..$max',
          );
        }
        return v;
      }

      limits = ProfileLimits(
        cpus: (cpus as num?)?.toDouble(),
        memoryMb: integer('memory_mb', 64, 1 << 20),
        pids: integer('pids', 16, 1 << 22),
        workspaceMb: integer('workspace_mb', 1, 1 << 20),
        homeMb: integer('home_mb', 1, 1 << 20),
        timeoutSecondsMax:
            integer('timeout_seconds_max', 1, maxTimeoutSecondsMax) ??
            defaultTimeoutSecondsMax,
      );
      final (m, w, h) = (limits.memoryMb, limits.workspaceMb, limits.homeMb);
      if (m != null && w != null && h != null && w + h >= m) {
        // tmpfs pages are charged to the container's memory limit.
        throw ProfileLoadError(
          '$where: limits.workspace_mb + limits.home_mb must be below limits.memory_mb',
        );
      }
    }

    final env = <String, String>{};
    if (p['env'] != null) {
      final e = _obj(p['env'], '$where env');
      for (final MapEntry(:key, :value) in e.entries) {
        if (!_envName.hasMatch(key)) {
          throw ProfileLoadError(
            '$where: env name "$key" is not a valid variable name',
          );
        }
        if (isReservedEnvName(key)) {
          throw ProfileLoadError('$where: env name "$key" is reserved');
        }
        if (value is! String || value.contains('\u0000')) {
          throw ProfileLoadError(
            '$where: env.$key must be a string without NUL',
          );
        }
        env[key] = value;
      }
    }

    return ExecutorProfile(
      name: name,
      description: description,
      image: image,
      digest: _digest(p),
      mounts: List.unmodifiable(mounts),
      egress: egress,
      devices: List.unmodifiable(devices),
      limits: limits,
      env: Map.unmodifiable(env),
    );
  }

  static String _digest(Map<String, Object?> definition) =>
      sha256.convert(utf8.encode(canonicalJson(definition))).toString();

  static Map<String, Object?> _obj(Object? v, String where) {
    if (v is Map) return v.cast<String, Object?>();
    throw ProfileLoadError('$where must be a JSON object');
  }

  static void _onlyKeys(
    Map<String, Object?> o,
    Set<String> allowed,
    String where,
  ) {
    final unknown = o.keys.where((k) => !allowed.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw ProfileLoadError('$where: unknown fields ${unknown.join(', ')}');
    }
  }

  /// An absolute, normalized path: no `.`, `..` or empty segments, no
  /// trailing slash, none of `:`, `,` and control characters.
  static String _absolutePath(Object? v, String where) {
    if (v is! String || !v.startsWith('/')) {
      throw ProfileLoadError('$where must be an absolute path');
    }
    if (v.contains(RegExp(r'[\u0000-\u001f\u007f:,]'))) {
      throw ProfileLoadError(
        '$where must not contain ":", "," or control characters',
      );
    }
    if (v == '/') return v;
    final segments = v.substring(1).split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw ProfileLoadError(
        '$where must be normalized (no ".", ".." or "//", no trailing "/")',
      );
    }
    return v;
  }

  static String _normalizeLoose(String path) {
    final segments = [
      for (final s in path.split('/'))
        if (s.isNotEmpty && s != '.') s,
    ];
    return '/${segments.join('/')}';
  }

  /// [a] is, contains or lies inside [b].
  static bool _related(String a, String b) =>
      a == b ||
      a.startsWith('$b/') ||
      b.startsWith('$a/') ||
      a == '/' ||
      b == '/';
}

/// What an operation is checked against (also used by the fake service).
typedef ProfileTerms = ({int timeoutSecondsMax, Iterable<String> envNames});

/// The executor-profile answers of an operation that uses the shell, in
/// this order: `422 executor_profile_unknown` ([terms] null), `422
/// invalid_request` (`limits.timeout_seconds` above the profile's
/// `timeout_seconds_max`), `400 reserved_env` (a variable the profile sets;
/// compared case-insensitively) and `503 executor_profile_unavailable`
/// ([status] known and not `ok`; null when the supervisor could not be
/// asked, and the run is attempted).
void checkOperationProfile(
  OperationRequest op,
  ProfileTerms? terms,
  String? status,
) {
  final name = op.executorProfile;
  if (terms == null) {
    throw ApiError(
      422,
      'executor_profile_unknown',
      'executor profile $name is not defined on this agent service',
    );
  }
  if (op.timeoutSeconds > terms.timeoutSecondsMax) {
    throw ApiError(
      422,
      'invalid_request',
      'limits.timeout_seconds ${op.timeoutSeconds} exceeds the '
          'timeout_seconds_max ${terms.timeoutSecondsMax} of executor '
          'profile $name',
    );
  }
  final upper = {for (final n in terms.envNames) n.toUpperCase()};
  final overriding = op.env.keys
      .where((k) => upper.contains(k.toUpperCase()))
      .toList();
  if (overriding.isNotEmpty) {
    throw ApiError(
      400,
      'reserved_env',
      'environment variables set by executor profile $name: '
          '${overriding.join(', ')}',
    );
  }
  if (status != null && status != 'ok') {
    throw ApiError(
      503,
      'executor_profile_unavailable',
      'executor profile $name is not available on this host ($status)',
      extra: {'status': status},
    );
  }
}
