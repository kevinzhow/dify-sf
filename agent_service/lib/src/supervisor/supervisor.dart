/// The sandbox supervisor: the only component with access to the container
/// runtime. It accepts exactly two commands, "create the sandbox for
/// execution X" and "remove sandbox Y"; image, network, limits and labels come
/// from its own configuration, never from a request.
///
/// API (bearer `SANDBOX_SUPERVISOR_KEY`):
///
/// - `POST /v1/sandboxes {"execution_key"}` → `{"sandbox_id", "url", "token",
///   "created"}`; idempotent per execution key (a stopped container is
///   replaced, with a new `sandbox_id`).
/// - `DELETE /v1/sandboxes/{sandbox_id}` → `{"sandbox_id", "deleted"}`
///   (force remove with volumes; containers without the label are refused).
/// - `GET /v1/sandboxes` → `{"sandboxes": [...]}` (labelled containers only).
/// - `GET /v1/health` → `{"status", "docker"}`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'docker.dart';

/// The shellctl port of the sandbox image.
const shellctlPort = 5004;

/// Label holding the SHA-256 of the execution key.
const executionLabel = 'dify-sf.sandbox.execution';

class SupervisorConfigError implements Exception {
  SupervisorConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything a sandbox is made of. Only the environment of the supervisor
/// process sets these.
class SupervisorConfig {
  SupervisorConfig({
    required this.key,
    required this.network,
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
    this.proxyUrl,
    this.noProxy = 'localhost,127.0.0.1',
    this.addressByIp = false,
    this.statePath,
    this.startTimeout = const Duration(seconds: 60),
  });

  final String key;
  final String network;
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
  final String? proxyUrl;
  final String noProxy;

  /// Sandbox URLs use the container's IP on [network] instead of its name
  /// (for a caller outside Docker's DNS, e.g. the integration test).
  final bool addressByIp;

  /// Where known sandboxes are recorded; without it, they are kept in memory
  /// only and a restart removes every labelled container.
  final String? statePath;
  final Duration startTimeout;

  String get label => '$labelKey=$labelValue';

  /// Reads `SANDBOX_*` and `DOCKER_SOCKET` (see README.md).
  static SupervisorConfig fromEnv(Map<String, String> env) {
    String? opt(String name) {
      final v = env[name]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    String req(String name) =>
        opt(name) ?? (throw SupervisorConfigError('$name is required'));

    int intOf(String name, int fallback, {int min = 1}) {
      final v = opt(name);
      if (v == null) return fallback;
      final n = int.tryParse(v);
      if (n == null || n < min) {
        throw SupervisorConfigError('$name must be an integer >= $min');
      }
      return n;
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
    final config = SupervisorConfig(
      key: req('SANDBOX_SUPERVISOR_KEY'),
      network: req('SANDBOX_NETWORK'),
      image:
          opt('SANDBOX_IMAGE') ?? 'langgenius/dify-agent-local-sandbox:1.17.1',
      dockerSocket: opt('DOCKER_SOCKET') ?? '/var/run/docker.sock',
      port: intOf('SANDBOX_SUPERVISOR_PORT', 5060, min: 0),
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
      proxyUrl: opt('SANDBOX_PROXY_URL'),
      noProxy: opt('SANDBOX_NO_PROXY') ?? 'localhost,127.0.0.1',
      addressByIp: address == 'ip',
      statePath: opt('SANDBOX_STATE_FILE'),
      startTimeout: Duration(seconds: intOf('SANDBOX_START_TIMEOUT', 60)),
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
  SandboxSupervisor(this.config, {DockerClient? docker, this.log})
    : docker = docker ?? DockerClient(config.dockerSocket);

  final SupervisorConfig config;
  final DockerClient docker;
  final void Function(String message)? log;

  final Random _random = Random.secure();

  /// Known sandboxes: container ID → execution key hash.
  final Map<String, String> _known = {};
  final Map<String, Future<void>> _locks = {};
  HttpServer? _server;

  int get port => _server!.port;
  Set<String> get knownIds => Set.unmodifiable(_known.keys);

  static String hashKey(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  String containerName(String executionKey) =>
      '${config.namePrefix}${hashKey(executionKey).substring(0, 24)}';

  /// The container create payload: everything but the token is fixed by the
  /// configuration.
  Map<String, Object?> createPayload(String executionKey, String token) {
    final c = config;
    String tmpfs(int mb) =>
        'rw,exec,nosuid,nodev,size=${mb}m,mode=0700,uid=${c.uid},gid=${c.gid}';
    final proxy = c.proxyUrl;
    return {
      'Image': c.image,
      'Env': [
        'SHELLCTL_AUTH_TOKEN=$token',
        if (proxy != null) ...[
          'HTTP_PROXY=$proxy',
          'HTTPS_PROXY=$proxy',
          'http_proxy=$proxy',
          'https_proxy=$proxy',
          'NO_PROXY=${c.noProxy}',
          'no_proxy=${c.noProxy}',
        ],
      ],
      'Labels': {
        c.labelKey: c.labelValue,
        executionLabel: hashKey(executionKey),
      },
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
        'NetworkMode': c.network,
        'Memory': c.memoryMb * 1024 * 1024,
        'MemorySwap': c.memoryMb * 1024 * 1024,
        'NanoCpus': (c.cpus * 1e9).round(),
        'PidsLimit': c.pidsLimit,
        'ReadonlyRootfs': true,
        'Tmpfs': {
          '/home/dify': tmpfs(c.homeMb),
          '/workspace': tmpfs(c.workspaceMb),
        },
        'CapDrop': ['ALL'],
        'SecurityOpt': ['no-new-privileges:true'],
        'Privileged': false,
        'Binds': <String>[],
        'Mounts': <Object?>[],
        'IpcMode': 'private',
        'RestartPolicy': {'Name': 'no'},
        'LogConfig': {
          'Type': 'json-file',
          'Config': {'max-size': '1m', 'max-file': '1'},
        },
      },
      'NetworkingConfig': {
        'EndpointsConfig': {c.network: <String, Object?>{}},
      },
    };
  }

  // ---- lifecycle ----------------------------------------------------------

  Future<int> start({Object address = '0.0.0.0', int? port}) async {
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

  /// Removes every labelled container this supervisor does not know of and
  /// forgets known ones that no longer exist. Unlabelled containers are never
  /// listed, so never touched.
  Future<List<String>> sweep() async {
    final removed = <String>[];
    final present = <String>{};
    for (final c in await docker.listContainers([config.label])) {
      final id = c['Id'] as String;
      present.add(id);
      if (_known.containsKey(id)) continue;
      await docker.removeContainer(id);
      removed.add(id);
      log?.call('sweep removed unknown sandbox $id');
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
    final labels = (inspect['Config'] as Map?)?['Labels'];
    return labels is Map && labels[config.labelKey] == config.labelValue;
  }

  String _newToken() {
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Creates (or returns) the sandbox of [executionKey].
  Future<Map<String, Object?>> acquire(String executionKey) => _locked(
    executionKey,
    () async {
      final name = containerName(executionKey);
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
          final id = existing['Id'] as String;
          final state = existing['State'] as Map?;
          if (state?['Running'] == true &&
              (state?['Health'] as Map?)?['Status'] != 'unhealthy') {
            _known[id] = hashKey(executionKey);
            _saveState();
            final ready = await _waitHealthy(id);
            return _describe(ready, created: false);
          }
          // Stopped (its tmpfs workspace is gone) or unhealthy: replace it.
          log?.call('replacing stopped sandbox $id');
          await docker.removeContainer(id);
          _known.remove(id);
          _saveState();
        }
        final token = _newToken();
        final id = await docker.createContainer(
          name,
          createPayload(executionKey, token),
        );
        if (id == null) continue; // created concurrently; inspect again
        _known[id] = hashKey(executionKey);
        _saveState();
        try {
          await docker.startContainer(id);
          final ready = await _waitHealthy(id);
          log?.call('created sandbox $id');
          return _describe(ready, created: true);
        } catch (e) {
          await docker.removeContainer(id).catchError((_) => false);
          _known.remove(id);
          _saveState();
          rethrow;
        }
      }
      throw SupervisorError(503, 'sandbox_conflict', 'could not create $name');
    },
  );

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

  Map<String, Object?> _describe(
    Map<String, Object?> inspect, {
    required bool created,
  }) {
    final id = inspect['Id'] as String;
    final env = ((inspect['Config'] as Map?)?['Env'] as List?) ?? const [];
    const prefix = 'SHELLCTL_AUTH_TOKEN=';
    final token = env
        .whereType<String>()
        .firstWhere((e) => e.startsWith(prefix), orElse: () => prefix)
        .substring(prefix.length);
    final String host;
    if (config.addressByIp) {
      final networks =
          ((inspect['NetworkSettings'] as Map?)?['Networks'] as Map?) ??
          const {};
      final ip = (networks[config.network] as Map?)?['IPAddress'];
      if (ip is! String || ip.isEmpty) {
        throw SupervisorError(503, 'sandbox_start_failed', 'sandbox has no IP');
      }
      host = ip;
    } else {
      host = (inspect['Name'] as String? ?? '').replaceFirst('/', '');
    }
    return {
      'sandbox_id': id,
      'url': 'http://$host:$shellctlPort',
      'token': token,
      'created': created,
    };
  }

  /// Force-removes a labelled container; false when it does not exist.
  Future<bool> remove(String sandboxId) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(sandboxId)) {
      throw SupervisorError(400, 'invalid_request', 'invalid sandbox_id');
    }
    final inspect = await docker.inspectContainer(sandboxId);
    if (inspect == null) {
      if (_known.remove(sandboxId) != null) _saveState();
      return false;
    }
    if (!_labelled(inspect)) {
      throw SupervisorError(404, 'not_found', 'no sandbox $sandboxId');
    }
    final id = inspect['Id'] as String;
    final removed = await docker.removeContainer(id);
    _known.remove(id);
    _saveState();
    log?.call('removed sandbox $id');
    return removed;
  }

  Future<List<Map<String, Object?>>> list() async => [
    for (final c in await docker.listContainers([config.label]))
      {
        'sandbox_id': c['Id'],
        'name': ((c['Names'] as List?)?.firstOrNull as String?)?.replaceFirst(
          '/',
          '',
        ),
        'state': c['State'],
        'execution_sha256': (c['Labels'] as Map?)?[executionLabel],
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
        case ('POST', ['v1', 'sandboxes']):
          final body = await _body(request);
          final extra = body.keys.where((k) => k != 'execution_key').toList();
          if (extra.isNotEmpty) {
            throw SupervisorError(
              400,
              'invalid_request',
              'only execution_key may be given; got ${extra.join(', ')}',
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
          final sandbox = await acquire(key);
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
